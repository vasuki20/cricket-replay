package com.aadhinitinytales.cricketreplay

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.TextView
import android.widget.VideoView
import java.io.File

// Dialog keeps the main Activity foreground while reviewing a completed local file.
internal class SamplePlayer(activity: Activity, file: File, done: (String?) -> Unit, dismissed: () -> Unit) {
    private val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
    private val video = VideoView(activity)
    init {
        val handler = Handler(Looper.getMainLooper()); var settled = false
        val layout = FrameLayout(activity); layout.setBackgroundColor(Color.BLACK)
        layout.addView(video, FrameLayout.LayoutParams(-1, -1))
        val errorText = TextView(activity).apply { setTextColor(Color.WHITE); gravity = Gravity.CENTER }
        val close = Button(activity).apply { text = "Close playback"; setOnClickListener { dialog.dismiss() } }
        layout.addView(close, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END))
        val timeout = Runnable { if (!settled) { settled = true; done("Playback preparation timed out"); dialog.dismiss() } }
        video.setMediaController(MediaController(activity).apply { setAnchorView(video) })
        video.setOnPreparedListener { handler.removeCallbacks(timeout); video.start(); if (!settled) { settled = true; done(null) } }
        video.setOnErrorListener { _, _, _ ->
            handler.removeCallbacks(timeout)
            if (!settled) { settled = true; done("Cannot play received MP4") }
            errorText.text = "Cannot play received MP4. Close playback and retry."
            if (errorText.parent == null) layout.addView(errorText, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
            true
        }
        dialog.setContentView(layout)
        dialog.setOnDismissListener {
            handler.removeCallbacks(timeout); video.stopPlayback()
            if (!settled) { settled = true; done("Playback cancelled") }; dismissed()
        }
        dialog.show(); dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        handler.postDelayed(timeout, 15_000); video.setVideoURI(Uri.fromFile(file))
    }
    fun dismiss() { dialog.dismiss() }
}
