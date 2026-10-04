package com.aadhinitinytales.cricketreplay

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.util.UUID

// Synthetic 20-second H.264 MP4. Uses the encoder's plane strides rather than assuming NV12/I420.
internal object SampleVideo {
    fun generate(cacheDir: File): File {
        val file = File(cacheDir, "cricket-sample-${UUID.randomUUID()}.mp4")
        var codec: MediaCodec? = null; var muxer: MediaMuxer? = null
        var success = false; var muxerStarted = false
        try {
            val format = MediaFormat.createVideoFormat("video/avc", 640, 360).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, 2_000_000); setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
                ?: error("No compatible H.264 encoder")
            val encoder = MediaCodec.createByCodecName(name); codec = encoder
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); encoder.start()
            val output = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); muxer = output
            val info = MediaCodec.BufferInfo(); var frame = 0; var inputDone = false; var outputDone = false; var track = -1
            val deadline = System.nanoTime() + 90_000_000_000L
            while (!outputDone) {
                check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline) { "Sample generation cancelled or timed out" }
                if (!inputDone) {
                    val index = encoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        if (frame == 600) {
                            encoder.queueInputBuffer(index, 0, 0, 20_000_000, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
                        } else {
                            val image = encoder.getInputImage(index) ?: error("Encoder does not expose YUV image planes")
                            try { draw(image, frame) } finally { image.close() }
                            encoder.queueInputBuffer(index, 0, 640 * 360 * 3 / 2, frame * 1_000_000L / 30, 0); frame++
                        }
                    }
                }
                val index = encoder.dequeueOutputBuffer(info, 10_000)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        check(!muxerStarted) { "Encoder format changed twice" }
                        track = output.addTrack(encoder.outputFormat); output.start(); muxerStarted = true
                    }
                    index >= 0 -> {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                check(muxerStarted) { "No encoder output format" }
                                val bytes = checkNotNull(encoder.getOutputBuffer(index))
                                bytes.position(info.offset); bytes.limit(info.offset + info.size)
                                output.writeSampleData(track, bytes, info)
                            }
                            outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally { encoder.releaseOutputBuffer(index, false) }
                    }
                }
            }
            check(muxerStarted && file.length() > 0) { "Encoder produced no video" }
            output.stop(); muxerStarted = false; success = true; return file
        } finally {
            runCatching { codec?.stop() }; runCatching { codec?.release() }
            if (muxerStarted) runCatching { muxer?.stop() }; runCatching { muxer?.release() }
            if (!success) file.delete()
        }
    }
    private fun draw(image: Image, frame: Int) {
        check(image.width == 640 && image.height == 360 && image.planes.size == 3) { "Unsupported encoder image layout" }
        for ((index, plane) in image.planes.withIndex()) {
            val width = if (index == 0) 640 else 320; val height = if (index == 0) 360 else 180
            val buffer = plane.buffer; val origin = buffer.position(); val row = ByteArray((width - 1) * plane.pixelStride + 1)
            for (y in 0 until height) {
                row.fill(if (index == 0) 35 else 128.toByte())
                if (index == 0) {
                    val ballX = 20 + (frame * 4 % 600)
                    for (x in maxOf(0, ballX - 20)..minOf(639, ballX + 20)) {
                        if ((x - ballX) * (x - ballX) + (y - 180) * (y - 180) < 400) row[x * plane.pixelStride] = 220.toByte()
                    }
                    if (y in 30..49) for (tick in 0..frame / 30) for (x in 15 + tick * 30 until 35 + tick * 30) row[x * plane.pixelStride] = 180.toByte()
                }
                buffer.position(origin + y * plane.rowStride); buffer.put(row)
            }
        }
    }
}
