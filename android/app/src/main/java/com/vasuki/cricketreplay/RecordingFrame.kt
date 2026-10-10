package com.aadhinitinytales.cricketreplay

import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import org.json.JSONObject

// Worker-only: index actual compressed sample PTS, decode an actual presentation frame.
internal object RecordingFrame {
    fun inspect(file: File, index: Int): JSONObject {
        check(Build.VERSION.SDK_INT >= 28) { "Recorded frame inspection requires Android 9 or later" }
        val times = mutableListOf<Long>()
        val source = MediaExtractor()
        try {
            source.setDataSource(file.path)
            val track = (0 until source.trackCount).firstOrNull { source.getTrackFormat(it).getString("mime")?.startsWith("video/") == true } ?: error("No video track")
            source.selectTrack(track)
            while (source.sampleTime >= 0) {
                val pts = source.sampleTime
                check(times.isEmpty() || pts > times.last()) { "Frame order unsupported by this inspector" }
                check(times.size < 10000) { "Inspection exceeds experiment frame bound" }
                times.add(pts)
                if (!source.advance()) break
            }
        } finally { source.release() }
        check(index in times.indices) { "Frame index outside recorded clip" }
        val decoder = MediaMetadataRetriever()
        try {
            decoder.setDataSource(file.path)
            val count = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull()
            check(count == times.size) { "Decoder/sample frame counts differ; exact index inspection unavailable" }
            val bitmap = decoder.getFrameAtIndex(index) ?: error("Recorded frame could not decode")
            try {
                val scale = minOf(1.0, 640.0 / bitmap.width, 640.0 / bitmap.height)
                val shown = if (scale < 1) Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(1), (bitmap.height * scale).toInt().coerceAtLeast(1), true) else bitmap
                try {
                    val bytes = ByteArrayOutputStream(); check(shown.compress(Bitmap.CompressFormat.PNG, 100, bytes))
                    return JSONObject().put("index", index).put("frameCount", times.size).put("timestampUs", times[index])
                        .put("width", shown.width).put("height", shown.height).put("pngBase64", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP))
                } finally { if (shown !== bitmap) shown.recycle() }
            } finally { bitmap.recycle() }
        } finally { decoder.release() }
    }
}
