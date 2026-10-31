package android.content
import java.io.File
class Assets(private val root: File) {
    fun list(path: String): Array<String>? = File(root, path).list()
    fun open(path: String) = File(root, path).inputStream()
}
class Context(val filesDir: File, root: File) {
    val assets = Assets(root)
}
