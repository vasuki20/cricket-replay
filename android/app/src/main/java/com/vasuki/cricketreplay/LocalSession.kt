package com.aadhinitinytales.cricketreplay

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

// Serial state owner; blocking accept/read/write never run on the UI/state thread.
internal class LocalSession(private val addresses: () -> List<String>, private val bindCamera: (Socket) -> Unit) {
    private val queue = Executors.newSingleThreadScheduledExecutor()
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(32))
    private var listener: ServerSocket? = null
    private var socket: Socket? = null
    private var auth: SessionAuthentication? = null
    private var secret = ""
    private var role = "host"
    private var handshake = "hello"
    private var authenticated = false
    private var handshakeTimeout: ScheduledFuture<*>? = null
    private val pending = mutableMapOf<String, Pair<Long, ScheduledFuture<*>>>()
    private var snapshot = emptySnapshot()
    private fun post(task: () -> Unit) { runCatching { queue.execute(task) } }
    private fun emptySnapshot() = JSONObject().put("state", "stopped").put("detail", "No session").put("role", role)
        .put("authenticated", false).put("addresses", JSONArray()).put("pingsReceived", 0).put("repliesReceived", 0)
    private fun publish(state: String, detail: String) {
        snapshot.put("state", state).put("detail", detail).put("role", role).put("authenticated", authenticated)
    }
    fun status(done: (JSONObject) -> Unit) { queue.execute { done(JSONObject(snapshot.toString())) } }
    fun startHost(secret: String, port: Int, done: (Exception?) -> Unit) { queue.execute {
        reset(); role = "host"; this.secret = secret
        try {
            val candidates = addresses(); require(candidates.isNotEmpty()) { "No Wi-Fi/hotspot IPv4 address; join Wi-Fi or enable hotspot manually" }
            snapshot.put("addresses", JSONArray(candidates)).put("port", port)
            val server = ServerSocket(); server.reuseAddress = true
            try { server.bind(InetSocketAddress(port)) } catch (error: Exception) { server.close(); throw error }
            listener = server; publish("listening", "Waiting for camera; keep this app foreground"); done(null)
            Thread({
                try {
                    while (!server.isClosed) {
                        val peer = server.accept()
                        // Verify actual local interface, rejecting cellular/VPN/public connections.
                        queue.submit {
                            if (listener !== server || socket != null ||
                                addresses().none { it.substringAfter(": ") == peer.localAddress.hostAddress } ||
                                !PairingCode.validAddress(peer.inetAddress.hostAddress ?: "")) peer.close()
                            else attach(peer)
                        }.get()
                    }
                } catch (_: Exception) { post { if (listener === server) { reset(); publish("failed", "Host listener stopped; restart") } } }
            }, "replay-accept").start()
        } catch (error: Exception) { publish("failed", error.message ?: "Cannot start host"); done(error) }
    } }
    fun connect(address: String, secret: String, port: Int) { queue.execute {
        reset(); role = "camera"; this.secret = secret; snapshot.put("port", port)
        val peer = Socket(); socket = peer; publish("connecting", "Connecting over local Wi-Fi")
        handshakeTimeout = queue.schedule({ if (socket === peer) failPeer("Connection/authentication timed out; check network and secret") }, 20, TimeUnit.SECONDS)
        Thread({
            try {
                bindCamera(peer); peer.connect(InetSocketAddress(address, port), 20_000)
                post { if (socket === peer) attach(peer) else peer.close() }
            } catch (error: Exception) { post { if (socket === peer) failPeer(error.message ?: "Connection failed") } }
        }, "replay-connect").start()
    } }
    private fun attach(peer: Socket) {
        socket = peer; peer.tcpNoDelay = true; authenticated = false; handshake = "hello"
        auth = SessionAuthentication(secret, role)
        handshakeTimeout?.cancel(false)
        handshakeTimeout = queue.schedule({ if (socket === peer) failPeer("Authentication timed out; check secret") }, 20, TimeUnit.SECONDS)
        publish("authenticating", "Checking session secret"); send(auth!!.hello())
        Thread({
            try {
                val input = peer.getInputStream(); val line = ByteArrayOutputStream()
                while (!peer.isClosed) {
                    val byte = input.read(); if (byte == -1) error("Peer disconnected")
                    if (byte == 10) {
                        val frame = JSONObject(line.toString("UTF-8")); line.reset()
                        // Wait for processing: bounded reader backlog, ordered frames.
                        queue.submit { if (socket === peer) handle(frame) }.get()
                    } else {
                        line.write(byte); require(line.size() <= 2048) { "Oversized diagnostic message" }
                    }
                }
            } catch (error: Exception) { post { if (socket === peer) failPeer(error.message ?: "Peer disconnected") } }
        }, "replay-read").start()
    }
    private fun send(frame: JSONObject) {
        val peer = socket ?: return
        val bytes = (frame.toString() + "\n").toByteArray(Charsets.UTF_8)
        try { writer.execute {
            try { peer.getOutputStream().write(bytes); peer.getOutputStream().flush() }
            catch (error: Exception) { post { if (socket === peer) failPeer(error.message ?: "Send failed") } }
        } } catch (_: Exception) { failPeer("Too many outgoing messages; reconnect") }
    }
    private fun signed(type: String, id: String = UUID.randomUUID().toString()) { send(auth!!.signed(type, id)) }
    private fun handle(frame: JSONObject) {
        try {
            val authentication = checkNotNull(auth)
            if (handshake == "hello") {
                require(authentication.acceptHello(frame)) { "Invalid handshake or incompatible app version" }
                handshake = "auth"; signed("auth"); return
            }
            require(authentication.verify(frame)) { "Authentication rejected: wrong secret, replay or altered message" }
            val type = frame.getString("type"); val id = frame.getString("id")
            if (handshake == "auth") {
                require(type == "auth") { "Expected authentication proof" }; handshake = "ready"; signed("ready"); return
            }
            if (handshake == "ready") {
                require(type == "ready") { "Expected ready confirmation" }
                handshake = "complete"; authenticated = true; handshakeTimeout?.cancel(false); handshakeTimeout = null
                if (role == "camera") secret = ""
                publish("connected", "Authenticated peer; status messages are unencrypted"); return
            }
            require(authenticated)
            when (type) {
                "ping", "status" -> {
                    snapshot.put("pingsReceived", snapshot.getInt("pingsReceived") + 1)
                    signed(if (type == "ping") "pong" else "statusReply", id)
                    publish("connected", "Received authenticated $type; replied")
                }
                "pong", "statusReply" -> {
                    val request = pending.remove(id) ?: error("Unexpected response")
                    request.second.cancel(false)
                    snapshot.put("lastRoundTripMs", (System.nanoTime() - request.first) / 1_000_000.0)
                        .put("repliesReceived", snapshot.getInt("repliesReceived") + 1)
                    publish("connected", "Received authenticated $type")
                }
                "transfer" -> error("Android video transfer is not implemented yet; this task supports ping/status only")
                else -> error("Unexpected handshake message")
            }
        } catch (error: Exception) { failPeer(error.message ?: "Invalid message") }
    }
    fun ping(status: Boolean, done: (Boolean) -> Unit) { queue.execute {
        if (!authenticated || pending.size >= 4) { done(false); return@execute }
        val id = UUID.randomUUID().toString()
        val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("Peer response timed out; reconnect") }, 8, TimeUnit.SECONDS)
        pending[id] = Pair(System.nanoTime(), timeout); signed(if (status) "status" else "ping", id); done(true)
    } }
    private fun failPeer(detail: String) {
        handshakeTimeout?.cancel(false); handshakeTimeout = null
        runCatching { socket?.close() }; socket = null; auth = null; authenticated = false
        pending.values.forEach { it.second.cancel(false) }; pending.clear(); writer.queue.clear()
        publish(if (listener == null) "failed" else "listening", detail)
    }
    private fun reset() { runCatching { listener?.close() }; listener = null; failPeer("Stopped"); secret = ""; snapshot = emptySnapshot() }
    fun stop(reason: String = "Stopped", done: () -> Unit = {}) { queue.execute { reset(); publish("stopped", reason); done() } }
    fun destroy() { stop { writer.shutdownNow(); queue.shutdown() } }
}
