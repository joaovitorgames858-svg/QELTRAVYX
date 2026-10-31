package dev.qeltravyx.qeltravyx

import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

/** QELTRAVYX Alpha 0.4: native PTY, xterm2 frontend, Android /system/bin/sh only. */
class MainActivity : FlutterActivity() {
    companion object { init { System.loadLibrary("qeltravyx_pty") } }

    private external fun nativeCreatePty(home: String, libraries: String, rows: Int, cols: Int): IntArray
    private external fun nativeResizePty(fd: Int, rows: Int, cols: Int): Boolean
    private external fun nativeSignalPty(pid: Int): Unit
    private external fun nativeWaitPty(pid: Int): Int

    private class PtySession(
        val pid: Int,
        val fd: ParcelFileDescriptor,
        val writer: FileOutputStream,
        val closed: AtomicBoolean = AtomicBoolean(false)
    )

    private val ui = Handler(Looper.getMainLooper())
    private val worker = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<Int, PtySession>()
    private val nextId = AtomicInteger(1)
    private val coreV2 by lazy { CoreV2Bridge(this, ui, worker, ::safeProject) }
    @Volatile private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        coreV2.attach(messenger)
        RuntimeBridge(this, ui, worker).attach(messenger)
        // QELTRAVYX_VERSION_ALPHA094: versão real do APK instalado.
        MethodChannel(messenger, "qeltravyx/version")
            .setMethodCallHandler { call, result ->
                if (call.method == "getVersion") {
                    try {
                        @Suppress("DEPRECATION")
                        val versionInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(versionInfo.versionName ?: "0.9.4")
                    } catch (e: Exception) {
                        result.error("VERSION_UNAVAILABLE", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        // QELTRAVYX_PACKAGES_UI_ALPHA09: read only the qpkg registry for visual UI.
        // Installation/removal remains in the existing qpkg command within the PTY.
        MethodChannel(messenger, "qeltravyx/packages").setMethodCallHandler { call, result ->
            if (call.method != "installed") {
                result.notImplemented()
            } else {
                worker.execute {
                    try {
                        val registry = File(filesDir, "workspace/.qpkg/installed.json")
                        val items = linkedMapOf<String, String>()
                        if (registry.isFile) {
                            require(registry.length() < 2L * 1024 * 1024) { "Registro QPKG muito grande" }
                            val data = org.json.JSONObject(registry.readText(Charsets.UTF_8))
                            val keys = data.keys()
                            while (keys.hasNext()) {
                                val name = keys.next()
                                if (Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,99}").matches(name)) {
                                    val item = data.getJSONObject(name)
                                    items[name] = item.getString("version")
                                }
                            }
                        }
                        ui.post { result.success(items) }
                    } catch (e: Exception) {
                        ui.post { result.error("QPKG_REGISTRY", e.message ?: "Falha ao ler registro", null) }
                    }
                }
            }
        }
        // QELTRAVYX_WORKSPACE_ALPHA07: do not grant access outside workspace/projects.
        MethodChannel(messenger, "qeltravyx/workspace").setMethodCallHandler { call, result ->
            val project = call.argument<String>("project")
            val filename = call.argument<String>("file")
            val text = call.argument<String>("text")
            val newName = call.argument<String>("newName")
            val core = call.argument<Boolean>("core") == true
            worker.execute {
                try {
                    val value = handleWorkspace(call.method, project, filename, text, newName, core)
                    ui.post { result.success(value) }
                } catch (e: Exception) {
                    ui.post { result.error("WORKSPACE_ERROR", e.message ?: "Falha no workspace", null) }
                }
            }
        }
        EventChannel(messenger, "qeltravyx/output")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) { eventSink = null }
            })
                // QELTRAVYX_ALPHA097_AGENT: preferencias persistentes por projeto.
        // Legacy contracts plus CORE V1 guards, execution cancellation and metadata memory.
        MethodChannel(messenger, "qeltravyx/agent").setMethodCallHandler { call, result ->
            try {
                val projectName = call.argument<String>("project")
                require(projectName != null &&
                    Regex("[A-Za-z0-9][A-Za-z0-9_-]{0,39}").matches(projectName)) {
                    "Nome de projeto invalido"
                }
                val root = safeProject(projectName)
                require(root.isDirectory) { "Projeto nao encontrado" }
                val prefs = getSharedPreferences("qeltravyx_agent_permissions_v1", MODE_PRIVATE)
                val base = "project:$projectName:"
                when (call.method) {
                    "runAgentPython" -> {
                        val script = call.argument<String>("file")
                        val core = call.argument<Boolean>("core") == true
                        val runId = call.argument<String>("runId")
                        val expected = call.argument<String>("expected")
                        val cancel = if (core) {
                            require(expected != null) { "Versao revisada ausente" }
                            require(call.argument<Boolean>("consent") == true) { "Consentimento por execucao ausente" }
                            require(runId != null && Regex("[0-9]{1,24}").matches(runId)) { "Execucao invalida" }
                            require(coreRuns.isEmpty()) { "Execucao CORE ja pendente" }
                            AtomicBoolean(false).also { coreRuns["$projectName:$runId"] = it }
                        } else null
                        worker.execute {
                            try {
                                if (core) {
                                    require(prefs.getBoolean(base + "read", false) && prefs.getBoolean(base + "tests", false)) { "Leitura e testes nao autorizados" }
                                    CorePolicy.path(script ?: "")
                                    val source = managerPath(projectName, script)
                                    CorePolicy.read(source)
                                }
                                val output = runAgentPython(projectName!!, script, cancel, if (core) expected else null)
                                ui.post { result.success(output) }
                            } catch (e: Exception) {
                                ui.post { result.error("AGENT_PYTHON", e.message ?: "Falha ao executar Python", null) }
                            } finally {
                                if (core) coreRuns.remove("$projectName:$runId")
                            }
                        }
                    }
                    "applyAgentPlan" -> {
                        val changes = call.argument<List<Map<String, Any?>>>("changes")
                        val core = call.argument<Boolean>("core") == true
                        if (core) require(call.argument<Boolean>("consent") == true) { "Confirmacao de escrita ausente" }
                        worker.execute {
                            try {
                                val output = applyAgentPlan(projectName!!, changes, core)
                                ui.post { result.success(output) }
                            } catch (e: Exception) {
                                ui.post { result.error("AGENT_APPLY", e.message ?: "Falha na aplicacao", null) }
                            }
                        }
                    }
                    "cancelCorePython" -> {
                        val runId = call.argument<String>("runId")
                        coreRuns["$projectName:$runId"]?.set(true)
                        result.success(null)
                    }
                    "recordCoreMemory" -> {
                        val action = call.argument<String>("action")
                        val phase = call.argument<String>("phase")
                        require(action != null && phase != null && action in CorePolicy.actions && phase in CorePolicy.outcomes) { "Evento CORE invalido" }
                        // Separate bounded metadata store. No prompts, source, paths or output.
                        val memory = getSharedPreferences("qeltravyx_core_memory_v1", MODE_PRIVATE)
                        val old = JSONArray(memory.getString(projectName, "[]"))
                        val next = JSONArray()
                        for (i in maxOf(0, old.length() - 39) until old.length()) next.put(old.getString(i))
                        next.put("${System.currentTimeMillis()} | $action | $phase")
                        check(memory.edit().putString(projectName, next.toString()).commit()) { "Falha ao registrar memoria" }
                        result.success(null)
                    }
                    "getCoreMemory" -> {
                        require(prefs.getBoolean(base + "read", false)) { "Leitura nao autorizada" }
                        val memory = getSharedPreferences("qeltravyx_core_memory_v1", MODE_PRIVATE)
                        val entries = JSONArray(memory.getString(projectName, "[]"))
                        result.success((0 until entries.length()).map { entries.getString(it) })
                    }
                    "getPermissions" -> result.success(mapOf(
                        "read" to prefs.getBoolean(base + "read", false),
                        "write" to prefs.getBoolean(base + "write", false),
                        "download" to prefs.getBoolean(base + "download", false),
                        "tests" to prefs.getBoolean(base + "tests", false),
                        "web" to prefs.getBoolean(base + "web", false)
                    ))
                    "savePermissions" -> {
                        val keys = listOf("read", "write", "download", "tests", "web")
                        val editor = prefs.edit()
                        for (key in keys) {
                            val permitted = call.argument<Boolean>(key) ?: false
                            editor.putBoolean(base + key, permitted)
                        }
                        if (editor.commit()) { coreV2.refresh(projectName); result.success(null) }
                        else result.error("AGENT_PERSISTENCE", "Nao foi possivel gravar a autorizacao", null)
                    }
                    "revokePermissions" -> {
                        val editor = prefs.edit()
                        listOf("read", "write", "download", "tests", "web").forEach {
                            editor.remove(base + it)
                        }
                        if (editor.commit()) { coreV2.refresh(projectName); result.success(null) }
                        else result.error("AGENT_PERSISTENCE", "Nao foi possivel revogar a autorizacao", null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("AGENT_PERMISSIONS", error.message ?: "Falha na configuracao do agente", null)
            }
        }
        MethodChannel(messenger, "qeltravyx/shell")
            .setMethodCallHandler { call, result ->
                val id = call.argument<Int>("sessionId")
                when (call.method) {
                    "createSession" -> {
                        if (sessions.size >= 4) {
                            result.error("SESSION_LIMIT", "Máximo de 4 sessões", null)
                        } else {
                            try {
                                val newId = nextId.getAndIncrement()
                                launchPty(newId)
                                result.success(newId)
                            } catch (e: Exception) {
                                result.error("PTY_START_ERROR", e.message, null)
                            }
                        }
                    }
                    "sendCommand", "sendInput" -> {
                        val data = if (call.method == "sendInput") {
                            call.argument<String>("data")
                        } else {
                            call.argument<String>("command")?.plus("\n")
                        }
                        val session = if (id == null) null else sessions[id]
                        when {
                            id == null || session == null || session.closed.get() ->
                                result.error("PTY_NOT_RUNNING", "Sessão não encontrada", null)
                            data == null || data.isEmpty() -> result.success(null)
                            else -> {
                                worker.execute {
                                    try {
                                        synchronized(session.writer) {
                                            check(!session.closed.get()) { "Sessão encerrada antes do envio" }
                                            session.writer.write(data.toByteArray(Charsets.UTF_8))
                                            session.writer.flush()
                                        }
                                        ui.post {
                                            if (call.method == "sendCommand") {
                                                recordHistory(data.trimEnd('\n'))
                                            }
                                            result.success(null)
                                        }
                                    } catch (e: Exception) {
                                        ui.post { result.error("PTY_WRITE_ERROR", e.message, null) }
                                    }
                                }
                            }
                        }
                    }
                    "resizeSession" -> {
                        val session = if (id == null) null else sessions[id]
                        if (session == null || session.closed.get()) {
                            result.error("PTY_NOT_RUNNING", "Sessão não encontrada", null)
                        } else {
                            val rows = (call.argument<Int>("rows") ?: 24).coerceIn(1, 200)
                            val cols = (call.argument<Int>("cols") ?: 80).coerceIn(1, 300)
                            try { result.success(nativeResizePty(session.fd.fd, rows, cols)) }
                            catch (e: Exception) { result.error("PTY_RESIZE_ERROR", e.message, null) }
                        }
                    }
                    "stopSession" -> {
                        if (id == null) result.error("BAD_ID", "Sessão inválida", null)
                        else { closePty(id); result.success(null) }
                    }
                    "restartSession" -> {
                        if (id == null || !sessions.containsKey(id)) {
                            result.error("BAD_ID", "Sessão não encontrada", null)
                        } else {
                            try {
                                closePty(id)
                                launchPty(id)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("PTY_START_ERROR", e.message, null)
                            }
                        }
                    }
                    "preparePythonRuntime" -> {
                        worker.execute {
                            try {
                                preparePythonRuntime()
                                ui.post { result.success(null) }
                            } catch (e: Exception) {
                                ui.post { result.error("PYTHON_ASSETS_ERROR", e.message, null) }
                            }
                        }
                    }
                    "getHistory" -> result.success(readHistory())
                    "clearHistory" -> {
                        getSharedPreferences("qeltravyx_terminal", MODE_PRIVATE)
                            .edit().remove("history_v1").apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // QELTRAVYX_WORKSPACE_ALPHA07: file operations restricted to the app's projects directory.
    private fun projectRoot(): File {
        val root = File(filesDir, "workspace/projects")
        check(root.isDirectory || root.mkdirs()) { "Não foi possível criar workspace/projects" }
        return root.canonicalFile
    }

    private fun safeProject(name: String?): File {
        require(name != null && Regex("[A-Za-z0-9][A-Za-z0-9_-]{0,39}").matches(name)) {
            "Projeto: use letras, números, _ ou - (máximo 40 caracteres)"
        }
        val base = projectRoot()
        val requested = File(base, name)
        val path = requested.canonicalFile
        require(path == requested.absoluteFile) { "Links de projeto nao permitidos" }
        require(path.parentFile == base) { "Projeto fora do workspace" }
        return path
    }

    private fun safePythonFile(project: String?, filename: String?): File {
        val folder = safeProject(project)
        require(folder.isDirectory) { "Projeto não encontrado" }
        require(filename != null && Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,70}\\.py").matches(filename)
                && !filename.contains("..")) {
            "Arquivo inválido. Use um nome simples terminado em .py"
        }
        val file = File(folder, filename).canonicalFile
        require(file.parentFile == folder) { "Arquivo fora do projeto" }
        return file
    }

    // QELTRAVYX_ALPHA095_MANAGER: apenas arquivos de texto no workspace/projects.
    // O editor Python anterior continua usando safePythonFile sem alteracoes.
    private fun managerName(value: String?): String {
        require(value != null && Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,70}").matches(value)
                && !value.contains("..")) {
            "Nome invalido. Use letras, numeros, _, - e ponto, sem '..'"
        }
        return value
    }

    private fun managerFileAllowed(name: String): Boolean {
        val normalized = name.lowercase(java.util.Locale.ROOT)
        return normalized.endsWith(".py") || normalized.endsWith(".sh") ||
                normalized.endsWith(".json") || normalized.endsWith(".txt") ||
                listOf(".md", ".dart", ".yaml", ".yml", ".toml", ".html", ".css", ".js", ".ts").any { normalized.endsWith(it) }
    }

    private fun managerPath(project: String?, relative: String?, allowRoot: Boolean = false): File {
        val root = safeProject(project)
        require(root.isDirectory) { "Projeto nao encontrado" }
        if (relative.isNullOrEmpty()) {
            require(allowRoot) { "Informe um arquivo ou pasta" }
            return root
        }
        require(!relative.startsWith('/') && !relative.contains('\\') && !relative.contains('\u0000')) {
            "Caminho relativo invalido"
        }
        var current = root
        for (part in relative.split('/')) {
            managerName(part)
            val next = File(current, part)
            // Impede atraves de links simbolicos, inclusive em subpastas.
            require(next.canonicalFile == next.absoluteFile) { "Links simbolicos nao permitidos" }
            current = next
        }
        require(current.path.startsWith(root.path + File.separator)) { "Fora do projeto" }
        return current
    }

    // QELTRAVYX_ALPHA099_PYTHON_RUNNER: executor com limite de tempo e saida.
    // AVISO: subprocesso usa UID do aplicativo; NAO e sandbox de seguranca.
    private val agentPythonBusy = java.util.concurrent.atomic.AtomicBoolean(false)
    private val coreRuns = ConcurrentHashMap<String, AtomicBoolean>()

    private fun runAgentPython(projectName: String, relativePath: String?, cancel: AtomicBoolean? = null, expected: String? = null): Map<String, Any> {
        require(cancel?.get() != true) { "Execucao cancelada antes de iniciar" }
        val prefs = getSharedPreferences("qeltravyx_agent_permissions_v1", MODE_PRIVATE)
        require(prefs.getBoolean("project:$projectName:read", false) &&
                prefs.getBoolean("project:$projectName:tests", false)) {
            "Autorize leitura e execucao de testes no projeto"
        }
        require(relativePath != null && relativePath.endsWith(".py", ignoreCase = true)) {
            "Somente scripts Python .py podem ser executados"
        }
        require(relativePath.length <= 180 && relativePath.split('/').size <= 4) {
            "Caminho Python invalido"
        }
        val projectDir = safeProject(projectName)
        require(projectDir.isDirectory) { "Projeto nao encontrado" }
        val script = managerPath(projectName, relativePath)
        require(script.isFile && script.length() in 1L..(256L * 1024L)) {
            "Script Python inexistente, vazio ou maior que 256 KB"
        }
        val binary = File(applicationInfo.nativeLibraryDir, "libqeltravyx_python.so")
        require(binary.isFile && binary.canExecute()) {
            "Executor Python nao encontrado no APK"
        }
        val pyhome = File(filesDir, "python-runtime-3.14.9")
        require(File(pyhome, ".qeltravyx_ready").isFile &&
                File(pyhome, "lib/python3.14/encodings/__init__.py").isFile) {
            "Python ainda nao foi preparado. Reinicie o aplicativo."
        }
        require(agentPythonBusy.compareAndSet(false, true)) {
            "Ja existe um teste Python em execucao"
        }
        var process: Process? = null
        try {
            // Nenhum comando e passado a /system/bin/sh: argumentos separados.
            val builder = ProcessBuilder(
                binary.absolutePath, "-I", "-B", script.absolutePath
            ).directory(projectDir).redirectErrorStream(true)
            val env = builder.environment()
            env.clear()
            env["QELTRAVYX_PYHOME"] = pyhome.absolutePath
            env["HOME"] = filesDir.absolutePath
            env["TMPDIR"] = cacheDir.absolutePath
            env["PATH"] = "/system/bin:/system/xbin"
            env["LANG"] = "C.UTF-8"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["ANDROID_ROOT"] = "/system"
            env["ANDROID_DATA"] = "/data"
            env["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir
            require(cancel?.get() != true) { "Execucao cancelada antes de iniciar" }
            if (expected != null) {
                require(managerPath(projectName, relativePath) == script && CorePolicy.read(script) == expected) { "Arquivo alterado desde o consentimento" }
                require(prefs.getBoolean("project:$projectName:read", false) && prefs.getBoolean("project:$projectName:tests", false)) { "Autorizacao revogada" }
            }
            val launched = builder.start()
            process = launched
            val output = java.io.ByteArrayOutputStream()
            val truncated = java.util.concurrent.atomic.AtomicBoolean(false)
            val reader = Thread({
                try {
                    launched.inputStream.use { input ->
                        val buffer = ByteArray(1024)
                        while (true) {
                            val size = input.read(buffer)
                            if (size < 0) break
                            synchronized(output) {
                                val remaining = 12000 - output.size()
                                if (remaining > 0) output.write(buffer, 0, minOf(size, remaining))
                                if (size > remaining) truncated.set(true)
                            }
                        }
                    }
                } catch (_: Exception) { /* Processo terminou ou fechou o pipe. */ }
            }, "qeltravyx-agent-python-output")
            reader.isDaemon = true
            reader.start()
            val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(8)
            var finished = false
            while (cancel?.get() != true && System.nanoTime() < deadline) {
                if (launched.waitFor(100, java.util.concurrent.TimeUnit.MILLISECONDS)) {
                    finished = true
                    break
                }
            }
            val cancelled = cancel?.get() == true
            if (!finished) {
                launched.destroyForcibly()
                launched.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
            }
            reader.join(900)
            val captured = synchronized(output) {
                String(output.toByteArray(), Charsets.UTF_8)
            }
            val exitCode = if (finished) launched.exitValue() else -1
            return mapOf(
                "script" to relativePath,
                "exitCode" to exitCode,
                "timedOut" to (!finished && !cancelled),
                "cancelled" to cancelled,
                "truncated" to truncated.get(),
                "output" to captured,
                "message" to if (cancelled) "Execucao cancelada" else if (!finished) "Tempo limite de 8 segundos" else "Processo encerrado"
            )
        } finally {
            process?.destroyForcibly()
            agentPythonBusy.set(false)
        }
    }

    // QELTRAVYX_ALPHA098_AGENT_APPLY: escritas limitadas e auditadas no projeto.
    @Synchronized
    private fun applyAgentPlan(projectName: String, changes: List<Map<String, Any?>>?, core: Boolean = false): Map<String, Any> {
        val prefs = getSharedPreferences("qeltravyx_agent_permissions_v1", MODE_PRIVATE)
        require(prefs.getBoolean("project:$projectName:write", false)) {
            "Autorizacao de escrita do projeto ausente ou revogada"
        }
        require(changes != null && changes.isNotEmpty() && changes.size <= 3) {
            "Limite de 1 a 3 arquivos por lote"
        }
        val projectDir = safeProject(projectName)
        require(projectDir.isDirectory) { "Projeto nao encontrado" }
        data class Change(val path: String, val file: File, val payload: ByteArray,
                          val old: ByteArray?)
        val prepared = mutableListOf<Change>()
        val unique = mutableSetOf<String>()
        for (record in changes) {
            val relative = record["path"] as? String ?: error("Caminho ausente")
            val content = record["content"] as? String ?: error("Conteudo ausente")
            require(record.containsKey("expected")) { "Versao original ausente" }
            val expected = record["expected"] as? String
            if (core) {
                require(prefs.getBoolean("project:$projectName:read", false)) { "Leitura nao autorizada" }
                CorePolicy.path(relative)
                CorePolicy.content(content)
                if (expected != null) CorePolicy.content(expected)
            }
            val file = managerPath(projectName, relative)
            require(managerFileAllowed(file.name)) { "Extensao nao permitida" }
            require(relative.split('/').size <= 4 && relative.length <= 180) { "Caminho muito longo" }
            require(file.parentFile?.isDirectory == true) { "Pasta pai nao encontrada" }
            require(unique.add(relative.lowercase(java.util.Locale.ROOT))) { "Arquivo duplicado" }
            val data = content.toByteArray(Charsets.UTF_8)
            require(data.size <= 12000) { "Arquivo proposto maior que 12 KB" }
            val prior: ByteArray? = if (file.exists()) {
                require(file.isFile && file.length() <= 256L * 1024L) { "Arquivo nao suportado" }
                val currentText = if (core) CorePolicy.read(file) else file.readText(Charsets.UTF_8)
                require(expected != null && currentText == expected) {
                    "Arquivo alterado desde a previa: $relative"
                }
                file.readBytes()
            } else {
                require(expected == null) { "Arquivo removido desde a previa: $relative" }
                null
            }
            prepared.add(Change(relative, file, data, prior))
        }
        // Backup fora de workspace/projects, inacessivel pelo gerenciador.
        val archiveRoot = File(filesDir, "workspace/.agent_backups/$projectName")
        check(archiveRoot.isDirectory || archiveRoot.mkdirs()) { "Falha ao criar pasta de backups" }
        val backupDir = File(archiveRoot,
            "batch_${System.currentTimeMillis()}_${java.util.UUID.randomUUID().toString().take(8)}")
        check(backupDir.mkdir()) { "Falha ao iniciar backup" }
        val manifest = org.json.JSONArray()
        for (change in prepared) {
            if (change.old != null) {
                val backupFile = File(backupDir, "original/${change.path}")
                check(backupFile.parentFile?.isDirectory == true || backupFile.parentFile?.mkdirs() == true) {
                    "Falha ao criar estrutura de backup"
                }
                backupFile.writeBytes(change.old)
            }
            manifest.put(org.json.JSONObject().put("path", change.path)
                .put("created", change.old == null))
        }
        File(backupDir, "manifest.json").writeText(manifest.toString(2), Charsets.UTF_8)
        val applied = mutableListOf<Change>()
        try {
            // Revalida a autorizacao imediatamente antes das escritas.
            require(prefs.getBoolean("project:$projectName:write", false)) {
                "Autorizacao de escrita revogada"
            }
            if (core) require(prefs.getBoolean("project:$projectName:read", false)) { "Leitura revogada" }
            for (change in prepared) {
                require(managerPath(projectName, change.path) == change.file) { "Caminho alterado desde a previa" }
                val unchanged = if (change.old == null) !change.file.exists()
                    else change.file.isFile && change.file.length() <= 256L * 1024L && change.file.readBytes().contentEquals(change.old)
                require(unchanged) { "Arquivo alterado durante o backup" }
                val temp = File.createTempFile(".qeltravyx_agent_", ".tmp", change.file.parentFile)
                try {
                    FileOutputStream(temp).use { stream ->
                        stream.write(change.payload)
                        stream.fd.sync()
                    }
                    check(temp.renameTo(change.file)) { "Falha ao escrever: ${change.path}" }
                    applied.add(change)
                } finally {
                    if (temp.exists()) temp.delete()
                }
            }
        } catch (e: Exception) {
            // Se houver falha, tenta restaurar o lote ja aplicado.
            for (change in applied.asReversed()) {
                try {
                    if (change.old == null) {
                        change.file.delete()
                    } else {
                        val restore = File.createTempFile(".qeltravyx_restore_", ".tmp", change.file.parentFile)
                        try {
                            restore.writeBytes(change.old)
                            check(restore.renameTo(change.file)) { "Falha ao restaurar arquivo" }
                        } finally { if (restore.exists()) restore.delete() }
                    }
                } catch (_: Exception) { /* Backups originais permanecem em backupDir */ }
            }
            throw e
        }
        return mapOf("backupId" to backupDir.name,
            "paths" to prepared.map { it.path },
            "message" to "Alteracoes aplicadas com backup. Nenhum comando executado.")
    }
    @Synchronized
    private fun handleWorkspace(method: String, project: String?, filename: String?,
                                text: String?, newName: String?, core: Boolean = false): Any? {
        if (core) {
            require(method == "listEntries" || method == "readTextFile") { "Ferramenta CORE nao permitida" }
            val prefs = getSharedPreferences("qeltravyx_agent_permissions_v1", MODE_PRIVATE)
            require(prefs.getBoolean("project:$project:read", false)) { "Leitura nao autorizada" }
            if (!filename.isNullOrEmpty()) CorePolicy.path(filename, folder = method == "listEntries")
        }
        when (method) {
            // QELTRAVYX_ALPHA095_MANAGER: metodos exclusivos do novo explorador.
            "listEntries" -> {
                val folder = managerPath(project, filename, allowRoot = true)
                require(folder.isDirectory) { "Pasta nao encontrada" }
                val children = folder.listFiles() ?: emptyArray<File>()
                if (core) require(children.size <= CorePolicy.MAX_ENTRIES) { "Pasta excede 200 entradas" }
                return children.filter { child ->
                    (!core || runCatching { CorePolicy.path(child.name, folder = child.isDirectory) }.isSuccess) &&
                    child.canonicalFile == child.absoluteFile &&
                            (child.isDirectory || (child.isFile && managerFileAllowed(child.name)))
                }.sortedWith(compareBy<File> { !it.isDirectory }
                    .thenBy { it.name.lowercase(java.util.Locale.ROOT) })
                    .map { mapOf("name" to it.name, "isDirectory" to it.isDirectory) }
            }
            "createFolder" -> {
                val folder = managerPath(project, filename)
                require(folder.parentFile?.isDirectory == true) { "Pasta pai nao encontrada" }
                require(!folder.exists()) { "Nome ja utilizado" }
                check(folder.mkdir()) { "Nao foi possivel criar pasta" }
                return null
            }
            "createTextFile" -> {
                val file = managerPath(project, filename)
                require(managerFileAllowed(file.name)) { "Use .py, .sh, .json ou .txt" }
                require(file.parentFile?.isDirectory == true) { "Pasta pai nao encontrada" }
                require(!file.exists()) { "Arquivo ja existe" }
                check(file.createNewFile()) { "Nao foi possivel criar arquivo" }
                return null
            }
            "readTextFile" -> {
                val file = managerPath(project, filename)
                require(file.isFile && managerFileAllowed(file.name)) { "Arquivo nao suportado" }
                require(file.length() <= 256L * 1024L) { "Arquivo maior que 256 KB" }
                return if (core) CorePolicy.read(file) else file.readText(Charsets.UTF_8)
            }
            "saveTextFile" -> {
                val file = managerPath(project, filename)
                require(file.isFile && managerFileAllowed(file.name)) { "Arquivo nao suportado" }
                require(text != null && text.toByteArray(Charsets.UTF_8).size <= 256 * 1024) {
                    "O editor aceita ate 256 KB"
                }
                val temp = File.createTempFile(".qeltravyx_", ".tmp", file.parentFile)
                try {
                    FileOutputStream(temp).use { stream ->
                        stream.write(text.toByteArray(Charsets.UTF_8))
                        stream.fd.sync()
                    }
                    check(temp.renameTo(file)) { "Nao foi possivel salvar o arquivo" }
                } finally {
                    if (temp.exists()) temp.delete()
                }
                return null
            }
            "renameEntry" -> {
                val old = managerPath(project, filename)
                require(old.isFile || old.isDirectory) { "Entrada nao encontrada" }
                val newLeaf = managerName(newName)
                if (old.isFile) {
                    require(managerFileAllowed(old.name) && managerFileAllowed(newLeaf)) {
                        "Use arquivos .py, .sh, .json ou .txt"
                    }
                }
                val renamed = File(old.parentFile, newLeaf)
                require(renamed.canonicalFile == renamed.absoluteFile) { "Destino invalido" }
                require(!renamed.exists()) { "Nome ja utilizado" }
                check(old.renameTo(renamed)) { "Nao foi possivel renomear" }
                return null
            }
            "deleteEntry" -> {
                val entry = managerPath(project, filename)
                require(entry.isFile || entry.isDirectory) { "Entrada nao encontrada" }
                if (entry.isFile) {
                    require(managerFileAllowed(entry.name)) { "Arquivo nao suportado" }
                } else {
                    require(entry.listFiles()?.isEmpty() == true) {
                        "A pasta nao esta vazia. Remova os itens individualmente."
                    }
                }
                check(entry.delete()) { "Nao foi possivel excluir" }
                return null
            }
            "listProjects" -> return projectRoot().listFiles()
                ?.filter { it.isDirectory && it.canonicalFile.parentFile == projectRoot() }
                ?.map { it.name }?.sorted() ?: emptyList<String>()
            "createProject" -> {
                val dir = safeProject(project)
                require(!dir.exists()) { "Projeto já existe" }
                check(dir.mkdir()) { "Não foi possível criar projeto" }
                return null
            }
            "listFiles" -> {
                val dir = safeProject(project)
                require(dir.isDirectory) { "Projeto não encontrado" }
                return dir.listFiles()?.filter { it.isFile && it.canonicalFile.parentFile == dir
                        && it.name.endsWith(".py") }?.map { it.name }?.sorted()
                    ?: emptyList<String>()
            }
            "createFile" -> {
                val file = safePythonFile(project, filename)
                require(!file.exists()) { "Arquivo já existe" }
                check(file.createNewFile()) { "Não foi possível criar arquivo" }
                return null
            }
            "readFile" -> {
                val file = safePythonFile(project, filename)
                require(file.isFile) { "Arquivo não encontrado" }
                require(file.length() <= 256 * 1024) { "Arquivo maior que 256 KB" }
                return file.readText(Charsets.UTF_8)
            }
            "saveFile" -> {
                val file = safePythonFile(project, filename)
                require(file.isFile) { "Arquivo não encontrado" }
                require(text != null && text.toByteArray(Charsets.UTF_8).size <= 256 * 1024) {
                    "O editor aceita arquivos de até 256 KB"
                }
                val temp = File.createTempFile(".qeltravyx_", ".tmp", file.parentFile)
                try {
                    FileOutputStream(temp).use { stream ->
                        stream.write(text.toByteArray(Charsets.UTF_8))
                        stream.fd.sync()
                    }
                    check(temp.renameTo(file)) { "Não foi possível salvar o arquivo" }
                } finally {
                    if (temp.exists()) temp.delete()
                }
                return null
            }
            "renameFile" -> {
                val old = safePythonFile(project, filename)
                val renamed = safePythonFile(project, newName)
                require(old.isFile) { "Arquivo não encontrado" }
                require(!renamed.exists()) { "Nome já utilizado" }
                check(old.renameTo(renamed)) { "Não foi possível renomear arquivo" }
                return null
            }
            "deleteFile" -> {
                val file = safePythonFile(project, filename)
                require(file.isFile) { "Arquivo não encontrado" }
                check(file.delete()) { "Não foi possível excluir o arquivo" }
                return null
            }
            "filePath" -> {
                val file = safePythonFile(project, filename)
                require(file.isFile) { "Arquivo não encontrado" }
                return file.absolutePath
            }
            else -> error("Método de workspace desconhecido")
        }
    }

    // Extract the official CPython stdlib from one ZIP, once, outside the UI thread.
    private fun preparePythonRuntime() {
        val destination = File(filesDir, "python-runtime-3.14.9")
        val marker = File(destination, ".qeltravyx_ready")
        if (marker.isFile && File(destination,
            "lib/python3.14/encodings/__init__.py").isFile) {
            RuntimePip.prepare(this)
            return
        }

        val pending = File(filesDir, "python-runtime-3.14.9.tmp")
        if (pending.exists()) pending.deleteRecursively()
        val root = File(pending, "lib")
        check(root.mkdirs()) { "Não foi possível preparar os diretórios Python" }
        try {
            assets.open("qeltravyx/python/stdlib.zip").use { input ->
                java.util.zip.ZipInputStream(input.buffered()).use { zip ->
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        val destinationFile = File(root, entry.name).canonicalFile
                        check(destinationFile.path.startsWith(root.canonicalPath + File.separator)) {
                            "Caminho inválido no pacote Python"
                        }
                        if (entry.isDirectory) {
                            check(destinationFile.isDirectory || destinationFile.mkdirs())
                        } else {
                            destinationFile.parentFile?.mkdirs()
                            FileOutputStream(destinationFile).use { output ->
                                zip.copyTo(output)
                            }
                        }
                        zip.closeEntry()
                    }
                }
            }
            check(File(root, "python3.14/encodings/__init__.py").isFile) {
                "Biblioteca padrão Python incompleta"
            }
            File(pending, ".qeltravyx_ready").writeText("3.14.9\n")
            if (destination.exists()) destination.deleteRecursively()
            check(pending.renameTo(destination)) {
                "Não foi possível ativar o Python preparado"
            }
            RuntimePip.prepare(this)
        } catch (e: Exception) {
            pending.deleteRecursively()
            throw e
        }
    }

    private fun prepareWorkspace() {
        val root = File(filesDir, "workspace")
        listOf("projects", "scripts", "tmp", "logs").forEach { name ->
            check(File(root, name).isDirectory || File(root, name).mkdirs()) {
                "Não foi possível criar a pasta $name"
            }
        }
        val profileDir = File(filesDir, ".qeltravyx")
        check(profileDir.isDirectory || profileDir.mkdirs()) {
            "Não foi possível criar a configuração do terminal"
        }
        val profile = File(profileDir, "profile.sh")
        if (!profile.exists()) {
            assets.open("qeltravyx/profile.sh").use { input ->
                profile.outputStream().use { output -> input.copyTo(output) }
            }
        }
        // Add new Bash commands without replacing an existing user profile.
        val bashMarker = "# QELTRAVYX_BASH_0_5_START"
        if (!profile.readText(Charsets.UTF_8).contains(bashMarker)) {
            val extension = assets.open("qeltravyx/bash-extension.sh")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            check(extension.contains(bashMarker)) { "Extensao Bash invalida" }
            profile.appendText("\n" + extension + "\n", Charsets.UTF_8)
        }
        // QELTRAVYX_BASH_0_5_1_INSTALL: preserve existing user Bash settings.
        val bashrc = File(profileDir, "bashrc")
        if (!bashrc.exists()) {
            assets.open("qeltravyx/bashrc").use { input ->
                bashrc.outputStream().use { output -> input.copyTo(output) }
            }
        }
        val bash051Marker = "# QELTRAVYX_BASH_0_5_1_START"
        if (!profile.readText(Charsets.UTF_8).contains(bash051Marker)) {
            val extension051 = assets.open("qeltravyx/bash051-extension.sh")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            check(extension051.contains(bash051Marker)) { "Extensao Bash 0.5.1 invalida" }
            profile.appendText("\n" + extension051 + "\n", Charsets.UTF_8)
        }
        val pyMarker = "# QELTRAVYX_PYTHON_0_6_START"
        val pyExtension = assets.open("qeltravyx/python-extension.sh")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
        check(pyExtension.contains(pyMarker)) { "Extensão Python inválida" }
        if (!profile.readText(Charsets.UTF_8).contains(pyMarker)) {
            profile.appendText("\n" + pyExtension + "\n", Charsets.UTF_8)
        }
        if (!bashrc.readText(Charsets.UTF_8).contains(pyMarker)) {
            bashrc.appendText("\n" + pyExtension + "\n", Charsets.UTF_8)
        }
        // Alpha 0.6.1: migrate existing shell profiles without erasing user files.
        val py061Marker = "# QELTRAVYX_PYTHON_0_6_1_START"
        val py061Extension = assets.open("qeltravyx/python061-extension.sh")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
        check(py061Extension.contains(py061Marker)) { "Extensão Python 0.6.1 inválida" }
        if (!profile.readText(Charsets.UTF_8).contains(py061Marker)) {
            profile.appendText("\n" + py061Extension + "\n", Charsets.UTF_8)
        }
        if (!bashrc.readText(Charsets.UTF_8).contains(py061Marker)) {
            bashrc.appendText("\n" + py061Extension + "\n", Charsets.UTF_8)
        }
        // Append only: preserve Python functions, user profiles and existing packages.
        val runtimeMarker = "# QELTRAVYX_RUNTIME_BASE_1_START"
        val runtimeExtension = assets.open("qeltravyx/runtime-extension.sh")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
        check(runtimeExtension.contains(runtimeMarker)) { "Extensão de runtime inválida" }
        for (shellProfile in listOf(profile, bashrc)) {
            if (!shellProfile.readText(Charsets.UTF_8).contains(runtimeMarker)) {
                shellProfile.appendText("\n" + runtimeExtension + "\n", Charsets.UTF_8)
            }
        }
        // QELTRAVYX_QPKG_ALPHA08: initialize trusted built-in qpkg manager.
        // Existing user profiles, Python runtime, Bash history and projects stay intact.
        val qpkgMarker = "# QELTRAVYX_QPKG_0_8_START"
        val qpkgExtension = assets.open("qeltravyx/qpkg-extension.sh")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
        check(qpkgExtension.contains(qpkgMarker)) { "qpkg extension inválida" }
        if (!profile.readText(Charsets.UTF_8).contains(qpkgMarker)) {
            profile.appendText("\n" + qpkgExtension + "\n", Charsets.UTF_8)
        }
        if (!bashrc.readText(Charsets.UTF_8).contains(qpkgMarker)) {
            bashrc.appendText("\n" + qpkgExtension + "\n", Charsets.UTF_8)
        }
        // App-owned launcher; user profiles, history and workspace stay intact.
        val sessionRc = File(profileDir, "session.bashrc")
        val sessionConfig = assets.open("qeltravyx/session.bashrc")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
        if (!sessionRc.exists() || sessionRc.readText(Charsets.UTF_8) != sessionConfig) {
            sessionRc.writeText(sessionConfig, Charsets.UTF_8)
        }
        val sessionMarker = "# QELTRAVYX_BASH_SESSION_1_START"
        if (!profile.readText(Charsets.UTF_8).contains(sessionMarker)) {
            val extension = assets.open("qeltravyx/bash-session-extension.sh")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            check(extension.contains(sessionMarker)) { "Extensão de sessão Bash inválida" }
            profile.appendText("\n" + extension + "\n", Charsets.UTF_8)
        }
    }

    private fun prepareQpkg() {
        // QELTRAVYX_QPKG_ALPHA08: install app-authored management files on first launch.
        val dir = File(filesDir, ".qeltravyx")
        check(dir.isDirectory || dir.mkdirs()) { "qpkg: pasta de configuração indisponível" }
        val ready = File(dir, ".qpkg_08_ready")
        if (ready.exists() && File(dir,"qpkg.py").isFile &&
            File(dir,"vendor/packaging/__init__.py").isFile && File(dir,"vendor/cacert.pem").isFile) return

        // Copy bundled qpkg script. Do not touch installed packages under workspace/.
        assets.open("qeltravyx/qpkg.py").use { input ->
            val tmp = File(dir, "qpkg.py.tmp")
            tmp.outputStream().use { output -> input.copyTo(output) }
            check(tmp.renameTo(File(dir,"qpkg.py"))) { "qpkg: falha ao ativar script" }
        }
        assets.open("qeltravyx/qpkg-vendor.zip").use { input ->
            java.util.zip.ZipInputStream(input).use { zip ->
                val safeRoot = dir.canonicalPath + File.separator
                var entry = zip.nextEntry
                var count = 0
                while (entry != null) {
                    check(++count <= 150) { "qpkg: excesso de arquivos de suporte" }
                    val out = File(dir, entry.name).canonicalFile
                    check(out.path.startsWith(safeRoot)) { "qpkg: caminho inválido" }
                    if (entry.isDirectory) {
                        check(out.isDirectory || out.mkdirs())
                    } else {
                        check(out.parentFile?.isDirectory == true || out.parentFile?.mkdirs() == true)
                        out.outputStream().use { output -> zip.copyTo(output) }
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
        }
        ready.writeText("0.8.0\n", Charsets.UTF_8)
    }

    private fun launchPty(id: Int) {
        prepareWorkspace()
        prepareQpkg()
        val info = nativeCreatePty(
            filesDir.absolutePath, applicationInfo.nativeLibraryDir, 24, 80
        )
        require(info.size == 2 && info[0] >= 0 && info[1] > 0) {
            "PTY inválido retornado pelo sistema"
        }
        val fd = ParcelFileDescriptor.adoptFd(info[0])
        val session = PtySession(info[1], fd, FileOutputStream(fd.fileDescriptor))
        sessions[id] = session
        Thread({
            try {
                InputStreamReader(FileInputStream(fd.fileDescriptor), Charsets.UTF_8)
                    .use { reader ->
                        val chars = CharArray(4096)
                        while (!session.closed.get()) {
                            val count = reader.read(chars)
                            if (count < 0) break
                            if (sessions[id] === session) {
                                emit("output", id, String(chars, 0, count))
                            }
                        }
                    }
            } catch (e: Exception) {
                if (sessions[id] === session && !session.closed.get()) {
                    emit("output", id, "\r\n[Erro ao ler PTY: ${e.message}]\r\n")
                }
            } finally {
                sessions.remove(id, session)
                if (session.closed.compareAndSet(false, true)) {
                    try { nativeSignalPty(session.pid) } catch (_: Exception) { }
                    try { session.fd.close() } catch (_: Exception) { }
                    emit("exit", id, "")
                }
                // Reap child process; do not leave zombie processes behind.
                try { nativeWaitPty(session.pid) } catch (_: Exception) { }
            }
        }, "qeltravyx-pty-reader-$id").start()
    }

    private fun closePty(id: Int) {
        val session = sessions.remove(id) ?: return
        if (session.closed.compareAndSet(false, true)) {
            try { nativeSignalPty(session.pid) } catch (_: Exception) { }
            worker.execute { try { session.fd.close() } catch (_: Exception) { } }
        }
    }

    private fun emit(type: String, id: Int, data: String) {
        ui.post { eventSink?.success(mapOf("type" to type, "sessionId" to id, "data" to data)) }
    }

    private fun readHistory(): List<String> {
        val pref = getSharedPreferences("qeltravyx_terminal", MODE_PRIVATE)
        return try {
            val arr = JSONArray(pref.getString("history_v1", "[]") ?: "[]")
            (0 until arr.length()).map { arr.optString(it) }
        } catch (_: Exception) { emptyList() }
    }

    private fun recordHistory(command: String) {
        val history = readHistory().toMutableList()
        if (history.lastOrNull() != command) history.add(command)
        while (history.size > 100) history.removeAt(0)
        val arr = JSONArray()
        history.forEach { arr.put(it) }
        getSharedPreferences("qeltravyx_terminal", MODE_PRIVATE)
            .edit().putString("history_v1", arr.toString()).apply()
    }

    override fun onDestroy() {
        sessions.keys.toList().forEach { closePty(it) }
        worker.shutdown()
        super.onDestroy()
    }
}
