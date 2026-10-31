package dev.qeltravyx.qeltravyx

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipInputStream

/** APK-owned data only. Executable Node remains in PackageManager's nativeLibraryDir. */
internal object RuntimeNpm {
    @Synchronized
    fun prepare(context: Context): String? {
        if (context.assets.list("qeltravyx/npm")?.contains("npm-runtime.zip") != true) return null
        var staging: File? = null
        try {
            val expected = context.assets.open("qeltravyx/npm/npm-runtime.sha256")
                .bufferedReader().use { it.readText().trim() }
            require(expected.matches(Regex("[0-9a-f]{64}"))) { "Hash npm inválido" }
            // Canonicalize the app root once; accept Android aliases, reject internal links.
            var parent = context.filesDir.canonicalFile
            for (name in listOf(".qeltravyx", "runtimes")) {
                val child = File(parent, name)
                check(child.canonicalFile == child.absoluteFile) { "Link interno no runtime" }
                check(child.isDirectory || child.mkdir())
                parent = child
            }
            val target = File(parent, "npm")
            check(target.canonicalFile == target.absoluteFile) { "Link interno no npm" }
            if (target.exists()) {
                val marker = File(target, ".qeltravyx_sha256")
                check(marker.canonicalFile == marker.absoluteFile)
                check(marker.isFile && marker.readText() == expected &&
                    File(target, "bin/npm-cli.js").isFile) {
                    "npm existente preservado; migração requer revisão"
                }
                return null
            }
            // Verify compressed bytes before extracting. Bound both compressed/unpacked sizes.
            val pending = File(parent, ".npm-${UUID.randomUUID()}")
            check(pending.mkdir())
            staging = pending
            val archive = File(pending, "payload.zip")
            val sha = MessageDigest.getInstance("SHA-256")
            context.assets.open("qeltravyx/npm/npm-runtime.zip").use { input ->
                archive.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n
                        check(total <= 24L * 1024 * 1024) { "ZIP npm excessivo" }
                        sha.update(buffer, 0, n)
                        output.write(buffer, 0, n)
                    }
                }
            }
            check(sha.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == expected) {
                "SHA-256 npm divergente"
            }
            val tree = File(pending, "tree")
            check(tree.mkdir())
            val names = HashSet<String>()
            var total = 0L
            ZipInputStream(archive.inputStream().buffered()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val name = entry.name
                    check(!entry.isDirectory && name.isNotEmpty() && !name.contains('\\') &&
                        !name.contains('\u0000') && name.split('/').all { it !in listOf("", ".", "..") }) {
                        "Caminho npm inválido"
                    }
                    check(names.add(name) && names.size <= 10000) { "Entradas npm inválidas" }
                    val out = File(tree, name)
                    check(out.canonicalPath.startsWith(tree.canonicalPath + File.separator))
                    check(out.parentFile!!.isDirectory || out.parentFile!!.mkdirs())
                    out.outputStream().use { output ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val n = zip.read(buffer)
                            if (n < 0) break
                            total += n
                            check(total <= 64L * 1024 * 1024) { "Extração npm excessiva" }
                            output.write(buffer, 0, n)
                        }
                    }
                }
            }
            check(File(tree, "bin/npm-cli.js").isFile && File(tree, "package.json").isFile &&
                File(tree, "node_modules/semver/package.json").isFile) { "Árvore npm incompleta" }
            File(tree, ".qel-global-npmrc").writeText("")
            File(tree, ".qeltravyx_sha256").writeText(expected)
            check(!target.exists() && tree.renameTo(target)) { "Ativação npm falhou" }
            return null
        } catch (failure: Exception) {
            return "npm não preparado: " + failure.javaClass.simpleName + ": " + failure.message.orEmpty().take(180)
        } finally {
            // Only this invocation's unactivated staging. Never delete existing npm/user data.
            staging?.deleteRecursively()
        }
    }
}
