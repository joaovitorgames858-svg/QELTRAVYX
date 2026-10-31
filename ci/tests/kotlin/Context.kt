package android.content
import java.io.File
class Assets(private val root: File) {
    fun list(path: String): Array<String>? = File(root, path).list()
    fun open(path: String) = File(root, path).inputStream()
}
class ApplicationInfo(val nativeLibraryDir: String)
class Context(val filesDir: File, root: File) {
    val cacheDir = File(filesDir, "cache").apply { mkdirs() }
    val applicationInfo = ApplicationInfo(File(filesDir, "nativeLibs").path)
    val assets = Assets(root)
}
