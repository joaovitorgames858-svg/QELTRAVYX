package dev.qeltravyx.qeltravyx

import android.content.Context
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

private fun payload(assets: File, entries: Map<String, String>, goodHash: Boolean = true) {
    val root = File(assets, "qeltravyx/npm").apply { mkdirs() }
    val zip = File(root, "npm-runtime.zip")
    ZipOutputStream(zip.outputStream()).use { output ->
        for ((name, text) in entries) {
            output.putNextEntry(ZipEntry(name)); output.write(text.toByteArray()); output.closeEntry()
        }
    }
    val hash = MessageDigest.getInstance("SHA-256").digest(zip.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) }
    File(root, "npm-runtime.sha256").writeText(if (goodHash) hash else "0".repeat(64))
}

fun main() {
    val temp = Files.createTempDirectory("qel-kotlin-").toFile()
    try {
        val assets = File(temp, "assets").apply { mkdir() }
        val files = File(temp, "files").apply { mkdir() }
        val context = Context(files, assets)
        check(RuntimeNpm.prepare(context) == null) // Optional component absent.
        val entries = mapOf("bin/npm-cli.js" to "// fixture", "package.json" to "{}", "node_modules/semver/package.json" to "{}")
        payload(assets, entries, false)
        check(RuntimeNpm.prepare(context)!!.contains("SHA-256"))
        check(!File(files, ".qeltravyx/runtimes/npm").exists())
        payload(assets, entries + ("../escape" to "bad"))
        check(RuntimeNpm.prepare(context) != null)
        check(!File(files, ".qeltravyx/runtimes/escape").exists())
        payload(assets, entries)
        check(RuntimeNpm.prepare(context) == null)
        check(RuntimeNpm.prepare(context) == null) // Idempotent.
        val cli = File(files, ".qeltravyx/runtimes/npm/bin/npm-cli.js")
        check(cli.readText() == "// fixture")
        payload(assets, entries + ("new.txt" to "changed"))
        check(RuntimeNpm.prepare(context)!!.contains("preservado"))
        check(cli.readText() == "// fixture")
        val alias = File(temp, "alias")
        Files.createSymbolicLink(alias.toPath(), files.toPath())
        payload(assets, entries)
        check(RuntimeNpm.prepare(Context(alias, assets)) == null) // App root alias.
        val fresh = File(temp, "fresh").apply { mkdir() }
        Files.createSymbolicLink(File(fresh, ".qeltravyx").toPath(), File(files, ".qeltravyx").toPath())
        check(RuntimeNpm.prepare(Context(fresh, assets))!!.contains("Link interno"))
        val realAssets = File("android/app/src/main/assets/qeltravyx")
        val qassets = File(assets, "qeltravyx").apply { mkdirs() }
        for (name in listOf("qpkg.py", "qpkg-vendor.zip", "qpkg-vendor.sha256")) {
            File(realAssets, name).copyTo(File(qassets, name), overwrite = true)
        }
        RuntimeQpkg.prepare(context)
        check(File(files, ".qeltravyx/vendor/packaging/__init__.py").isFile)
        RuntimeQpkg.prepare(context)
        File(files, ".qeltravyx/qpkg.py").writeText("# user customized")
        RuntimeQpkg.prepare(context)
        val backups = File(files, ".qeltravyx").listFiles()!!.filter { it.name.startsWith("qpkg.py.backup-") }
        check(backups.size == 1 && backups.first().readText() == "# user customized")
        println("RuntimeQpkg JVM: vendor install/idempotence/script backup PASS; not Android evidence")
        println("RuntimeNpm JVM: absence/hash/zip-slip/idempotence/upgrade preservation/root alias/internal link PASS; not Android evidence")
    } finally { temp.deleteRecursively() }
}
