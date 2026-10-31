package dev.qeltravyx.qeltravyx

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/** Only fixed probes and bundled smoke tests; never launches downloaded code. */
internal class RuntimeBridge(private val context: Context, private val ui: Handler,
    private val worker: ExecutorService) {
    private val libs get() = context.applicationInfo.nativeLibraryDir
    private val pyhome get() = File(context.filesDir, "python-runtime-3.14.9")
    private val npmCli get() = File(context.filesDir, ".qeltravyx/runtimes/npm/bin/npm-cli.js")
    private val binaries = linkedMapOf("python" to "libqeltravyx_python.so",
        "node" to "libqeltravyx_node.so", "git" to "libqeltravyx_git.so",
        "bash" to "libqeltravyx_bash.so")

    private fun safeOutput(text: String) = text.take(16384)
        .replace(Regex("(?i)(token|password|senha|api[_-]?key)\\s*[:=]\\s*[^\\s]+"), "$1=[oculto]")

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "qeltravyx/runtimes").setMethodCallHandler { call, result ->
            if (call.method !in listOf("inspect", "testPython", "testRuntime")) {
                result.notImplemented()
            } else worker.execute {
                try {
                    val value = when (call.method) {
                        "inspect" -> inspect()
                        "testPython" -> testPython()
                        else -> testRuntime(call.argument<String>("name") ?: "")
                    }
                    ui.post { result.success(value) }
                } catch (error: Exception) {
                    ui.post { result.error("RUNTIME_INSPECTION", error.javaClass.simpleName, null) }
                }
            }
        }
    }

    private fun probe(command: List<String>, cwd: File = context.filesDir,
        stdin: String = "", timeout: Long = 5): Map<String, Any> {
        val started = System.nanoTime()
        var process: Process? = null
        try {
            val builder = ProcessBuilder(command).directory(cwd).redirectErrorStream(true)
            builder.environment().apply {
                clear()
                put("HOME", context.filesDir.absolutePath)
                put("PATH", "/system/bin:/system/xbin")
                put("LD_LIBRARY_PATH", libs)
                put("QELTRAVYX_PYHOME", pyhome.absolutePath)
                put("TMPDIR", context.cacheDir.absolutePath)
                put("LANG", "C.UTF-8")
                put("ANDROID_ROOT", "/system")
                put("ANDROID_DATA", "/data")
                put("GIT_CONFIG_NOSYSTEM", "1")
                put("GIT_CONFIG_GLOBAL", "/dev/null")
                put("GIT_TERMINAL_PROMPT", "0")
                put("GIT_EXEC_PATH", File(context.filesDir, ".qeltravyx/runtimes/git/libexec/git-core").absolutePath)
            }
            val child = builder.start()
            process = child
            val output = ByteArrayOutputStream()
            val reader = Thread {
                runCatching {
                    child.inputStream.use { input ->
                        val bytes = ByteArray(2048)
                        while (true) {
                            val n = input.read(bytes)
                            if (n < 0) break
                            synchronized(output) {
                                val available = (16384 - output.size()).coerceAtLeast(0)
                                output.write(bytes, 0, minOf(n, available))
                            }
                        }
                    }
                }
            }
            reader.start()
            child.outputStream.bufferedWriter().use { it.write(stdin) }
            val done = child.waitFor(timeout, TimeUnit.SECONDS)
            if (!done) child.destroyForcibly()
            reader.join(1000)
            val text = synchronized(output) { output.toString("UTF-8") }
            return mapOf("exitCode" to if (done) child.exitValue() else -1,
                "timedOut" to !done, "output" to safeOutput(text),
                "durationMs" to (System.nanoTime() - started) / 1_000_000)
        } catch (error: Exception) {
            return mapOf("exitCode" to -1, "timedOut" to false,
                "output" to safeOutput(error.javaClass.simpleName + ": " + (error.message ?: "sem detalhe")),
                "durationMs" to (System.nanoTime() - started) / 1_000_000)
        } finally { process?.destroyForcibly() }
    }

    private fun inspect(): List<Map<String, Any>> {
        val results = binaries.map { (name, library) ->
            val binary = File(libs, library)
            if (!binary.isFile) mapOf("name" to name, "status" to "Não instalado",
                "reason" to "Componente ARM64 não empacotado neste APK.")
            else if (!binary.canExecute()) mapOf("name" to name, "status" to "Incompatível",
                "reason" to "Componente do APK sem permissão de execução neste Android.")
            else if (name == "python" && !File(pyhome, ".qeltravyx_ready").isFile)
                mapOf("name" to name, "status" to "Não disponível", "reason" to "Stdlib ainda não preparada.")
            else {
                val evidence = probe(listOf(binary.absolutePath, "--version"))
                mapOf("name" to name, "status" to if (evidence["exitCode"] == 0) "Instalado" else "Erro",
                    "reason" to evidence["output"].toString(), "evidence" to evidence,
                    "path" to binary.absolutePath)
            }
        }.toMutableList()
        val python = File(libs, binaries.getValue("python"))
        if (results.first()["status"] == "Instalado") {
            val pip = probe(listOf(python.absolutePath, "-m", "pip", "--version"))
            results.add(mapOf("name" to "pip", "status" to if (pip["exitCode"] == 0) "Limitado" else "Não disponível",
                "reason" to (pip["output"].toString() + if (pip["exitCode"] == 0)
                    "\nWheels Python puros locais; sem HTTPS, compilação, scripts ou substituição de pacotes."
                    else File(pyhome, ".qeltravyx_pip_error").takeIf { it.isFile }?.readText().orEmpty()), "evidence" to pip))
        } else results.add(mapOf("name" to "pip", "status" to "Não disponível", "reason" to "Python indisponível."))
        val node = results.first { it["name"] == "node" }
        results.add(if (!npmCli.isFile) mapOf("name" to "npm", "status" to "Não instalado",
            "reason" to "CLI npm não empacotada; Node e npm são componentes distintos.")
        else if (node["status"] != "Instalado") mapOf("name" to "npm", "status" to "Não disponível",
            "reason" to "CLI presente, mas Node não executou com sucesso.")
        else {
            val evidence = probe(listOf(File(libs, binaries.getValue("node")).absolutePath,
                npmCli.absolutePath, "--version"))
            mapOf("name" to "npm", "status" to if (evidence["exitCode"] == 0) "Instalado" else "Erro",
                "reason" to evidence["output"].toString(), "evidence" to evidence)
        })
        results.add(mapOf("name" to "pkg / apt", "status" to "Não disponível", "reason" to "Não existe ambiente APT neste aplicativo. QPKG gerencia apenas pacotes Python puros."))
        return results
    }

    private fun testRuntime(name: String): Map<String, Any> {
        require(name in listOf("python", "pip", "node", "npm", "git")) { "Runtime desconhecido" }
        if (name == "python") return testPython()
        val available = inspect().first { it["name"] == name }
        if (available["status"] !in listOf("Instalado", "Limitado")) return mapOf(
            "exitCode" to -1, "timedOut" to false, "durationMs" to 0,
            "output" to "${available["status"]}: ${available["reason"]}")
        val directory = File(context.cacheDir, "runtime-smoke-${java.util.UUID.randomUUID()}")
        check(directory.mkdir())
        try {
            val python = File(libs, binaries.getValue("python")).absolutePath
            val node = File(libs, binaries.getValue("node")).absolutePath
            return when (name) {
                "pip" -> {
                    context.assets.open("qeltravyx/pip_smoke.py").use { input ->
                        File(directory, "pip_smoke.py").outputStream().use { input.copyTo(it) }
                    }
                    probe(listOf(python, "-I", "-B", "pip_smoke.py"), directory, timeout = 90)
                }
                "npm" -> probe(listOf(node, npmCli.absolutePath, "--version"), directory)
                "node" -> {
                    File(directory, "relative.txt").writeText("relative-ok")
                    File(directory, "hello.js").writeText(
                        "const fs = require('fs'); const assert = require('assert'); " +
                        "assert.strictEqual(fs.readFileSync('relative.txt', 'utf8'), 'relative-ok'); " +
                        "assert.strictEqual(process.argv[2], 'argumento ç'); " +
                        "assert.strictEqual(fs.readFileSync(0, 'utf8'), 'entrada-ok\\n'); " +
                        "console.log('QELTRAVYX NODE OK');")
                    probe(listOf(node, "hello.js", "argumento ç"), directory, "entrada-ok\n", 10)
                }
                else -> {
                    val git = File(libs, binaries.getValue("git")).absolutePath
                    File(directory, "hello.txt").writeText("local-only\n")
                    val commands = listOf(listOf("init"), listOf("add", "hello.txt"),
                        listOf("-c", "user.name=QELTRAVYX smoke", "-c", "user.email=smoke@localhost",
                            "-c", "commit.gpgsign=false", "commit", "-m", "Smoke local"),
                        listOf("status", "--porcelain"), listOf("log", "-1", "--format=%s"))
                    val output = StringBuilder()
                    var duration = 0L
                    var last: Map<String, Any> = emptyMap()
                    for (args in commands) {
                        last = probe(listOf(git) + args, directory)
                        duration += last["durationMs"] as Long
                        output.append("git ${args.joinToString(" ")}\n${last["output"]}\n")
                        if (last["exitCode"] != 0) break
                    }
                    last + mapOf("output" to safeOutput(output.toString()), "durationMs" to duration)
                }
            }
        } finally {
            // Unique directory owned by this invocation, including the test .git.
            directory.deleteRecursively()
        }
    }

    private fun testPython(): Map<String, Any> {
        val directory = File(context.cacheDir, "runtime-smoke-${java.util.UUID.randomUUID()}")
        check(directory.mkdir())
        try {
            context.assets.open("qeltravyx/runtime_smoke.py").use { input ->
                File(directory, "hello.py").outputStream().use { input.copyTo(it) }
            }
            File(directory, "relative.txt").writeText("relative-ok")
            return probe(listOf(File(libs, binaries.getValue("python")).absolutePath,
                "-I", "-B", "hello.py", "argumento ç"), directory, "entrada-ok\n", 10)
        } finally {
            // Only this invocation's own fixtures, never a user project.
            directory.listFiles()?.forEach { it.delete() }
            directory.delete()
        }
    }
}
