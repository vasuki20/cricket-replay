package com.aadhinitinytales.cricketreplay

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer

internal object RecordingClip {
    // No transcoding: start at the preceding sync sample, preserve original intervals across files.
    fun extract(segments: List<RecordingSegment>, endUs: Long, reviewSeconds: Int, output: File): JSONObject {
        val cutoff = endUs - reviewSeconds * 1_000_000L
        val deadline = System.nanoTime() + 30_000_000_000L
        var muxer: MediaMuxer? = null
        var started = false; var success = false; var base = -1L; var last = -1L; var frames = 0
        var maxDelta = 0L; var gaps = 0; var track = -1; var width = 0; var height = 0
        val csv = File(output.parentFile, "clip-frames.csv")
        try {
            val writer = csv.bufferedWriter()
            writer.use {
                it.write("frame,sourcePtsUs,clipPtsUs,deltaUs,segment\n")
                val bytes = ByteBuffer.allocateDirect(4 * 1024 * 1024)
                for ((index, segment) in segments.withIndex()) {
                    val extractor = MediaExtractor()
                    try {
                        extractor.setDataSource(segment.file.absolutePath)
                        check(extractor.trackCount == 1) { "Expected one silent video track" }
                        val format = extractor.getTrackFormat(0)
                        check(format.getString(MediaFormat.KEY_MIME) == "video/avc")
                        extractor.selectTrack(0)
                        if (index == 0) extractor.seekTo((cutoff - segment.firstUs).coerceAtLeast(0), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        if (muxer == null) {
                            width = format.getInteger(MediaFormat.KEY_WIDTH); height = format.getInteger(MediaFormat.KEY_HEIGHT)
                            muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).apply {
                                setOrientationHint(segment.rotation); track = addTrack(format); start(); started = true
                            }
                        } else check(format.getInteger(MediaFormat.KEY_WIDTH) == width && format.getInteger(MediaFormat.KEY_HEIGHT) == height) { "Segment format mismatch" }
                        while (extractor.sampleTime >= 0) {
                            check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline) { "Clip extraction cancelled or exceeded 30 seconds" }
                            val pts = segment.firstUs + extractor.sampleTime
                            if (pts > endUs) break
                            bytes.clear()
                            val size = extractor.readSampleData(bytes, 0)
                            check(size in 1..bytes.capacity()) { "Invalid or oversized encoded frame" }
                            if (base < 0) {
                                check(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) { "Clip must begin with a keyframe" }
                                base = pts
                            }
                            check(last < 0 || pts > last) { "Non-monotonic clip timestamps" }
                            val delta = if (last < 0) 0 else pts - last
                            check(delta <= 100_000) { "Partial footage: recorded frame interval exceeds 100 ms" }
                            maxDelta = maxOf(maxDelta, delta); if (delta > 50_000) gaps++
                            val info = MediaCodec.BufferInfo().apply { set(0, size, pts - base,
                                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0) }
                            checkNotNull(muxer).writeSampleData(track, bytes, info)
                            it.write("$frames,$pts,${pts - base},$delta,${segment.file.name}\n")
                            frames++; last = pts; extractor.advance()
                        }
                    } finally { extractor.release() }
                }
            }
            check(frames > 1 && last >= cutoff) { "No complete review footage" }
            check(base <= cutoff && cutoff - base <= 5_000_000) { "Keyframe lead-in exceeds five seconds" }
            checkNotNull(muxer).stop(); started = false
            val inspection = inspect(output, frames)
            check(System.nanoTime() < deadline) { "Clip frame inspection exceeded 30 seconds" }
            success = true
            return JSONObject().put("ready", true).put("bytes", output.length()).put("frames", frames)
                .put("width", width).put("height", height).put("durationSeconds", (last - base) / 1_000_000.0)
                .put("effectiveFps", (frames - 1) * 1_000_000.0 / (last - base))
                .put("sourceFirstUs", base).put("sourceLastUs", last).put("leadInSeconds", (cutoff - base) / 1_000_000.0)
                .put("segments", segments.size).put("maxFrameDeltaMs", maxDelta / 1000.0).put("intervalsOver50ms", gaps)
                .put("decodedFrames", inspection)
        } finally {
            if (started) runCatching { muxer?.stop() }; runCatching { muxer?.release() }
            if (!success) { output.delete(); csv.delete() }
        }
    }

    // Decode beginning/middle/end as a smoke check; timestamps alone cannot establish visible continuity.
    private fun inspect(file: File, frames: Int): Int {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            check(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) != "yes") { "Unexpected audio" }
            var decoded = 0
            for (index in listOf(0, frames / 2, frames - 1)) {
                val bitmap = if (android.os.Build.VERSION.SDK_INT >= 28) retriever.getFrameAtIndex(index)
                    else retriever.getFrameAtTime(if (index == 0) 0 else index * 1_000_000L / 30, MediaMetadataRetriever.OPTION_CLOSEST)
                checkNotNull(bitmap) { "Cannot decode clip frame $index" }; bitmap.recycle(); decoded++
            }
            return decoded
        } finally { retriever.release() }
    }
}
