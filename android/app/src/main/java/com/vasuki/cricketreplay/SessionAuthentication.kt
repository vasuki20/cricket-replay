package com.aadhinitinytales.cricketreplay

import org.json.JSONObject
import java.security.MessageDigest
import android.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

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
    companion object { fun validID(value: String) = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}").matches(value) }
}
