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
    private val session by lazy { LocalSession(::localAddresses, ::bindWiFi) }
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
        session.startHost(secret, port) { error -> if (error == null) call.resolve() else call.reject(error.message ?: "Host failed") }
    }
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
    @PluginMethod fun stopSession(call: PluginCall) { session.stop { call.resolve() } }
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
    // Connection milestone only. Keep transfer controls disabled until the next Android task.
    @PluginMethod fun sampleStatus(call: PluginCall) { call.resolve(JSObject().put("ready", false)) }
    @PluginMethod fun generateSample(call: PluginCall) { call.unimplemented("Android sample transfer is pending") }
    @PluginMethod fun sendSample(call: PluginCall) { call.unimplemented("Android sample transfer is pending") }
    @PluginMethod fun playReceivedSample(call: PluginCall) { call.unimplemented("Android sample transfer is pending") }
    @PluginMethod fun cleanupSamples(call: PluginCall) { call.unimplemented("Android sample transfer is pending") }
    override fun handleOnStop() { session.stop("App backgrounded; foreground and restart/reconnect") }
    override fun handleOnDestroy() { session.destroy() }
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
