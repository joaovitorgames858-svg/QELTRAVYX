package io.flutter.plugin.common
interface BinaryMessenger
class MethodCall(val method: String) {
    fun <T> argument(name: String): T? = null
}
class MethodChannel(messenger: BinaryMessenger, name: String) {
    interface Result {
        fun notImplemented()
        fun success(value: Any?)
        fun error(code: String, message: String?, details: Any?)
    }
    fun setMethodCallHandler(handler: (MethodCall, Result) -> Unit) {}
}
