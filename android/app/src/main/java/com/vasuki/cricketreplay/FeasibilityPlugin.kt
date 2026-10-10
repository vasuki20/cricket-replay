package com.aadhinitinytales.cricketreplay

import android.Manifest
import android.os.Build
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.graphics.Bitmap
import android.util.Base64
import androidx.activity.result.ActivityResult
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import com.getcapacitor.annotation.ActivityCallback
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanOptions
import com.journeyapps.barcodescanner.ScanIntentResult
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.Socket
import org.json.JSONObject

@CapacitorPlugin(name = "Feasibility", permissions = [
    Permission(alias = "camera", strings = [Manifest.permission.CAMERA])
])
class FeasibilityPlugin : Plugin() {
    private val recordingPreview by lazy { RecordingPreview(activity, bridge.webView) }
    @PluginMethod fun setFullscreen(call: PluginCall) { activity.runOnUiThread {
        if (player != null) { call.resolve(); return@runOnUiThread }
        activity.requestedOrientation = if (call.getBoolean("enabled", false) == true) android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR else android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        call.resolve()
    } }
    @PluginMethod fun setRecordingPreview(call: PluginCall) { activity.runOnUiThread { recordingPreview.layout(call) } }
    private var inspectingFrame = false
    private var preparingRemoteReview = false
    private val frameWorker = java.util.concurrent.Executors.newSingleThreadExecutor()
    @PluginMethod fun inspectRecordingFrame(call: PluginCall) { activity.runOnUiThread {
        val index = call.getInt("index")
        if (inspectingFrame || preparingRemoteReview || player != null || index == null || index !in 0..9999) { call.reject("Close playback and choose an available frame"); return@runOnUiThread }
        inspectingFrame = true
        recording.completedClip { file -> frameWorker.execute {
            try {
                val result = RecordingFrame.inspect(file ?: error("Extract a recording clip first"), index)
                activity.runOnUiThread { inspectingFrame = false; call.resolve(JSObject(result.toString())) }
            } catch (error: Exception) { activity.runOnUiThread { inspectingFrame = false; call.reject(error.message ?: "Frame decode failed") } }
        } }
    } }
    @PluginMethod fun inspectReceivedReviewFrame(call: PluginCall) { activity.runOnUiThread {
        val index = call.getInt("index")
        if (inspectingFrame || preparingRemoteReview || player != null || index == null || index !in 0..9999) { call.reject("Close playback and choose an available frame"); return@runOnUiThread }
        inspectingFrame = true
        session.acquireReview { file, info -> frameWorker.execute {
            try {
                val result = RecordingFrame.inspect(file ?: error("No verified host recording review"), index)
                result.put("sourceTimestampUs", checkNotNull(info).getLong("sourceFirstUs") + result.getLong("timestampUs"))
                activity.runOnUiThread { inspectingFrame = false; call.resolve(JSObject(result.toString())) }
            } catch (error: Exception) { activity.runOnUiThread { inspectingFrame = false; call.reject(error.message ?: "Frame decode failed") } }
            finally { if (file != null) session.releaseMedia() }
        } }
    } }
    @PluginMethod fun saveReceivedReview(call: PluginCall) {
        session.acquireReview { file, _ ->
            if (file == null) { call.reject("Close playback and wait for a verified replay"); return@acquireReview }
            frameWorker.execute {
                try {
                    val folder = java.io.File(context.filesDir, "saved-replays"); check(folder.isDirectory || folder.mkdirs())
                    val saved = java.io.File(folder, "replay-${java.util.UUID.randomUUID()}.mp4")
                    try { file.copyTo(saved) } catch (error: Exception) { saved.delete(); throw error }
                    activity.runOnUiThread {
                        try {
                            val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", saved)
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).setType("video/mp4")
                                .putExtra(android.content.Intent.EXTRA_STREAM, uri).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            activity.startActivity(android.content.Intent.createChooser(intent, "Save or share replay"))
                            call.resolve()
                        } catch (error: Exception) { call.reject("Replay saved in this app; sharing unavailable: ${error.message}") }
                    }
                } catch (error: Exception) { call.reject(error.message ?: "Could not save replay") }
                finally { session.releaseMedia() }
            }
        }
    }
    @PluginMethod fun playReceivedReview(call: PluginCall) { activity.runOnUiThread {
        val rate = (call.getDouble("rate", 1.0) ?: 1.0).toFloat()
        if (rate !in listOf(1f, 0.5f, 0.25f) || player != null || inspectingFrame || activity.isFinishing || activity.isDestroyed) { call.reject("Close playback/inspection and foreground the app first"); return@runOnUiThread }
        session.acquireReview { file, _ -> activity.runOnUiThread {
            if (file == null) { call.reject("No complete, verified host recording review"); return@runOnUiThread }
            if (player != null || activity.isFinishing || activity.isDestroyed) { session.releaseMedia(); call.reject("Close playback first"); return@runOnUiThread }
            try {
                player = SamplePlayer(activity, file, { error ->
                    if (error == null) { session.reviewPlaybackStarted(); call.resolve() } else call.reject(error)
                }, { player = null; session.releaseMedia() }, rate, { notifyListeners("reviewFrames", JSObject()) })
            } catch (error: Exception) { player = null; session.releaseMedia(); call.reject(error.message ?: "Cannot open host review playback") }
        } }
    } }
    private var hosting = false
    private fun updateScreenAwake() {
        if (hosting || cameraRecording) activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    private var cameraRecording = false // UI thread owns scanner/generator/camera resource exclusion.
    private val recording by lazy { RollingRecording(context) {
        activity.runOnUiThread { cameraRecording = false; recordingPreview.hide(); updateScreenAwake() }
    } }
    override fun load() {
        session.onEndMatch = { done -> activity.runOnUiThread {
            if (player != null || inspectingFrame || preparingRemoteReview) done(IllegalStateException("Close playback and finish replay first"))
            else { hosting = false; updateScreenAwake(); recording.stop { recording.cleanup { error ->
                if (error != null) done(error) else session.cleanupTransfer(done)
            } } }
        } }
        session.matchStatus = { done -> recording.status { state -> done(JSONObject().put("state", state.getString("state")).put("elapsedSeconds", state.getDouble("elapsedSeconds")).put("bufferedSeconds", state.getDouble("bufferedSeconds")).put("retentionSeconds", state.getInt("retentionSeconds")).put("reviewSeconds", state.getInt("reviewSeconds"))) } }
        session.onReviewCancelled = { activity.runOnUiThread { preparingRemoteReview = false } }
        session.exportReview = { done -> recording.exportReview { file, info, error ->
            activity.runOnUiThread { preparingRemoteReview = false }; done(file, info, error)
        } }
        session.validateReceivedReview = RecordingFrame::validateReview
        session.onReview = { endpoint, done -> activity.runOnUiThread {
            if (player != null || inspectingFrame) done(IllegalStateException("Close frame inspection/playback before a remote review"))
            else {
                preparingRemoteReview = true
                recording.extract(endpoint) { error ->
                    if (error != null) activity.runOnUiThread { preparingRemoteReview = false }
                    done(error)
                }
            }
        } }
    }
    private var matchReviewPreparing = false
    @PluginMethod fun requestMatchReview(call: PluginCall) { activity.runOnUiThread {
        if (matchReviewPreparing) { call.reject("A replay is already being prepared"); return@runOnUiThread }
        matchReviewPreparing = true
        session.requestMatchReview { error ->
            activity.runOnUiThread { matchReviewPreparing = false }
            if (error == null) call.resolve() else call.reject(error.message ?: "Replay unavailable; reconnect and retry")
        }
    } }
    @PluginMethod fun endPeerMatch(call: PluginCall) { session.endPeerMatch { ok -> call.resolve(JSObject().put("acknowledged", ok)) } }
    @PluginMethod fun requestMatchStatus(call: PluginCall) { session.requestMatchStatus { call.resolve() } }
    @PluginMethod fun measureReviewClock(call: PluginCall) { session.measureClock(); call.resolve() }
    @PluginMethod fun requestTimedReview(call: PluginCall) {
        session.requestReview(call.getInt("delayMs", 0) ?: 0) { error -> if (error == null) call.resolve() else call.reject(error.message ?: "Review unavailable") }
    }
    @PluginMethod fun recordingStatus(call: PluginCall) { recording.status { call.resolve(JSObject(it.toString())) } }
    @PluginMethod fun recordingReport(call: PluginCall) { recording.report { call.resolve(JSObject().put("report", it)) } }
    @PluginMethod fun startRecording(call: PluginCall) { activity.runOnUiThread {
        if (cameraRecording || scanning || player != null || generating || inspectingFrame || preparingRemoteReview) { call.reject("Stop capture, close scanning/playback and finish sample generation first"); return@runOnUiThread }
        if (getPermissionState("camera") != PermissionState.GRANTED) {
            call.reject("Camera access denied or not requested. Request camera permission, or enable Camera in app settings."); return@runOnUiThread
        }
        try {
            // Reject fractional/absent/incorrectly typed configuration rather than silently truncating it.
            val retention = call.data.get("retentionSeconds") as? Int ?: error("Retention must be an integer")
            val review = call.data.get("reviewSeconds") as? Int ?: error("Review must be an integer")
            val config = RecordingConfig(retention, review)
            @Suppress("DEPRECATION") val rotation = when (activity.windowManager.defaultDisplay.rotation) {
                android.view.Surface.ROTATION_90 -> 90; android.view.Surface.ROTATION_180 -> 180
                android.view.Surface.ROTATION_270 -> 270; else -> 0
            }
            val previewSurface = recordingPreview.output() ?: error("Live camera preview is not ready; try again")
            cameraRecording = true; activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            recording.start(config, rotation, previewSurface, recordingPreview::configure) { error ->
                if (error == null) call.resolve() else { activity.runOnUiThread { cameraRecording = false; updateScreenAwake() }; call.reject(error.message ?: "Cannot start recording") }
            }
        } catch (error: Exception) { call.reject(error.message ?: "Invalid recording configuration") }
    } }
    @PluginMethod fun stopRecording(call: PluginCall) { recording.stop { activity.runOnUiThread {
        updateScreenAwake(); call.resolve()
    } } }
    @PluginMethod fun extractRecording(call: PluginCall) { activity.runOnUiThread {
        if (player != null || inspectingFrame || preparingRemoteReview) { call.reject("Close frame inspection/playback before replacing the clip"); return@runOnUiThread }
        recording.extract { error -> if (error == null) call.resolve() else call.reject(error.message ?: "Cannot extract recent clip") }
    } }
    @PluginMethod fun playRecordingClip(call: PluginCall) {
        recording.completedClip { file -> activity.runOnUiThread {
            if (file == null) { call.reject("No completed recording clip"); return@runOnUiThread }
            if (player != null || activity.isFinishing || activity.isDestroyed) { call.reject("Close playback first"); return@runOnUiThread }
            val rate = (call.getDouble("rate", 1.0) ?: 1.0).toFloat()
            if (rate !in listOf(1f, 0.5f, 0.25f) || inspectingFrame) { call.reject("Choose 1×, 0.5× or 0.25× and finish inspection first"); return@runOnUiThread }
            try { player = SamplePlayer(activity, file, { error -> if (error == null) call.resolve() else call.reject(error) }, { player = null }, rate) }
            catch (_: Exception) { player = null; call.reject("Cannot open recording playback") }
        } }
    }
    @PluginMethod fun cleanupRecording(call: PluginCall) { activity.runOnUiThread {
        if (player != null || inspectingFrame || preparingRemoteReview) { call.reject("Close frame inspection/playback before cleanup"); return@runOnUiThread }
        recording.cleanup { error -> if (error == null) call.resolve() else call.reject(error.message ?: "Cannot clean recording") }
    } }
    private val session by lazy { LocalSession(::localAddresses, ::bindWiFi, java.io.File(context.cacheDir, "cricket-transfer")) }
    private var scanning = false
    private fun localAddresses(): List<String> = NetworkInterface.getNetworkInterfaces().toList()
        .filter { it.isUp && !it.isLoopback && (it.name.startsWith("wlan") || it.name.startsWith("ap") || it.name.startsWith("swlan") || it.name.startsWith("wifi")) }
        .flatMap { network -> network.inetAddresses.toList().filterIsInstance<Inet4Address>()
            .mapNotNull { address -> address.hostAddress?.takeIf(PairingCode::validAddress)?.let { "${network.name}: $it" } } }
        .sorted()
    private fun bindWiFi(socket: Socket) {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.allNetworks.firstOrNull { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } ?: error("Join a local Wi-Fi network first; cellular routing is not used")
        network.bindSocket(socket)
    }
    private fun options(call: PluginCall): Pair<String, Int>? {
        val secret = call.getString("secret") ?: ""; val port = call.getInt("port") ?: 0
        if (!PairingCode.validSecret(secret) || port !in 1024..65535) {
            call.reject("Use a generated 32-character lowercase hex secret and port 1024–65535"); return null
        }
        return Pair(secret, port)
    }
    @PluginMethod fun generateSessionSecret(call: PluginCall) { call.resolve(JSObject().put("secret", PairingCode.newSecret())) }
    @PluginMethod fun startHost(call: PluginCall) {
        val (secret, port) = options(call) ?: return
        val viewerSecret = call.getString("viewerSecret")
        session.startHost(secret, port) { error ->
            fun finish(failure: Exception?) { activity.runOnUiThread { hosting = failure == null; updateScreenAwake(); if (failure == null) call.resolve() else { session.stop(); call.reject(failure.message ?: "Host failed") } } }
            if (error != null || viewerSecret == null) finish(error)
            else if (!PairingCode.validSecret(viewerSecret) || viewerSecret == secret || port >= 65535) finish(IllegalArgumentException("Invalid viewer pairing"))
            else session.startViewers(viewerSecret, port + 1, ::finish)
        }
    }
    @PluginMethod fun connectViewer(call: PluginCall) {
        val (secret, port) = options(call) ?: return
        val address = call.getString("address") ?: ""
        if (!PairingCode.validAddress(address)) { call.reject("Use a local Wi-Fi address"); return }
        session.connect(address, secret, port, viewer = true); call.resolve()
    }
    @PluginMethod fun fetchViewerReplay(call: PluginCall) { session.fetchPublished { error -> if (error == null) call.resolve() else call.reject(error.message ?: "Replay unavailable") } }
    @PluginMethod fun connectCamera(call: PluginCall) {
        val (secret, port) = options(call) ?: return
        val address = call.getString("address") ?: ""
        if (!PairingCode.validAddress(address)) { call.reject("Enter a private/local IPv4 address without a port"); return }
        session.connect(address, secret, port); call.resolve()
    }
    @PluginMethod fun sessionStatus(call: PluginCall) { session.status { call.resolve(JSObject(it.toString())) } }
    @PluginMethod fun sendSessionPing(call: PluginCall) {
        session.ping(call.getBoolean("status") ?: false) { sent ->
            if (sent) call.resolve() else call.reject("Connect and authenticate first; at most four requests may be outstanding")
        }
    }
    @PluginMethod fun stopSession(call: PluginCall) { activity.runOnUiThread { hosting = false; updateScreenAwake(); session.stop { call.resolve() } } }
    @PluginMethod fun createPairingQR(call: PluginCall) {
        val (secret, port) = options(call) ?: return
        val address = call.getString("address") ?: ""
        if (!PairingCode.validAddress(address)) { call.reject("Invalid local pairing address"); return }
        try {
            val bitmap = BarcodeEncoder().encodeBitmap(PairingCode(address, port, secret).json().toString(), BarcodeFormat.QR_CODE, 512, 512)
            val stream = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream); bitmap.recycle()
            call.resolve(JSObject().put("image", "data:image/png;base64," + Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)))
        } catch (_: Exception) { call.reject("Cannot create pairing QR") }
    }
    @PluginMethod fun scanPairingQR(call: PluginCall) {
        activity.runOnUiThread {
            if (cameraRecording) { call.reject("Stop recording before opening the QR camera"); return@runOnUiThread }
            if (scanning) { call.reject("Scanner already open"); return@runOnUiThread }
            scanning = true
            if (getPermissionState("camera") == PermissionState.GRANTED) openScanner(call)
            else requestPermissionForAlias("camera", call, "scanPermissionResult")
        }
    }
    @PermissionCallback private fun scanPermissionResult(call: PluginCall) {
        if (getPermissionState("camera") == PermissionState.GRANTED) openScanner(call)
        else { scanning = false; call.reject("Camera access denied. Enable Camera in app settings to scan.") }
    }
    private fun openScanner(call: PluginCall) {
        try {
            val intent = ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Scan the host's Replay pairing QR").setBeepEnabled(false).setBarcodeImageEnabled(false)
                .setOrientationLocked(false).setTimeout(60_000).createScanIntent(activity)
            startActivityForResult(call, intent, "scanResult")
        } catch (_: Exception) { scanning = false; call.reject("Cannot open camera scanner") }
    }
    @ActivityCallback private fun scanResult(call: PluginCall?, result: ActivityResult) {
        scanning = false
        if (call == null) return
        val text = ScanIntentResult.parseActivityResult(result.resultCode, result.data).contents
        if (text == null) { call.reject("Scan cancelled or interrupted; retry"); return }
        val code = PairingCode.decode(text)
        if (code == null) call.reject("Not a valid Replay host QR; scan the host's code")
        else call.resolve(JSObject(code.result().toString()))
    }
    private var sampleFile: java.io.File? = null
    private var sampleInfo = JSObject().put("ready", false)
    private var generating = false
    private var player: SamplePlayer? = null
    private var destroyed = false
    private val generator = java.util.concurrent.Executors.newSingleThreadExecutor()
    @PluginMethod fun sampleStatus(call: PluginCall) { activity.runOnUiThread { call.resolve(sampleInfo) } }
    @PluginMethod fun generateSample(call: PluginCall) { activity.runOnUiThread {
        if (cameraRecording) { call.reject("Stop recording before synthetic generation"); return@runOnUiThread }
        if (generating) { call.reject("Already generating"); return@runOnUiThread }
        if (sampleFile != null) { call.resolve(sampleInfo); return@runOnUiThread }
        generating = true
        generator.execute {
            var file: java.io.File? = null
            try {
                val generated = SampleVideo.generate(context.cacheDir); file = generated
                val info = JSObject().put("ready", true).put("bytes", generated.length())
                    .put("sha256", SampleTransfer.checksum(generated)).put("durationSeconds", 20)
                activity.runOnUiThread {
                    generating = false
                    if (destroyed) { generated.delete(); call.reject("App closed during generation") }
                    else { sampleFile = generated; sampleInfo = info; call.resolve(info) }
                }
            } catch (error: Exception) {
                file?.delete(); activity.runOnUiThread { generating = false; call.reject(error.message ?: "Cannot generate sample") }
            }
        }
    } }
    @PluginMethod fun sendSample(call: PluginCall) { activity.runOnUiThread {
        val file = sampleFile
        if (file == null) { call.reject("Generate the sample first"); return@runOnUiThread }
        session.sendSample(file, call.getBoolean("slow") ?: false) { error ->
            if (error == null) call.resolve() else call.reject(error.message ?: "Cannot send sample")
        }
    } }
    @PluginMethod fun playReceivedSample(call: PluginCall) {
        session.acquireSample { file -> activity.runOnUiThread {
            if (file == null) { call.reject("No complete, checksum-verified sample"); return@runOnUiThread }
            if (player != null || inspectingFrame || activity.isFinishing || activity.isDestroyed) { session.releaseMedia(); call.reject("Close playback/inspection and return to the app first"); return@runOnUiThread }
            try {
                player = SamplePlayer(activity, file, { error -> if (error == null) call.resolve() else call.reject(error) }, { player = null; session.releaseMedia() })
            } catch (_: Exception) { player = null; session.releaseMedia(); call.reject("Cannot open native playback") }
        } }
    }
    @PluginMethod fun cleanupSamples(call: PluginCall) { activity.runOnUiThread {
        if (generating || player != null) { call.reject("Finish generation/playback before cleanup"); return@runOnUiThread }
        session.cleanupTransfer { error -> activity.runOnUiThread {
            if (error != null) { call.reject(error.message ?: "Cannot clean samples"); return@runOnUiThread }
            val file = sampleFile
            if (file != null && file.exists() && !file.delete()) { call.reject("Cannot remove generated sample"); return@runOnUiThread }
            sampleFile = null; sampleInfo = JSObject().put("ready", false); call.resolve()
        } }
    } }
    override fun handleOnStop() {
        cameraRecording = false
        recording.stop("App backgrounded; recording stopped. Foreground and start a new experiment.")
        updateScreenAwake()
        player?.background()
        // Keep the listener, verified review and fullscreen screen across Home.
    }
    override fun handleOnResume() { player?.foreground() }
    override fun handleOnDestroy() { destroyed = true; recording.destroy(); recordingPreview.destroy(); player?.dismiss(); session.destroy(); generator.shutdownNow(); frameWorker.shutdown() }
    private fun diagnostics(): JSObject = JSObject().apply {
        put("platform", "android")
        put("appVersion", context.packageManager.getPackageInfo(context.packageName, 0).versionName)
        put("osVersion", Build.VERSION.RELEASE)
        put("cameraPermission", when (getPermissionState("camera")) {
            PermissionState.GRANTED -> "granted"
            PermissionState.DENIED -> "denied"
            PermissionState.PROMPT_WITH_RATIONALE -> "prompt with rationale"
            else -> "not requested"
        })
    }

    @PluginMethod
    fun ping(call: PluginCall) { call.resolve(diagnostics()) }

    @PluginMethod
    fun requestCameraPermission(call: PluginCall) {
        requestPermissionForAlias("camera", call, "cameraPermissionResult")
    }

    @PermissionCallback
    private fun cameraPermissionResult(call: PluginCall) { call.resolve(diagnostics()) }
}
