package com.aadhinitinytales.cricketreplay

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

// All operations run on LocalSession's serial state queue. Bytes never enter the WebView.
internal class SampleTransfer(private val queue: ScheduledExecutorService, private val directory: File) {
    companion object {
        const val CHUNK_SIZE = 16 * 1024
        const val MAX_BYTES = 32 * 1024 * 1024
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
        fun checksum(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(CHUNK_SIZE)
                while (true) { val count = stream.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            return hex(digest.digest())
        }
    }
    private var handle: RandomAccessFile? = null
    private var partial: File? = null
    var completed: File? = null; private set
    private var id = ""
    private var total = 0
    private var offset = 0
    private var sha = ""
    private var digest = MessageDigest.getInstance("SHA-256")
    private var started = 0L
    private var timer: ScheduledFuture<*>? = null
    private var sending = false
    private var slow = false
    private var phase = "idle"
    private val history = mutableListOf<JSONObject>()
    var state = JSONObject().put("state", "idle").put("bytes", 0).put("totalBytes", 0).put("checksumVerified", false); private set
    var onSend: ((String, JSONObject) -> Unit)? = null
    var onFailure: ((String) -> Unit)? = null
    val active get() = phase in setOf("offer", "sending", "receiving", "finishing")
    private fun update(phase: String, detail: String) {
        this.phase = phase
        state = JSONObject().put("state", phase).put("detail", detail).put("requestId", id).put("bytes", offset)
            .put("totalBytes", total).put("sha256", sha).put("checksumVerified", phase == "ready" || phase == "complete")
        if (phase == "ready" || phase == "complete") {
            val seconds = ((System.nanoTime() - started) / 1_000_000_000.0).coerceAtLeast(0.000001)
            state.put("durationSeconds", seconds).put("throughputMBps", total / seconds / 1_000_000.0)
            history.add(JSONObject(state.toString())); while (history.size > 10) history.removeAt(0)
        }
        state.put("attempts", JSONArray(history))
    }
    private fun arm() {
        timer?.cancel(false)
        if (active) {
            val request = id
            timer = queue.schedule({ if (id == request && active) fail("Transfer timed out; reconnect and retry") }, 30, TimeUnit.SECONDS)
        }
    }
    private fun send(packet: JSONObject) {
        arm(); val request = id
        if (slow && packet.optString("kind") == "chunk") queue.schedule({
            if (id == request && active) onSend?.invoke(request, packet)
        }, 500, TimeUnit.MILLISECONDS)
        else onSend?.invoke(id, packet)
    }
    private fun clearPartial() {
        timer?.cancel(false); timer = null; runCatching { handle?.close() }; handle = null
        partial?.delete(); partial = null
    }
    fun cancel(reason: String) { val interrupted = active; clearPartial(); if (interrupted) update("failed", reason) }
    fun cleanup() {
        check(!active) { "Stop the transfer before cleaning files" }
        clearPartial(); check(!directory.exists() || directory.deleteRecursively()) { "Cannot remove received samples" }
        completed = null; history.clear(); id = ""; offset = 0; total = 0; sha = ""; update("idle", "Temporary received files removed")
    }
    private fun prepare() {
        check(!active) { "A transfer is already active" }; clearPartial()
        completed?.let { check(!it.exists() || it.delete()) { "Cannot remove previous sample" } }; completed = null
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create transfer directory" }
        offset = 0; digest = MessageDigest.getInstance("SHA-256"); started = System.nanoTime()
    }
    fun begin(file: File, slow: Boolean = false) {
        check(!active) { "A transfer is already active" }
        val size = file.length(); require(size in 1..MAX_BYTES.toLong()) { "Sample must be 1–32 MiB" }
        val checksum = checksum(file); prepare()
        id = UUID.randomUUID().toString(); total = size.toInt(); sha = checksum; sending = true; this.slow = slow
        try { handle = RandomAccessFile(file, "r") } catch (error: Exception) { update("failed", "Cannot read sample"); throw error }
        update("offer", "Waiting for host to accept sample"); send(JSONObject().put("kind", "offer").put("bytes", total).put("sha256", sha))
    }
    private fun fail(detail: String) { clearPartial(); update("failed", detail); onFailure?.invoke(detail) }
    private fun integer(packet: JSONObject, name: String) = packet.get(name) as? Int ?: error("Invalid $name")
    fun receive(request: String, packet: JSONObject, isHost: Boolean) {
        try {
            require(SessionAuthentication.validID(request)) { "Invalid request ID" }
            val kind = packet.getString("kind")
            if (kind == "offer") {
                val bytes = integer(packet, "bytes"); val hash = packet.getString("sha256")
                require(isHost && bytes in 1..MAX_BYTES && Regex("[0-9a-f]{64}").matches(hash)) { "Invalid sample offer" }
                prepare(); id = request; total = bytes; sha = hash; sending = false; slow = false
                val file = File(directory, "$id.part"); check(file.createNewFile()) { "Cannot create partial file" }
                partial = file; handle = RandomAccessFile(file, "rw")
                update("receiving", "Receiving encrypted sample"); send(JSONObject().put("kind", "ack").put("offset", 0)); return
            }
            require(active && request == id) { "Unexpected transfer/request ID" }
            when (kind) {
                "ack" -> {
                    require(sending && phase in setOf("offer", "sending") && integer(packet, "offset") == offset) { "Invalid chunk acknowledgement" }
                    if (offset == total) {
                        handle?.close(); handle = null; update("finishing", "Waiting for host checksum verification")
                        send(JSONObject().put("kind", "end"))
                    } else {
                        val bytes = ByteArray(minOf(CHUNK_SIZE, total - offset)); checkNotNull(handle).readFully(bytes)
                        val start = offset; offset += bytes.size; update("sending", "Sending encrypted sample")
                        send(JSONObject().put("kind", "chunk").put("offset", start).put("data", Base64.encodeToString(bytes, Base64.NO_WRAP)))
                    }
                }
                "chunk" -> {
                    require(!sending && phase == "receiving" && integer(packet, "offset") == offset) { "Invalid or out-of-order chunk" }
                    val encoded = packet.getString("data"); require(encoded.length <= CHUNK_SIZE * 2) { "Oversized chunk" }
                    val bytes = Base64.decode(encoded, Base64.DEFAULT)
                    require(bytes.isNotEmpty() && bytes.size <= CHUNK_SIZE && offset + bytes.size <= total) { "Invalid chunk size" }
                    checkNotNull(handle).write(bytes); digest.update(bytes); offset += bytes.size
                    update("receiving", "Receiving encrypted sample"); send(JSONObject().put("kind", "ack").put("offset", offset))
                }
                "end" -> {
                    require(!sending && phase == "receiving" && offset == total) { "Incomplete sample" }
                    val actual = hex(digest.digest()); require(actual == sha) { "Checksum mismatch; partial sample discarded" }
                    checkNotNull(handle).fd.sync(); handle?.close(); handle = null
                    val ready = File(directory, "$id.mp4"); check(checkNotNull(partial).renameTo(ready)) { "Cannot finalize received sample" }
                    partial = null; completed = ready; timer?.cancel(false); timer = null
                    update("ready", "Complete sample verified; ready to play")
                    onSend?.invoke(id, JSONObject().put("kind", "complete").put("bytes", total).put("sha256", actual))
                }
                "complete" -> {
                    require(sending && phase == "finishing" && integer(packet, "bytes") == total && packet.getString("sha256") == sha) { "Invalid completion receipt" }
                    timer?.cancel(false); timer = null; update("complete", "Host verified the complete sample")
                }
                else -> error("Unknown transfer message")
            }
        } catch (error: Exception) { fail(error.message ?: "Transfer failed") }
    }
}
