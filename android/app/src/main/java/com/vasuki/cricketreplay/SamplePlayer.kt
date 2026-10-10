package com.aadhinitinytales.cricketreplay

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.VideoView
import java.io.File
import kotlin.math.max

// One foreground dialog owns playback throughout rotation. Controls never use floating windows.
internal class SamplePlayer(activity: Activity, file: File, done: (String?) -> Unit, dismissed: () -> Unit, rate: Float = 1f, frames: (() -> Unit)? = null) {
    private val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
    private val video = VideoView(activity)
    private var restorePosition = 0
    private var restorePlaying = true
    private var suspended = false
    init {
        val handler = Handler(Looper.getMainLooper())
        var settled = false; var ready = false; var dragging = false; var fill = false; var speed = rate
        fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
        val previousOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        var wantsFrames = false
        val layout = FrameLayout(activity).apply { setBackgroundColor(Color.rgb(10, 17, 14)) }
        fun button(label: String, action: () -> Unit) = Button(activity).apply {
            text = label; isAllCaps = false; textSize = 14f; letterSpacing = 0f
            typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
            minWidth = 0; minimumWidth = 0; stateListAnimator = null; includeFontPadding = false
            setPadding(dp(16), 0, dp(16), 0); setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(-2, dp(48)).apply { marginStart = dp(6) }
            val shape = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xCC17231E.toInt()); cornerRadius = dp(24).toFloat(); setStroke(dp(1), 0x24FFFFFF)
            }
            background = android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x33FFFFFF), shape, null)
            minHeight = dp(48); minimumHeight = dp(48); setOnClickListener { action() }
        }
        val stage = FrameLayout(activity).apply { setBackgroundColor(Color.BLACK); clipChildren = true }
        stage.addView(video, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        fun fitVideo() {
            val scale = if (fill && video.width > 0 && video.height > 0) max(stage.width.toFloat() / video.width, stage.height.toFloat() / video.height) else 1f
            video.scaleX = scale; video.scaleY = scale
        }
        val top = LinearLayout(activity).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(10), dp(8), dp(10), dp(8)) }
        val title = TextView(activity).apply { text = "Video"; textSize = 14f; setTextColor(Color.WHITE); setPadding(dp(6), 0, 0, 0) }
        top.addView(title, LinearLayout.LayoutParams(0, dp(48), 1f))
        val sizing = button("Fill") { fill = !fill; fitVideo() }
        sizing.setOnClickListener { fill = !fill; sizing.text = if (fill) "Fit" else "Fill"; fitVideo() }
        if (frames != null) top.addView(button("Frames") { wantsFrames = true; dialog.dismiss() })
        top.addView(sizing); top.addView(button("Close") { dialog.dismiss() })
        layout.addView(stage, FrameLayout.LayoutParams(-1, -1))
        top.setBackgroundColor(0xAA000000.toInt())
        layout.addView(top, FrameLayout.LayoutParams(-1, dp(64), Gravity.TOP))
        val seek = SeekBar(activity).apply { isEnabled = false; max = 1000; contentDescription = "Replay position" }
        val controls = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(0xAA000000.toInt()) }
        controls.addView(seek, LinearLayout.LayoutParams(-1, dp(40)))
        val bottom = LinearLayout(activity).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(10), dp(8), dp(10), dp(8)) }
        val play = button("Pause") { if (ready) { if (video.isPlaying) video.pause() else video.start() } }
        val position = TextView(activity).apply { setTextColor(Color.WHITE); gravity = Gravity.CENTER }
        fun time(ms: Int): String = "%d:%02d".format(ms.coerceAtLeast(0) / 60000, ms.coerceAtLeast(0) / 1000 % 60)
        val speedButton = button("${speed}×") {}
        speedButton.setOnClickListener {
            if (!ready) return@setOnClickListener
            val next = when (speed) { 1f -> .5f; .5f -> .25f; else -> 1f }
            val playing = video.isPlaying
            try { media?.playbackParams = android.media.PlaybackParams().setSpeed(next).setPitch(1f); speed = next; speedButton.text = "${speed}×"; if (!playing) video.pause() }
            catch (_: Exception) { position.text = "Speed unavailable" }
        }
        bottom.addView(play); bottom.addView(position, LinearLayout.LayoutParams(0, dp(48), 1f)); bottom.addView(speedButton)
        controls.addView(bottom)
        layout.addView(controls, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        val hideControls = Runnable { if (!dragging) { top.visibility = View.GONE; controls.visibility = View.GONE } }
        fun showControls() { top.visibility = View.VISIBLE; controls.visibility = View.VISIBLE; handler.removeCallbacks(hideControls); handler.postDelayed(hideControls, 3500) }
        stage.setOnClickListener { if (top.visibility == View.VISIBLE) { top.visibility = View.GONE; controls.visibility = View.GONE; handler.removeCallbacks(hideControls) } else showControls() }
        video.setOnTouchListener { _, event -> if (event.action == android.view.MotionEvent.ACTION_UP) stage.performClick(); true }
        for (row in listOf(top, bottom)) for (i in 0 until row.childCount) row.getChildAt(i).setOnTouchListener { _, _ -> showControls(); false }
        showControls()

        seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(bar: SeekBar) { dragging = true; handler.removeCallbacks(hideControls) }
            override fun onProgressChanged(bar: SeekBar, value: Int, user: Boolean) { if (user && ready) position.text = "${time(video.duration * value / 1000)} / ${time(video.duration)}" }
            override fun onStopTrackingTouch(bar: SeekBar) { if (ready) video.seekTo(video.duration * bar.progress / 1000); dragging = false; showControls() }
        })
        val tick = object : Runnable {
            override fun run() {
                if (ready && !dragging) { val duration = video.duration.coerceAtLeast(1); seek.progress = (video.currentPosition.toLong() * 1000 / duration).toInt(); position.text = "${time(video.currentPosition)} / ${time(duration)}"; play.text = if (video.isPlaying) "Pause" else "Play" }
                handler.postDelayed(this, 250)
            }
        }
        val timeout = Runnable { if (!settled) { settled = true; done("Playback preparation timed out"); dialog.dismiss() } }
        video.setOnPreparedListener { player ->
            handler.removeCallbacks(timeout); media = player
            try {
                player.playbackParams = android.media.PlaybackParams().setSpeed(speed).setPitch(1f)
                ready = true; seek.isEnabled = true; if (restorePosition > 0) video.seekTo(restorePosition)
                if (restorePlaying) video.start() else video.pause(); video.post { fitVideo() }; handler.removeCallbacks(tick); handler.post(tick)
                if (!settled) { settled = true; done(null) }
            } catch (error: Exception) { if (!settled) { settled = true; done("Decoder cannot play at requested speed: ${error.message}") }; dialog.dismiss() }
        }
        video.setOnErrorListener { _, _, _ ->
            handler.removeCallbacks(timeout); ready = false; seek.isEnabled = false; position.text = "Playback unavailable"
            if (!settled) { settled = true; done("Cannot play received MP4") }; true
        }
        video.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitVideo() }
        layout.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION") view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        dialog.setContentView(layout)
        dialog.setOnDismissListener {
            handler.removeCallbacksAndMessages(null); video.stopPlayback(); media = null
            if (!settled) { settled = true; done("Playback cancelled") }; if (!wantsFrames) activity.requestedOrientation = previousOrientation; dismissed(); if (wantsFrames) frames?.invoke()
        }
        dialog.show()
        dialog.window?.apply { setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT); addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        layout.requestApplyInsets(); handler.postDelayed(timeout, 15_000); video.setVideoURI(Uri.fromFile(file))
    }
    private var media: android.media.MediaPlayer? = null
    fun background() {
        if (suspended) return
        restorePosition = video.currentPosition; restorePlaying = video.isPlaying; suspended = true; video.suspend()
    }
    fun foreground() { if (suspended) { suspended = false; video.resume() } }
    fun dismiss() { dialog.dismiss() }
}
