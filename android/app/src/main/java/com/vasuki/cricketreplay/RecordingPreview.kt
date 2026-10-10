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
    private val host = FrameLayout(activity).apply { isClickable = false; clipChildren = true; setBackgroundColor(android.graphics.Color.BLACK) }
    private val texture = TextureView(activity).apply { isClickable = false }
    private var surface: Surface? = null
    private var waiting = mutableListOf<PluginCall>()
    private var attached = false
    private var bufferWidth = 1280
    private var bufferHeight = 720
    private var sensorOrientation = 90
    private var displayRotation = 0

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
        if (call.getBoolean("fullscreen", false) == true) {
            web.setBackgroundColor(android.graphics.Color.TRANSPARENT); web.bringToFront()
        } else host.bringToFront()
        // Alpha avoids destroying/recreating a Camera2 target when it leaves the screen.
        host.alpha = if (visible) 1f else 0f
        fit((width * scale).roundToInt(), (height * scale).roundToInt())
        if (!visible || surface != null) call.resolve() else {
            waiting.add(call)
            host.postDelayed({ if (waiting.remove(call)) call.reject("Camera preview did not become ready; try again") }, 3000)
        }
    }
    fun output(): Surface? = surface
    fun configure(width: Int, height: Int, sensorDegrees: Int, displayDegrees: Int) {
        texture.surfaceTexture?.setDefaultBufferSize(width, height)
        activity.runOnUiThread {
            bufferWidth = width; bufferHeight = height
            sensorOrientation = sensorDegrees; displayRotation = displayDegrees
            fit(host.width, host.height)
        }
    }
    private fun fit(width: Int, height: Int) {
        val currentRotation = web.display?.rotation?.times(90) ?: displayRotation
        val geometry = previewGeometry(width, height, bufferWidth, bufferHeight, sensorOrientation, currentRotation)
        texture.layoutParams = FrameLayout.LayoutParams(geometry.width, geometry.height, android.view.Gravity.CENTER)
        // TextureView already rotates camera buffers into the display's natural orientation.
        // Rotate the view only for device rotation; never reuse MP4 orientation metadata here.
        texture.rotation = geometry.rotation
    }
    fun hide() { host.alpha = 0f }
    fun destroy() {
        waiting.toList().forEach { it.reject("App closed") }; waiting.clear()
        (host.parent as? ViewGroup)?.removeView(host); attached = false
        surface?.release(); surface = null
    }
}

internal data class PreviewGeometry(val width: Int, val height: Int, val rotation: Float)
internal fun previewGeometry(width: Int, height: Int, bufferWidth: Int, bufferHeight: Int,
                             sensorDegrees: Int, displayDegrees: Int): PreviewGeometry {
    val naturalWidth = if (sensorDegrees % 180 == 0) bufferWidth else bufferHeight
    val naturalHeight = if (sensorDegrees % 180 == 0) bufferHeight else bufferWidth
    val uprightWidth = if (displayDegrees % 180 == 0) naturalWidth else naturalHeight
    val uprightHeight = if (displayDegrees % 180 == 0) naturalHeight else naturalWidth
    val scale = min(width.toFloat() / uprightWidth, height.toFloat() / uprightHeight)
    return PreviewGeometry((naturalWidth * scale).roundToInt().coerceAtLeast(1),
        (naturalHeight * scale).roundToInt().coerceAtLeast(1), -displayDegrees.toFloat())
}
