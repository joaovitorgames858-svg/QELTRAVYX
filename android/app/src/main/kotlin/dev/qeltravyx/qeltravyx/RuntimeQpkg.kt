package dev.qeltravyx.qeltravyx

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipInputStream

/** Refresh only the app-owned manager; installed packages and registry stay untouched. */
internal object RuntimeQpkg {
    @Synchronized
    fun prepare(context: Context) {
        val root = context.filesDir.canonicalFile
        val directory = File(root, ".qeltravyx")
        check(directory.canonicalFile == directory.absoluteFile) { "Link na configuração QPKG" }
        check(directory.isDirectory || directory.mkdir())
        val script = File(directory, "qpkg.py")
        check(script.canonicalFile == script.absoluteFile) { "Link no QPKG" }
        val content = context.assets.open("qeltravyx/qpkg.py").use { it.readBytes() }
        check(content.size <= 128 * 1024)
        val vendor = File(directory, "vendor")
        check(vendor.canonicalFile == vendor.absoluteFile) { "Link no vendor QPKG" }
        if (!vendor.exists()) {
            val expected = context.assets.open("qeltravyx/qpkg-vendor.sha256")
                .bufferedReader().use { it.readText().trim() }
            val data = context.assets.open("qeltravyx/qpkg-vendor.zip").use { input ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    check(buffer.size() + n <= 2 * 1024 * 1024)
                    buffer.write(chunk, 0, n)
                }
                buffer.toByteArray()
            }
            val sha = MessageDigest.getInstance("SHA-256").digest(data)
                .joinToString("") { "%02x".format(it.toInt() and 255) }
            check(sha == expected) { "Hash vendor QPKG divergente" }
            val pending = File(directory, ".vendor-${UUID.randomUUID()}")
            check(pending.mkdir())
            try {
                var total = 0L
                val seen = HashSet<String>()
                ZipInputStream(data.inputStream()).use { zip ->
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        check(!entry.isDirectory && entry.name.startsWith("vendor/") &&
                            !entry.name.contains('\\') && !entry.name.contains('\u0000') &&
                            entry.name.split('/').all { it !in listOf("", ".", "..") })
                        check(seen.add(entry.name) && seen.size <= 150)
                        val out = File(pending, entry.name)
                        check(out.canonicalPath.startsWith(pending.canonicalPath + File.separator))
                        check(out.parentFile!!.isDirectory || out.parentFile!!.mkdirs())
                        out.outputStream().use { stream ->
                            val chunk = ByteArray(8192)
                            while (true) {
                                val n = zip.read(chunk)
                                if (n < 0) break
                                total += n
                                check(total <= 4 * 1024 * 1024)
                                stream.write(chunk, 0, n)
                            }
                        }
                    }
                }
                check(File(pending, "vendor/packaging/__init__.py").isFile && File(pending, "vendor/cacert.pem").isFile)
                check(File(pending, "vendor").renameTo(vendor))
            } finally { pending.deleteRecursively() }
        }
        check(File(vendor, "packaging/__init__.py").isFile && File(vendor, "cacert.pem").isFile) {
            "Vendor existente incompleto preservado; revisão necessária"
        }
        if (!script.isFile || !script.readBytes().contentEquals(content)) {
            if (script.isFile) {
                val backup = File(directory, "qpkg.py.backup-${UUID.randomUUID()}")
                check(script.length() <= 128 * 1024)
                script.copyTo(backup, overwrite = false)
            }
            val temp = File.createTempFile("qpkg-", ".tmp", directory)
            try {
                temp.outputStream().use { it.write(content); it.fd.sync() }
                check(temp.renameTo(script)) { "Falha ao ativar QPKG" }
            } finally { temp.delete() }
        }
    }
}
