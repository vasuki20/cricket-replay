package com.aadhinitinytales.cricketreplay

import org.json.JSONObject
import java.security.MessageDigest
import android.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import java.security.SecureRandom

// Byte-for-byte compatible with the iOS protocol-v2 HMAC transcript.
internal class SessionAuthentication(secret: String, private val role: String, val nonce: String = UUID.randomUUID().toString()) {
    private val key = SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256")
    private var peerNonce: String? = null
    private var sent = 0
    private var received = 0
    private val peerRole get() = if (role == "host") "camera" else "host"
    fun hello() = JSONObject().put("type", "hello").put("nonce", nonce).put("role", role).put("protocol", 2)
    fun acceptHello(frame: JSONObject): Boolean {
        val n = frame.optString("nonce")
        if (peerNonce != null || frame.optString("type") != "hello" || frame.opt("protocol") != 2 ||
            !validID(n) || frame.optString("role") != peerRole) return false
        peerNonce = n; return true
    }
    private fun mac(sender: String, receiver: String, direction: String, sequence: Int, type: String, id: String, payload: String): ByteArray {
        val engine = Mac.getInstance("HmacSHA256"); engine.init(key)
        return engine.doFinal("cricket-p0-v2|$sender|$receiver|$direction|$sequence|$type|$id|$payload".toByteArray(Charsets.UTF_8))
    }
    fun signed(type: String, id: String = UUID.randomUUID().toString(), payload: String = ""): JSONObject {
        val peer = checkNotNull(peerNonce); sent++
        return JSONObject().put("type", type).put("id", id).put("seq", sent).put("payload", payload)
            .put("mac", Base64.encodeToString(mac(nonce, peer, role, sent, type, id, payload), Base64.NO_WRAP))
    }
    fun verify(frame: JSONObject): Boolean = try {
        val peer = checkNotNull(peerNonce)
        val sequence = frame.get("seq") as? Int ?: error("Sequence missing")
        val type = frame.getString("type"); val id = frame.getString("id")
        require(sequence == received + 1 && type in setOf("auth", "ready", "ping", "pong", "status", "statusReply", "transfer") && validID(id))
        val actual = Base64.decode(frame.getString("mac"), Base64.DEFAULT)
        require(actual.size == 32 && MessageDigest.isEqual(actual, mac(peer, nonce, peerRole, sequence, type, id, frame.optString("payload", ""))))
        received = sequence; true
    } catch (_: Exception) { false }
    private fun transferKey(direction: String): SecretKeySpec {
        val peer = checkNotNull(peerNonce)
        val host = if (role == "host") nonce else peer
        val camera = if (role == "camera") nonce else peer
        fun hmac(key: ByteArray, bytes: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256")); doFinal(bytes)
        }
        // RFC 5869 extract + first expand block (32 bytes), matching CryptoKit HKDF.
        val extracted = hmac("$host|$camera".toByteArray(Charsets.UTF_8), key.encoded)
        return SecretKeySpec(hmac(extracted, "cricket-p0-v2-aes-gcm-$direction".toByteArray(Charsets.UTF_8) + byteArrayOf(1)), "AES")
    }
    fun encrypt(packet: JSONObject, id: String): String {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, transferKey(role), GCMParameterSpec(128, iv))
        cipher.updateAAD(id.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + cipher.doFinal(packet.toString().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }
    fun decrypt(payload: String, id: String): JSONObject {
        require(payload.length <= 60_000) { "Oversized encrypted packet" }
        val combined = Base64.decode(payload, Base64.DEFAULT)
        require(combined.size >= 28) { "Invalid encrypted packet" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, transferKey(peerRole), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        cipher.updateAAD(id.toByteArray(Charsets.UTF_8))
        return JSONObject(String(cipher.doFinal(combined.copyOfRange(12, combined.size)), Charsets.UTF_8))
    }
    companion object { fun validID(value: String) = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}").matches(value) }
}
