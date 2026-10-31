package dev.qeltravyx.qeltravyx

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Executes only the bundled CORE module. No prompt is interpolated into shell. */
internal class CoreV2Bridge(
    private val context: Context,
    private val ui: Handler,
    private val worker: ExecutorService,
    private val projectRoot: (String) -> File
) {
    private data class Run(val id: String, val cancelled: AtomicBoolean = AtomicBoolean(false))
    private val runs = ConcurrentHashMap<String, Run>()
    @Volatile private var events: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        EventChannel(messenger, "qeltravyx/core-v2-progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(messenger, "qeltravyx/core-v2").setMethodCallHandler { call, result ->
            try {
                val project = call.argument<String>("project") ?: error("Projeto ausente")
                val root = projectRoot(project)
                require(root.isDirectory) { "Projeto inexistente" }
                val id = call.argument<String>("runId") ?: error("Execucao ausente")
                require(Regex("[a-zA-Z0-9_-]{1,64}").matches(id)) { "Execucao invalida" }
                when (call.method) {
                    "cancelCoreV2" -> {
                        runs[project]?.takeIf { it.id == id }?.cancelled?.set(true)
                        refresh(project)
                        if (runs[project] == null) persistCancellation(project, id)
                        result.success(null)
                    }
                    "runCoreV2" -> {
                        val request = call.argument<String>("request") ?: error("Pedido ausente")
                        require(request.toByteArray(Charsets.UTF_8).size <= 240000) { "Pedido excessivo" }
                        val approved = call.argument<Boolean>("approved") == true
                        val run = Run(id)
                        require(runs.putIfAbsent(project, run) == null) { "Tarefa ja em execucao" }
                        worker.execute {
                            try {
                                refresh(project)
                                val response = execute(project, root, request, approved, run)
                                // Release before delivering approval/completion: the Dart
                                // callback may immediately submit the authorized next step.
                                runs.remove(project, run)
                                ui.post { result.success(response) }
                            } catch (error: Exception) {
                                runs.remove(project, run)
                                ui.post { result.error("CORE_V2", error.message ?: "Falha CORE V2", null) }
                            } finally {
                                runs.remove(project, run)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("CORE_V2", error.message, null)
            }
        }
    }

    private fun metadata(project: String): File {
        require(
            project.isNotBlank() &&
            project != "." &&
            project != ".." &&
            !project.contains('/') &&
            !project.contains('\\')
        ) { "Nome de projeto invalido" }

        val base = File(context.filesDir, "core-v2")
        require(!java.nio.file.Files.isSymbolicLink(base.toPath())) {
            "Link na raiz de metadados"
        }

        val directory = File(base, project)
        require(!java.nio.file.Files.isSymbolicLink(directory.toPath())) {
            "Link em metadados"
        }
        require(directory.canonicalFile.parentFile == base.canonicalFile) {
            "Metadados fora da pasta autorizada"
        }
        check(directory.isDirectory || directory.mkdirs()) { "Falha ao criar metadados" }
        return directory
    }

    private fun persistCancellation(project: String, id: String) {
        val directory = metadata(project)
        val target = File(directory, "run_$id.json")
        require(
            !java.nio.file.Files.isSymbolicLink(target.toPath()) &&
            target.canonicalFile.parentFile == directory.canonicalFile
        ) { "Link em estado" }
        if (!target.isFile || target.length() > 1_000_000) return
        val state = JSONObject(target.readText())
        if (state.optString("phase") != "approval") return
        state.put("phase", "cancelled")
        state.put("updated_at", System.currentTimeMillis() / 1000.0)
        state.put("diagnostic", JSONObject().put("code", "cancelled").put("phase", "approval")
            .put("message", "Aprovacao recusada ou cancelada").put("automatic_replay", false)
            .put("next_step", "Consulte estado e backups antes de reenviar uma etapa."))
        state.optJSONArray("events")?.put(JSONObject().put("phase", "cancelled").put("message", "Aprovacao recusada ou cancelada"))
        val temp = File.createTempFile("state-", ".tmp", directory)
        try {
            temp.writeText(state.toString())
            check(temp.renameTo(target)) { "Falha ao persistir cancelamento" }
        } finally { temp.delete() }
    }

    private fun grants(project: String): JSONObject {
        val prefs = context.getSharedPreferences("qeltravyx_agent_permissions_v1", Context.MODE_PRIVATE)
        return JSONObject().apply {
            for (key in listOf("read", "write", "tests", "web")) put(key, prefs.getBoolean("project:$project:$key", false))
        }
    }

    /** Called on permission save/revoke, so an active task sees revocation. */
    @Synchronized fun refresh(project: String) {
        val run = runs[project] ?: return
        val directory = metadata(project)
        val temp = File.createTempFile("control-", ".tmp", directory)
        try {
            temp.writeText(JSONObject().put("grants", grants(project)).put("cancelled", run.cancelled.get()).toString())
            check(temp.renameTo(File(directory, "control.json"))) { "Falha ao atualizar permissoes" }
        } finally { temp.delete() }
    }

    private fun execute(project: String, root: File, request: String, approved: Boolean, run: Run): Map<String, Any> {
        val binary = File(context.applicationInfo.nativeLibraryDir, "libqeltravyx_python.so")
        val pyhome = File(context.filesDir, "python-runtime-3.14.9")
        require(binary.canExecute() && File(pyhome, ".qeltravyx_ready").isFile) { "Runtime Python ainda nao preparado; reinicie o aplicativo" }
        val directory = metadata(project)
        val script = File.createTempFile("core-runtime-", ".py", context.cacheDir)
        var child: Process? = null
        try {
            context.assets.open("qeltravyx/core_v2.py").use { input -> script.outputStream().use { input.copyTo(it) } }
            val builder = ProcessBuilder(binary.absolutePath, "-I", "-B", script.absolutePath).directory(root)
            val env = builder.environment()
            env.clear()
            env["QELTRAVYX_PYHOME"] = pyhome.absolutePath
            env["LD_LIBRARY_PATH"] = context.applicationInfo.nativeLibraryDir
            env["PATH"] = "/system/bin:/system/xbin"
            env["TMPDIR"] = context.cacheDir.absolutePath
            env["LANG"] = "C.UTF-8"
            env["ANDROID_ROOT"] = "/system"
            env["ANDROID_DATA"] = "/data"
            val process = builder.start()
            child = process
            val payload = JSONObject().put("root", root.absolutePath).put("metadata", directory.absolutePath)
                .put("grants", grants(project)).put("request", request).put("approved", approved).put("runId", run.id)
            process.outputStream.bufferedWriter(Charsets.UTF_8).use { it.write(payload.toString()) }
            var response: Map<String, Any>? = null
            var failure: Exception? = null
            // Runtime stdout is JSON lines only. Bound accumulated data before parsing.
            val reader = Thread {
                try {
                    process.inputStream.bufferedReader(Charsets.UTF_8).use { input ->
                        val line = StringBuilder()
                        var total = 0
                        while (true) {
                            val c = input.read()
                            if (c < 0) break
                            require(++total <= 2_000_000 && line.length <= 300_000) { "Saida CORE excessiva" }
                            if (c != 10) { line.append(c.toChar()); continue }
                            val record = JSONObject(line.toString())
                            line.setLength(0)
                            record.optJSONObject("event")?.let { event ->
                                val value = mapOf("project" to project, "runId" to run.id,
                                    "phase" to event.optString("phase"), "message" to event.optString("message"))
                                ui.post { events?.success(value) }
                            }
                            record.optJSONObject("result")?.let { value ->
                                response = mutableMapOf<String, Any>("phase" to value.optString("phase", "failed"),
                                    "output" to value.optString("output"), "runId" to run.id).apply {
                                    for (key in listOf("diagnostic", "persistence_diagnostic")) {
                                        value.optJSONObject(key)?.let { put(key, diagnostic(it)) }
                                    }
                                }
                            }
                        }
                    }
                } catch (error: Exception) { failure = error; process.destroyForcibly() }
            }
            reader.start()
            // Drain stderr without exposing raw credentials or unbounded buffering.
            val errors = Thread { runCatching { process.errorStream.use { stream ->
                val buffer = ByteArray(1024)
                while (stream.read(buffer) >= 0) { /* Runtime failures are reported through JSON. */ }
            } } }
            errors.start()
            if (!process.waitFor(480, TimeUnit.SECONDS)) {
                run.cancelled.set(true)
                refresh(project)
                if (!process.waitFor(12, TimeUnit.SECONDS)) process.destroyForcibly()
                error("Tempo limite CORE; consulte estado e backups antes de retomar")
            }
            reader.join(2000)
            errors.join(1000)
            check(!reader.isAlive) { "Leitura CORE incompleta" }
            failure?.let { throw it }
            return response ?: error("Runtime sem resposta valida")
        } finally {
            child?.destroyForcibly()
            script.delete()
        }
    }

    /** Only bounded codec-compatible fields from the bundled runtime cross the channel. */
    private fun diagnostic(value: JSONObject): Map<String, Any> = mutableMapOf<String, Any>().apply {
        for (key in listOf("code", "phase", "message", "next_step")) {
            val text = value.opt(key)
            if (text is String) put(key, text.take(if (key == "message") 1800 else 1000))
        }
        put("automatic_replay", false)
        value.optJSONArray("details")?.let { details ->
            put("details", (0 until minOf(details.length(), 5)).mapNotNull { index ->
                details.optJSONObject(index)?.let { item ->
                    mutableMapOf<String, Any>().apply {
                        for (key in listOf("code", "severity", "path", "message")) {
                            val text = item.opt(key)
                            if (text is String) put(key, text.take(600))
                        }
                        val line = item.optInt("line", -1)
                        if (line > 0) put("line", line)
                    }
                }
            })
        }
    }
}
