package com.aadhinitinytales.cricketreplay

import org.json.JSONObject
import java.security.SecureRandom

internal data class PairingCode(val address: String, val port: Int, val secret: String) {
    fun json() = JSONObject().put("kind", "cricket-replay-pairing").put("version", 1)
        .put("address", address).put("port", port).put("secret", secret)
    fun result() = JSONObject().put("address", address).put("port", port).put("secret", secret)
    companion object {
        fun validSecret(value: String) = Regex("[0-9a-f]{32}").matches(value)
        fun newSecret(): String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
        fun validAddress(value: String): Boolean {
            val parts = value.split('.')
            if (parts.size != 4 || parts.any { !Regex("0|[1-9][0-9]{0,2}").matches(it) }) return false
            val octets = parts.map { it.toInt() }
            if (octets.any { it !in 0..255 }) return false
            return octets[0] == 10 || (octets[0] == 172 && octets[1] in 16..31) ||
                (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        fun decode(text: String): PairingCode? = try {
            require(text.toByteArray(Charsets.UTF_8).size <= 1024)
            val json = JSONObject(text)
            require(json.get("kind") == "cricket-replay-pairing" && json.get("version") == 1)
            val address = json.getString("address"); val secret = json.getString("secret")
            val port = json.get("port") as? Int ?: error("Invalid port")
            require(validAddress(address) && validSecret(secret) && port in 1024..65535)
            PairingCode(address, port, secret)
        } catch (_: Exception) { null }
    }
}
