package com.aadhinitinytales.cricketreplay

import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.BufferedInputStream
import java.io.File
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
internal class LocalSession(private val addresses: () -> List<String>, private val bindCamera: (Socket) -> Unit, private val directory: File) {
    private var viewerHub: LocalSession? = null
    private var servingViewers = false
    private var viewerClient = false
    private val viewers = mutableListOf<LocalSession>()
    private var publishedReview: (((File?, JSONObject?, Exception?) -> Unit) -> Unit)? = null
    private fun copyLatest(target: File, done: (File?, JSONObject?, Exception?) -> Unit) { queue.execute {
        try {
            val current = if (snapshot.optJSONObject("review")?.optString("state") == "ready" && transfer.state.optString("state") == "ready") transfer.completed else null
            val source = current ?: previousReview?.first ?: error("No replay yet")
            val info = if (current != null) transfer.recording else previousReview?.second
            target.mkdirs(); val copy = File(target, "viewer-" + UUID.randomUUID() + ".mp4")
            source.copyTo(copy); done(copy, JSONObject(checkNotNull(info).toString()), null)
        } catch (error: Exception) { done(null, null, error) }
    } }
    fun startViewers(secret: String, port: Int, done: (Exception?) -> Unit) { queue.execute {
        viewerHub?.destroy()
        val hub = LocalSession(addresses, bindCamera, File(directory.parentFile, directory.name + "-viewers")).apply { servingViewers = true }
        hub.publishedReview = { callback -> copyLatest(hub.directory, callback) }
        viewerHub = hub; hub.startHost(secret, port, done)
    } }
    fun fetchPublished(done: (Exception?) -> Unit) { queue.execute {
        if (!viewerClient || !authenticated || mediaInUse || transfer.active || pending.isNotEmpty()) { done(IllegalStateException("Connect and close playback first")); return@execute }
        try {
            if (snapshot.optJSONObject("review")?.optString("state") == "ready" && transfer.completed != null && transfer.recording != null) {
                val saved = File(directory, "previous-review.mp4"); transfer.completed!!.copyTo(saved, overwrite = true)
                previousReview = Pair(saved, JSONObject(transfer.recording!!.toString()))
            }
        } catch (error: Exception) { done(error); return@execute }
        val id = UUID.randomUUID().toString(); val tap = nowUs()
        val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("Viewer replay timed out") }, 45, TimeUnit.SECONDS)
        pending[id] = Pair((tap * 1000).toLong(), timeout)
        snapshot.put("review", JSONObject().put("requestId", id).put("state", "requesting").put("tapUs", tap))
        signed("status", id, JSONObject().put("kind", "published").toString()); done(null)
    } }
    private fun copyLatestForViewer(target: File, done: (File?, JSONObject?, Exception?) -> Unit) {
        publishedReview?.invoke { source, info, error ->
            if (source == null || error != null) done(null, null, error)
            else try { target.mkdirs(); val copy = File(target, source.name); source.copyTo(copy); source.delete(); done(copy, info, null) }
            catch (failure: Exception) { source.delete(); done(null, null, failure) }
        }
    }
    private fun servePublished(id: String) {
        if (preparingReview || transfer.active) { signed("statusReply", id, JSONObject().put("kind", "review").put("ok", false).put("detail", "Transfer busy").toString()); return }
        preparingReview = true; val token = auth
        publishedReview?.invoke { file, info, error -> post(rejected = { file?.delete() }) {
            preparingReview = false
            if (auth !== token || !authenticated) { file?.delete(); return@post }
            if (error != null || file == null || info == null) { signed("statusReply", id, JSONObject().put("kind", "review").put("ok", false).put("detail", error?.message ?: "No replay yet").toString()); return@post }
            try {
                signed("statusReply", id, JSONObject().put("kind", "review").put("ok", true).put("peerTapUs", info.getDouble("requestedHostUs")).toString())
                transfer.begin(file, info = info, reviewId = id); outgoingReview = file
            } catch (failure: Exception) { file.delete(); failPeer(failure.message ?: "Viewer transfer failed") }
        } }
    }
    private val queue = Executors.newSingleThreadScheduledExecutor()
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(64))
    private var listener: ServerSocket? = null
    @Volatile private var socket: Socket? = null
    private var auth: SessionAuthentication? = null
    private var secret = ""
    private var role = "host"
    private var handshake = "hello"
    @Volatile private var authenticated = false
    private var handshakeTimeout: ScheduledFuture<*>? = null
    private val pending = mutableMapOf<String, Pair<Long, ScheduledFuture<*>>>()
    private var clockSamples = 0
    private var bestClock: Triple<Double, Double, Double>? = null
    var onEndMatch: (((Exception?) -> Unit) -> Unit)? = null
    private var endCompletion: ((Boolean) -> Unit)? = null
    var matchStatus: (((JSONObject) -> Unit) -> Unit)? = null
    var onReview: ((Long, (Exception?) -> Unit) -> Unit)? = null
    var onReviewCancelled: (() -> Unit)? = null
    var exportReview: (((File?, JSONObject?, Exception?) -> Unit) -> Unit)? = null
    var validateReceivedReview: ((File, JSONObject) -> Unit)? = null
    private var preparingReview = false
    private var mediaInUse = false
    private var previousReview: Pair<File, JSONObject>? = null
    private var outgoingReview: File? = null
    private var snapshot = emptySnapshot()
    private val transfer = SampleTransfer(queue, directory).apply {
        onSend = { id, packet ->
            try {
                check(authenticated) { "Peer disconnected" }
                val authentication = checkNotNull(auth)
                send(authentication.signed("transfer", id, authentication.encrypt(packet, id)))
            } catch (error: Exception) { failPeer(error.message ?: "Cannot encrypt transfer") }
        }
        acceptOffer = { media, id ->
            check(!mediaInUse) { "Close host playback/inspection before sending" }
            val review = snapshot.optJSONObject("review")
            if (media == "recording") check(review?.optString("requestId") == id && review.optString("state") in listOf("requesting", "transferring")) { "Unexpected or stale recording review" }
            else check(review?.optString("state") !in listOf("requesting", "transferring")) { "A recorded review is pending" }
        }
        validateRecording = { file, info ->
            val review = checkNotNull(snapshot.optJSONObject("review")) { "No pending review" }
            check(kotlin.math.abs(review.getDouble("peerTapUs") - info.getDouble("requestedHostUs")) <= 1) { "Recording endpoint does not match the requested tap" }
            checkNotNull(validateReceivedReview) { "Host recording decoder unavailable" }.invoke(file, info)
        }
        onChange = { state ->
            val review = snapshot.optJSONObject("review")
            if (state.optString("media") == "recording" && state.optString("state") == "ready" && review?.optString("requestId") == state.optString("reviewId")) {
                review.put("state", "ready").put("detail", "Recording verified and decoded on host; ready to play")
                    .put("verifiedElapsedMs", (nowUs() - review.getDouble("tapUs")) / 1000)
                pending.remove(review.getString("requestId"))?.second?.cancel(false)
            }
            if (state.optString("state") == "complete") { outgoingReview?.delete(); outgoingReview = null }
        }
        onFailure = { failPeer(it) }
    }
    private fun post(rejected: () -> Unit = {}, task: () -> Unit) { if (runCatching { queue.execute(task) }.isFailure) rejected() }
    private fun emptySnapshot() = JSONObject().put("state", "stopped").put("detail", "No session").put("role", role)
        .put("authenticated", false).put("addresses", JSONArray()).put("pingsReceived", 0).put("repliesReceived", 0)
    private fun publish(state: String, detail: String) {
        snapshot.put("state", state).put("detail", detail).put("role", role).put("authenticated", authenticated)
    }
    fun status(done: (JSONObject) -> Unit) { queue.execute { snapshot.put("transfer", transfer.state).put("hasPlayableReview", previousReview?.first?.exists() == true || (snapshot.optJSONObject("review")?.optString("state") == "ready" && transfer.completed != null)); done(JSONObject(snapshot.toString())) } }
    fun sendSample(file: File, slow: Boolean, done: (Exception?) -> Unit) { queue.execute {
        try {
            check(role == "camera" && authenticated && !preparingReview) { "Connect camera to host first" }
            transfer.begin(file, slow); done(null)
        } catch (error: Exception) { done(error) }
    } }
    fun completedSample(done: (File?) -> Unit) { queue.execute { done(if (transfer.state.optString("media") == "sample" && transfer.state.optString("state") == "ready") transfer.completed else null) } }
    fun acquireSample(done: (File?) -> Unit) { queue.execute {
        if (mediaInUse || snapshot.optJSONObject("review")?.optString("state") in listOf("requesting", "transferring") || transfer.state.optString("media") != "sample" || transfer.state.optString("state") != "ready" || transfer.completed == null) { done(null); return@execute }
        mediaInUse = true; done(transfer.completed)
    } }
    fun acquireReview(done: (File?, JSONObject?) -> Unit) { queue.execute {
        if (mediaInUse || transfer.active || snapshot.optJSONObject("review")?.optString("state") in listOf("requesting", "transferring")) { done(null, null); return@execute }
        val current = if (snapshot.optJSONObject("review")?.optString("state") == "ready" && transfer.state.optString("state") == "ready" && transfer.state.optString("reviewId") == snapshot.optJSONObject("review")?.optString("requestId")) transfer.completed else null
        val file = current ?: previousReview?.first
        val info = if (current != null) transfer.recording else previousReview?.second
        if (file == null || !file.exists() || info == null) { done(null, null); return@execute }
        mediaInUse = true; done(file, info)
    } }
    fun releaseMedia() { queue.execute { mediaInUse = false } }
    fun reviewPlaybackStarted() { queue.execute {
        snapshot.optJSONObject("review")?.let { if (it.optString("state") == "ready" && !it.has("tapToPlayMs")) it.put("tapToPlayMs", (nowUs() - it.getDouble("tapUs")) / 1000) }
    } }
    fun cleanupTransfer(done: (Exception?) -> Unit) { queue.execute {
        try { check(!mediaInUse && !preparingReview && snapshot.optJSONObject("review")?.optString("state") !in listOf("requesting", "transferring")) { "Close playback/inspection and stop or finish the pending review first" }; transfer.cleanup(); previousReview = null; snapshot.remove("review"); done(null) } catch (error: Exception) { done(error) }
    } }
    fun startHost(secret: String, port: Int, done: (Exception?) -> Unit) { queue.execute {
        reset(); role = if (servingViewers) "camera" else "host"; this.secret = secret
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
                            if (listener !== server || (!servingViewers && socket != null) ||
                                addresses().none { it.substringAfter(": ") == peer.localAddress.hostAddress } ||
                                !PairingCode.validAddress(peer.inetAddress.hostAddress ?: "")) peer.close()
                            else if (servingViewers) {
                                // Each viewer has independent authentication, transfer and storage.
                                val iterator = viewers.iterator()
                                while (iterator.hasNext()) { val old = iterator.next(); if (old.socket == null) { old.destroy(); iterator.remove() } }
                                if (viewers.size >= 4) peer.close()
                                else {
                                    val child = LocalSession(addresses, bindCamera, File(directory, UUID.randomUUID().toString()))
                                    child.servingViewers = true; child.role = "camera"; child.secret = this.secret
                                    child.publishedReview = { callback -> copyLatestForViewer(child.directory, callback) }
                                    child.socket = peer; viewers.add(child); child.post { child.attach(peer) }
                                }
                            } else attach(peer)
                        }.get()
                    }
                } catch (_: Exception) { post { if (listener === server) { reset(); publish("failed", "Host listener stopped; restart") } } }
            }, "replay-accept").start()
        } catch (error: Exception) { publish("failed", error.message ?: "Cannot start host"); done(error) }
    } }
    fun connect(address: String, secret: String, port: Int, viewer: Boolean = false) { queue.execute {
        val cachedReview = if (viewer && viewerClient && this.secret == secret) snapshot.optJSONObject("review")?.takeIf { it.optString("state") == "ready" } else null
        reset(); cachedReview?.let { snapshot.put("review", it) }; viewerClient = viewer; role = if (viewer) "host" else "camera"; this.secret = secret; snapshot.put("port", port)
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
                val input = peer.getInputStream(); val buffer = ByteArray(65536); val line = ByteArrayOutputStream()
                while (!peer.isClosed) {
                    val count = input.read(buffer); if (count == -1) error("Peer disconnected")
                    var start = 0
                    for (index in 0 until count) {
                        if (buffer[index] == 10.toByte()) {
                            line.write(buffer, start, index - start)
                            require(line.size() <= if (authenticated) 65536 else 2048) { "Oversized message" }
                            val size = line.size(); val frame = JSONObject(line.toString("UTF-8")); line.reset(); start = index + 1
                            // Process one complete frame at a time; bounded and ordered.
                            queue.submit { if (socket === peer) {
                                if (size > 2048 && !(authenticated && frame.optString("type") == "transfer")) failPeer("Oversized diagnostic message")
                                else handle(frame)
                            } }.get()
                        }
                    }
                    line.write(buffer, start, count - start)
                    require(line.size() <= if (authenticated) 65536 else 2048) { "Oversized message" }
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
    private fun signed(type: String, id: String = UUID.randomUUID().toString(), payload: String = "") { send(auth!!.signed(type, id, payload)) }
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
            if (servingViewers && type != "transfer") {
                val body = runCatching { JSONObject(frame.optString("payload")) }.getOrNull()
                check(type == "status" && body?.optString("kind") == "published") { "Viewers may only fetch completed replays" }
                servePublished(id); return
            }
            when (type) {
                "ping", "status" -> {
                    snapshot.put("pingsReceived", snapshot.getInt("pingsReceived") + 1)
                    val t2 = nowUs()
                    val body = runCatching { JSONObject(frame.optString("payload")) }.getOrNull()
                    when {
                        type == "status" && body?.optString("kind") == "review" -> {
                            check(role == "camera" && onReview != null) { "Review receiver unavailable" }
                            if (preparingReview || transfer.active) {
                                signed("statusReply", id, JSONObject().put("kind", "review").put("ok", false).put("detail", "A review/transfer is already active").toString()); return
                            }
                            preparingReview = true
                            val endpoint = body.getLong("peerTapUs"); val token = auth
                            onReview!!.invoke(endpoint) { error -> post {
                                if (auth !== token) return@post
                                fun reply(failure: Exception?) {
                                    preparingReview = false
                                    signed("statusReply", id, JSONObject().put("kind", "review").put("ok", failure == null)
                                        .put("detail", failure?.message ?: "Extracted; encrypted recording transfer in progress").put("peerTapUs", endpoint).toString())
                                }
                                if (error != null) reply(error)
                                else if (exportReview == null) reply(IllegalStateException("Recording export unavailable"))
                                else exportReview!!.invoke { file, info, failure -> post {
                                    if (auth !== token) { file?.delete() }
                                    else if (failure != null) reply(failure)
                                    else try { transfer.begin(checkNotNull(file), info = checkNotNull(info), reviewId = id); outgoingReview = file; reply(null) }
                                    catch (e: Exception) { file?.delete(); reply(e) }
                                } }
                            } }
                        }
                        type == "status" && body?.optString("kind") == "endMatch" -> {
                            val token = auth
                            val handler = onEndMatch
                            if (handler == null) signed("statusReply", id, JSONObject().put("kind", "endMatch").put("ok", false).toString())
                            else handler { error -> post {
                                if (auth === token) {
                                    signed("statusReply", id, JSONObject().put("kind", "endMatch").put("ok", error == null).toString())
                                    if (error == null) queue.schedule({ if (auth === token) stop() }, 1, TimeUnit.SECONDS)
                                }
                            } }
                        }
                        type == "status" && body?.optString("kind") == "match" -> {
                            val token = auth
                            matchStatus?.invoke { state -> post { if (auth === token) signed("statusReply", id, state.put("kind", "match").toString()) } }
                        }
                        type == "status" && body?.optString("kind") == "clock" -> signed("statusReply", id, JSONObject().put("kind", "clock").put("t2", t2).put("t3", nowUs()).toString())
                        else -> signed(if (type == "ping") "pong" else "statusReply", id)
                    }
                    publish("connected", "Received authenticated $type; replied")
                }
                "pong", "statusReply" -> {
                    val request = pending[id] ?: error("Unexpected response")
                    val t4 = nowUs(); val body = runCatching { JSONObject(frame.optString("payload")) }.getOrNull()
                    if (body?.optString("kind") == "endMatch") {
                        val done = endCompletion; endCompletion = null; done?.invoke(body.optBoolean("ok"))
                    } else if (body?.optString("kind") == "match") {
                        snapshot.put("peerRecording", body)
                    } else if (body?.optString("kind") == "clock") {
                        val t1 = request.first / 1000.0; val t2 = body.getDouble("t2"); val t3 = body.getDouble("t3")
                        val network = t4 - t1 - (t3 - t2); require(network >= 0 && t3 >= t2) { "Invalid clock exchange" }
                        val offset = ((t2 - t1) + (t3 - t4)) / 2; clockSamples++
                        if (bestClock == null || network / 2 < bestClock!!.second) bestClock = Triple(offset, network / 2, t4)
                        bestClock?.let { snapshot.put("clock", JSONObject().put("samples", clockSamples).put("offsetUs", it.first).put("uncertaintyUs", it.second).put("measuredAtUs", it.third)) }
                    } else if (body?.optString("kind") == "review") {
                        val review = snapshot.optJSONObject("review") ?: JSONObject()
                        body.keys().forEach { key -> review.put(key, body.get(key)) }
                        if (review.optString("state") != "ready") review.put("state", if (body.optBoolean("ok")) "transferring" else "failed")
                        review.put("replyElapsedMs", (t4 - request.first / 1000.0) / 1000)
                        snapshot.put("review", review)
                    }
                    if (snapshot.optJSONObject("review")?.optString("requestId") != id || snapshot.optJSONObject("review")?.optString("state") == "failed") pending.remove(id)?.second?.cancel(false)
                    snapshot.put("lastRoundTripMs", (nowUs() - request.first / 1000.0) / 1000.0)
                        .put("repliesReceived", snapshot.getInt("repliesReceived") + 1)
                    publish("connected", "Received authenticated $type")
                }
                "transfer" -> transfer.receive(id, authentication.decrypt(frame.getString("payload"), id), role == "host")
                else -> error("Unexpected handshake message")
            }
        } catch (error: Exception) { failPeer(error.message ?: "Invalid message") }
    }
    fun ping(status: Boolean, done: (Boolean) -> Unit) { queue.execute {
        if (!authenticated || pending.size >= 4) { done(false); return@execute }
        val id = UUID.randomUUID().toString()
        val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("Peer response timed out; reconnect") }, 8, TimeUnit.SECONDS)
        pending[id] = Pair(SystemClock.elapsedRealtimeNanos(), timeout); signed(if (status) "status" else "ping", id, if (status) JSONObject().put("kind", "clock").toString() else ""); done(true)
    } }
    fun endPeerMatch(done: (Boolean) -> Unit) { queue.execute {
        if (!authenticated || endCompletion != null) { done(false); return@execute }
        endCompletion = done
        val id = UUID.randomUUID().toString()
        val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("End match acknowledgement timed out") }, 8, TimeUnit.SECONDS)
        pending[id] = Pair(SystemClock.elapsedRealtimeNanos(), timeout)
        signed("status", id, JSONObject().put("kind", "endMatch").toString())
    } }
    fun requestMatchStatus(done: (Boolean) -> Unit) { queue.execute {
        if (!authenticated || pending.isNotEmpty()) { done(false); return@execute }
        val id = UUID.randomUUID().toString()
        val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("Camera status timed out; reconnect") }, 8, TimeUnit.SECONDS)
        pending[id] = Pair(SystemClock.elapsedRealtimeNanos(), timeout)
        signed("status", id, JSONObject().put("kind", "match").toString()); done(true)
    } }
    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000.0
    fun measureClock() { queue.execute {
        clockSamples = 0; bestClock = null; snapshot.remove("clock"); val token = auth
        for (index in 0..7) queue.schedule({ if (authenticated && auth === token) ping(true) {} }, index * 80L, TimeUnit.MILLISECONDS)
    } }
    fun requestMatchReview(done: (Exception?) -> Unit) {
        val tap = nowUs()
        queue.execute {
            val token = auth
            if (role != "host" || !authenticated || mediaInUse || transfer.active || snapshot.optJSONObject("review")?.optString("state") in listOf("requesting", "transferring")) { done(IllegalStateException("Connect the camera and close playback before reviewing")); return@execute }
            val clock = bestClock
            if (clockSamples >= 4 && clock != null && tap - clock.third < 30_000_000 && pending.isEmpty()) {
                requestReview(0, tap, done); return@execute
            }
            measureClock()
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(3500)
            fun awaitClock() {
                if (auth !== token || !authenticated) { done(IllegalStateException("Connection changed while preparing replay; reconnect and retry")); return }
                if ((clockSamples >= 8 && pending.isEmpty()) || System.nanoTime() >= deadline) { requestReview(0, tap, done); return }
                queue.schedule({ awaitClock() }, 50, TimeUnit.MILLISECONDS)
            }
            queue.schedule({ awaitClock() }, 50, TimeUnit.MILLISECONDS)
        }
    }
    fun requestReview(delayMs: Int, tapUs: Double? = null, done: (Exception?) -> Unit) {
        val tap = tapUs ?: nowUs()
        queue.execute {
            val best = bestClock
            if (role != "host" || !authenticated || clockSamples < 4 || best == null || nowUs() - best.third >= 30_000_000 || delayMs !in 0..5000 || pending.isNotEmpty() || transfer.active || mediaInUse) {
                done(IllegalStateException("Measure clocks first; wait for replies, then review within 30 seconds")); return@execute
            }
            try {
                if (snapshot.optJSONObject("review")?.optString("state") == "ready" && transfer.state.optString("state") == "ready" && transfer.recording != null) {
                    val saved = File(directory, "previous-review.mp4")
                    checkNotNull(transfer.completed).copyTo(saved, overwrite = true)
                    previousReview = Pair(saved, JSONObject(checkNotNull(transfer.recording).toString()))
                }
            } catch (error: Exception) { done(error); return@execute }
            val id = UUID.randomUUID().toString(); val token = auth
            val timeout = queue.schedule({ if (pending.containsKey(id)) failPeer("Timed review expired; reconnect") }, 45, TimeUnit.SECONDS)
            pending[id] = Pair((tap * 1000).toLong(), timeout)
            snapshot.put("review", JSONObject().put("kind", "review").put("requestId", id).put("state", "requesting").put("tapUs", tap).put("peerTapUs", tap + best.first).put("uncertaintyUs", best.second).put("injectedDelayMs", delayMs))
            queue.schedule({ if (authenticated && auth === token) signed("status", id, JSONObject().put("kind", "review").put("peerTapUs", (tap + best.first).toLong()).toString()) }, delayMs.toLong(), TimeUnit.MILLISECONDS)
            done(null)
        }
    }
    private fun failPeer(detail: String) {
        val end = endCompletion; endCompletion = null; end?.invoke(false)
        clockSamples = 0; bestClock = null; snapshot.remove("clock"); snapshot.remove("peerRecording")
        if (preparingReview) onReviewCancelled?.invoke(); preparingReview = false
        snapshot.optJSONObject("review")?.let { if (it.optString("state") in listOf("requesting", "transferring")) it.put("state", "failed").put("detail", detail) }
        transfer.cancel(detail); outgoingReview?.delete(); outgoingReview = null
        handshakeTimeout?.cancel(false); handshakeTimeout = null
        runCatching { socket?.close() }; socket = null; auth = null; authenticated = false
        pending.values.forEach { it.second.cancel(false) }; pending.clear(); writer.queue.clear()
        publish(if (listener == null) "failed" else "listening", detail)
    }
    private fun reset() { viewerHub?.destroy(); viewerHub = null; viewers.forEach { it.destroy() }; viewers.clear(); runCatching { listener?.close() }; listener = null; failPeer("Stopped"); secret = ""; snapshot = emptySnapshot() }
    fun stop(reason: String = "Stopped", done: () -> Unit = {}) { queue.execute { reset(); publish("stopped", reason); done() } }
    fun destroy() { stop { if (servingViewers) directory.deleteRecursively(); writer.shutdownNow(); queue.shutdown() } }
}
