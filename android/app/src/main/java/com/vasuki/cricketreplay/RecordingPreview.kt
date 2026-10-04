package com.aadhinitinytales.cricketreplay

import android.app.Activity
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.coordinatorlayout.widget.CoordinatorLayout
import com.getcapacitor.PluginCall
import kotlin.math.min
import kotlin.math.roundToInt

// UI thread owns layout. The SurfaceTexture stays alive through scrolling and clip playback.
internal class RecordingPreview(private val activity: Activity, private val web: WebView) {
    private val host = FrameLayout(activity).apply { isClickable = false; clipChildren = true }
    private val texture = TextureView(activity).apply { isClickable = false }
    private var surface: Surface? = null
    private var waiting = mutableListOf<PluginCall>()
    private var attached = false
    private var bufferWidth = 1280
    private var bufferHeight = 720
    private var rotation = 0

    init {
        host.addView(texture)
        texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(value: SurfaceTexture, width: Int, height: Int) {
                value.setDefaultBufferSize(bufferWidth, bufferHeight); surface = Surface(value)
                waiting.toList().forEach { it.resolve() }; waiting.clear()
            }
            override fun onSurfaceTextureSizeChanged(value: SurfaceTexture, width: Int, height: Int) {
                // View layout must not change the configured camera stream dimensions.
                value.setDefaultBufferSize(bufferWidth, bufferHeight)
            }
            override fun onSurfaceTextureUpdated(value: SurfaceTexture) {}
            override fun onSurfaceTextureDestroyed(value: SurfaceTexture): Boolean {
                surface?.release(); surface = null
                waiting.toList().forEach { it.reject("Camera preview closed before it was ready") }; waiting.clear()
                return true
            }
        }
    }
    fun layout(call: PluginCall) {
        val visible = call.getBoolean("visible", false) == true
        if (!visible && !attached) { call.resolve(); return }
        val viewport = call.getDouble("viewportWidth") ?: 0.0
        val x = call.getDouble("x") ?: Double.NaN; val y = call.getDouble("y") ?: Double.NaN
        val width = call.getDouble("width") ?: 0.0; val height = call.getDouble("height") ?: 0.0
        if (!listOf(viewport, x, y, width, height).all { it.isFinite() } || viewport <= 0 || width <= 0 || height <= 0) {
            call.reject("Invalid camera preview bounds"); return
        }
        val parent = web.parent as? ViewGroup ?: run { call.reject("Camera preview container unavailable"); return }
        val scale = web.width / viewport
        val nativeWidth = (width * scale).roundToInt().coerceAtLeast(1)
        val nativeHeight = (height * scale).roundToInt().coerceAtLeast(1)
        val params = when (parent) {
            is CoordinatorLayout -> CoordinatorLayout.LayoutParams(nativeWidth, nativeHeight)
            is FrameLayout -> FrameLayout.LayoutParams(nativeWidth, nativeHeight)
            else -> { call.reject("Unsupported camera preview container"); return }
        }.apply {
            leftMargin = web.left + (x * scale).roundToInt(); topMargin = web.top + (y * scale).roundToInt()
        }
        if (!attached) { parent.addView(host, params); attached = true } else host.layoutParams = params
        // Alpha avoids destroying/recreating a Camera2 target when it leaves the screen.
        host.alpha = if (visible) 1f else 0f
        fit((width * scale).roundToInt(), (height * scale).roundToInt())
        if (!visible || surface != null) call.resolve() else {
            waiting.add(call)
            host.postDelayed({ if (waiting.remove(call)) call.reject("Camera preview did not become ready; try again") }, 3000)
        }
    }
    fun output(): Surface? = surface
    fun configure(width: Int, height: Int, degrees: Int) {
        texture.surfaceTexture?.setDefaultBufferSize(width, height)
        activity.runOnUiThread { bufferWidth = width; bufferHeight = height; rotation = degrees; fit(host.width, host.height) }
    }
    private fun fit(width: Int, height: Int) {
        val scale = min(width.toFloat() / bufferWidth, height.toFloat() / bufferHeight)
        texture.layoutParams = FrameLayout.LayoutParams((bufferWidth * scale).roundToInt().coerceAtLeast(1), (bufferHeight * scale).roundToInt().coerceAtLeast(1), android.view.Gravity.CENTER)
        texture.rotation = rotation.toFloat()
    }
    fun hide() { host.alpha = 0f }
    fun destroy() {
        waiting.toList().forEach { it.reject("App closed") }; waiting.clear()
        (host.parent as? ViewGroup)?.removeView(host); attached = false
        surface?.release(); surface = null
    }
}
