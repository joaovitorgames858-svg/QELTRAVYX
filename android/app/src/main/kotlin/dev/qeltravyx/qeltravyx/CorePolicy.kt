package dev.qeltravyx.qeltravyx

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** CORE V1 policy: no network, shell strings or inference dependencies. */
internal object CorePolicy {
    const val MAX_BYTES = 12000
    const val MAX_ENTRIES = 200
    private val sensitive = Regex(
        "secret|credential|token|password|senha|api[_-]?key|service.account|\\.env|sk-[\\w-]{12,}|bearer\\s|PRIVATE KEY",
        RegexOption.IGNORE_CASE
    )

    fun path(value: String, folder: Boolean = false) {
        require(value.length <= 180 && !value.contains("..") && !value.contains('\\')) { "Caminho CORE invalido" }
        val parts = value.split('/')
        require(parts.size <= 4 && parts.all { Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,70}").matches(it) }) { "Caminho CORE invalido" }
        require(!sensitive.containsMatchIn(value)) { "Arquivo sensivel bloqueado no CORE" }
        require(folder || Regex(".*\\.(py|sh|json|txt)", RegexOption.IGNORE_CASE).matches(value)) { "Extensao CORE invalida" }
    }

    fun read(file: File): String {
        require(file.isFile && file.length() <= MAX_BYTES) { "Arquivo CORE inexistente ou maior que 12 KB" }
        // Bound the actual stream too, in case another process grows the file.
        val bytes = ByteArray(MAX_BYTES + 1)
        val count = file.inputStream().use { input ->
            var total = 0
            while (total < bytes.size) {
                val size = input.read(bytes, total, bytes.size - total)
                if (size < 0) break
                total += size
            }
            total
        }
        require(count <= MAX_BYTES) { "CORE limitado a 12 KB" }
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val text = decoder.decode(ByteBuffer.wrap(bytes, 0, count)).toString()
        content(text)
        return text
    }

    fun content(value: String) {
        require(value.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "CORE limitado a 12 KB" }
        require(!sensitive.containsMatchIn(value)) { "Conteudo sensivel bloqueado no CORE" }
        require(value.none { (it.code in 0..31 && it != '\n' && it != '\r' && it != '\t') || it.code in 127..159 }) { "Controle binario bloqueado no CORE" }
    }

    val actions = setOf("list", "createPython", "read", "verifyPython", "repairBom", "diagnostics", "unsupported")
    val outcomes = setOf("completed", "failed", "cancelled")
}
