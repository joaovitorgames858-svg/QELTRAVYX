package dev.qeltravyx.qeltravyx

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipInputStream

/** Installs only APK-owned Python data. Never alters the native Python launcher. */
internal object RuntimePip {
    @Synchronized
    fun prepare(context: Context) {
        val home = File(context.filesDir, "python-runtime-3.14.9")
        val error = File(home, ".qeltravyx_pip_error")
        try {
            val expected = context.assets.open("qeltravyx/python/pip-runtime.sha256")
                .bufferedReader().use { it.readText().trim() }
            require(expected.matches(Regex("[0-9a-f]{64}")))
            val site = File(home, "lib/python3.14/site-packages")

                        // QELTRAVYX_PIP_ANDROID_PATH_ALIAS_FIX_V1
                        // Normaliza o pai antes de comparar cada filho.
                        // Aceita aliases legítimos do Android, mas
                        // rejeita links simbólicos internos inesperados.
                        val libDir = File(home, "lib")
                        val pythonDir = File(libDir, "python3.14")

                        for (directory in listOf(libDir, pythonDir, site)) {
                            val parent = directory.parentFile!!.canonicalFile
                            val expected = File(parent, directory.name).absoluteFile

                            check(directory.canonicalFile == expected) {
                                "Link interno não suportado: ${directory.name}"
                            }
                        }

            check(site.isDirectory || site.mkdirs())
            val marker = File(site, ".qeltravyx_pip")
            val pip = File(site, "pip")
            val metadata = File(site, "pip-26.2.2.dist-info")
            if (marker.isFile && marker.readText() == expected &&
                File(pip, "_qeltravyx.py").isFile && File(metadata, "METADATA").isFile) {
                error.delete()
                return
            }
            // Preserve any pip already installed by the user; no destructive migration.

                        val resolvedSite = site.canonicalFile

                        check(
                            pip.canonicalFile ==
                                File(resolvedSite, pip.name).absoluteFile &&
                            metadata.canonicalFile ==
                                File(resolvedSite, metadata.name).absoluteFile
                        ) {
                            "Link interno não suportado nos pacotes pip"
                        }

            check(!pip.exists() && !metadata.exists()) { "pip existente preservado; migração manual necessária" }
            val staging = File(site, ".pip-${UUID.randomUUID()}")
            check(staging.mkdir())
            try {
                val data = context.assets.open("qeltravyx/python/pip-runtime.zip").use { it.readBytes() }
                val actual = MessageDigest.getInstance("SHA-256").digest(data)
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
                check(actual == expected) { "SHA-256 do pip empacotado divergente" }
                ZipInputStream(data.inputStream()).use { zip ->
                    var count = 0
                    var total = 0L
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        check(++count <= 2000)
                        val target = File(staging, entry.name).canonicalFile
                        check(target.path.startsWith(staging.canonicalPath + File.separator))
                        check(entry.name.startsWith("pip/") || entry.name.startsWith("pip-26.2.2.dist-info/"))
                        if (entry.isDirectory) check(target.isDirectory || target.mkdirs())
                        else {
                            check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs())
                            target.outputStream().use { output ->
                                val buffer = ByteArray(8192)
                                while (true) {
                                    val size = zip.read(buffer)
                                    if (size < 0) break
                                    total += size
                                    check(total <= 16L * 1024 * 1024)
                                    output.write(buffer, 0, size)
                                }
                            }
                        }
                    }
                }
                check(File(staging, "pip/_internal/cli/main.py").isFile)
                check(File(staging, "pip/_qeltravyx.py").isFile)
                val stagedPip = File(staging, "pip")
                check(stagedPip.renameTo(pip))
                try {
                    check(File(staging, metadata.name).renameTo(metadata))
                    marker.writeText(expected)
                } catch (failure: Exception) {
                    // Only data created by this invocation is rolled back.
                    pip.renameTo(stagedPip)
                    metadata.renameTo(File(staging, metadata.name))
                    throw failure
                }
                error.delete()
            } finally { staging.deleteRecursively() }
        } catch (failure: Exception) {
            // A pip provisioning failure must never disable the existing Python runtime.
            runCatching { error.writeText("pip não preparado: " + (failure.message ?: failure.javaClass.simpleName)) }
        }
    }
}
