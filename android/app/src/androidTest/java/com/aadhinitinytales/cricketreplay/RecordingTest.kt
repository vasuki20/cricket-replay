package com.aadhinitinytales.cricketreplay

import android.content.pm.ActivityInfo
import android.media.MediaMetadataRetriever
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.nio.ByteBuffer

@RunWith(AndroidJUnit4::class)
class RecordingTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun snapshot(engine: RollingRecording): JSONObject {
        val latch = CountDownLatch(1); var result: JSONObject? = null
        engine.status { result = it; latch.countDown() }
        check(latch.await(5, TimeUnit.SECONDS)); return checkNotNull(result)
    }
    @Test fun missingExtractionInputFailsWithoutPublishingClip() {
        val directory = File(context.cacheDir, "recording-failure-test").apply { mkdirs() }
        val output = File(directory, "clip.mp4")
        try {
            val segment = RecordingSegment(File(directory, "missing.mp4"), File(directory, "missing.csv"), 0, 25_000_000, 750, 0)
            try { RecordingClip.extract(listOf(segment), 25_000_000, 20, output); fail("Missing input accepted") } catch (_: Exception) {}
            assertFalse(output.exists()); assertFalse(File(directory, "clip-frames.csv").exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun remuxPreservesSyntheticFramesAndIntervalsAcrossFiles() {
        val directory = File(context.cacheDir, "recording-remux-test").apply { mkdirs() }
        val sample = SampleVideo.generate(context.cacheDir)
        val source = MediaExtractor()
        val segments = mutableListOf<RecordingSegment>()
        val origin = 1_000_000_000_000L
        var output: MediaMuxer? = null; var file: File? = null; var track = -1
        var first = 0L; var last = 0L; var count = 0
        fun seal() {
            output?.stop(); output?.release(); output = null
            val segmentFile = checkNotNull(file)
            segments.add(RecordingSegment(segmentFile, File(directory, "${segments.size}.csv"), origin + first, origin + last, count, 0))
        }
        try {
            source.setDataSource(sample.absolutePath); source.selectTrack(0)
            val bytes = ByteBuffer.allocateDirect(4 * 1024 * 1024)
            while (source.sampleTime >= 0) {
                val pts = source.sampleTime; val sync = source.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                if (output != null && sync && pts - first >= 5_000_000) seal()
                if (output == null) {
                    file = File(directory, "${segments.size}.mp4"); first = pts; count = 0
                    output = MediaMuxer(checkNotNull(file).absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).apply {
                        track = addTrack(source.getTrackFormat(0)); start()
                    }
                }
                bytes.clear(); val size = source.readSampleData(bytes, 0)
                val info = MediaCodec.BufferInfo().apply { set(0, size, pts - first, if (sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0) }
                checkNotNull(output).writeSampleData(track, bytes, info); last = pts; count++; source.advance()
            }
            seal()
            val result = RecordingClip.extract(segments, origin + last, 15, File(directory, "clip.mp4"))
            assertEquals(4, result.getInt("segments")); assertEquals(0, result.getInt("intervalsOver50ms"))
            assertTrue(result.getDouble("effectiveFps") in 29.99..30.01)
            val rows = File(directory, "clip-frames.csv").readLines().drop(1).map { it.split(',') }
            val clip = File(directory, "clip.mp4")
            val forward = RecordingFrame.inspect(clip, 100)
            val next = RecordingFrame.inspect(clip, 101)
            val backward = RecordingFrame.inspect(clip, 100)
            assertEquals(rows.size, forward.getInt("frameCount"))
            assertEquals(rows[100][2].toLong(), forward.getLong("timestampUs"))
            assertTrue(next.getLong("timestampUs") > forward.getLong("timestampUs"))
            assertEquals(forward.getString("pngBase64"), backward.getString("pngBase64"))
            assertNotEquals(forward.getString("pngBase64"), next.getString("pngBase64"))
            try { RecordingFrame.inspect(clip, rows.size); fail("Invalid frame index accepted") } catch (_: Exception) {}
            rows.zipWithNext().forEach { (a, b) -> assertTrue("Original 30fps intervals across file joins", b[1].toLong() - a[1].toLong() in 33_332..33_334) }
            val original = MediaMetadataRetriever(); val remuxed = MediaMetadataRetriever()
            try {
                original.setDataSource(sample.absolutePath); remuxed.setDataSource(File(directory, "clip.mp4").absolutePath)
                var joins = 0
                rows.forEachIndexed { index, row ->
                    if (index > 0 && row[4] != rows[index - 1][4]) {
                        for (frame in listOf(index - 1, index, index + 1)) {
                            val sourceIndex = Math.round((rows[frame][1].toLong() - origin) * 30.0 / 1_000_000).toInt()
                            val a = checkNotNull(original.getFrameAtIndex(sourceIndex)); val b = checkNotNull(remuxed.getFrameAtIndex(frame))
                            try { assertTrue("Exact decoded synthetic frame preserved at join", a.sameAs(b)) } finally { a.recycle(); b.recycle() }
                        }
                        joins++
                    }
                }
                assertTrue(joins >= 2)
            } finally { original.release(); remuxed.release() }
        } finally { runCatching { output?.stop() }; runCatching { output?.release() }; source.release(); sample.delete(); directory.deleteRecursively() }
    }
    @Test fun rearCameraContinuesThroughExtractionAndEviction() {
        val keyguard = context.getSystemService(android.content.Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        assertFalse("Unlock the physical phone before running camera/UI tests", keyguard.isKeyguardLocked)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity {
                it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            // Wait for the display rotation instead of assuming Activity orientation is already applied.
            val rotationDeadline = SystemClock.elapsedRealtime() + 5000
            var landscape = false
            while (!landscape && SystemClock.elapsedRealtime() < rotationDeadline) {
                scenario.onActivity { @Suppress("DEPRECATION")
                    landscape = it.windowManager.defaultDisplay.rotation in listOf(android.view.Surface.ROTATION_90, android.view.Surface.ROTATION_270)
                }
                if (!landscape) SystemClock.sleep(100)
            }
            assertTrue("Unlocked landscape display required", landscape)
            val engine = RollingRecording(context)
            try {
                val started = CountDownLatch(1); var failure: Exception? = null
                var displayRotation = 90
                scenario.onActivity { @Suppress("DEPRECATION")
                    displayRotation = when (it.windowManager.defaultDisplay.rotation) {
                        android.view.Surface.ROTATION_90 -> 90; android.view.Surface.ROTATION_270 -> 270; else -> 0
                    }
                }
                engine.start(RecordingConfig(30, 20), displayRotation) { failure = it; started.countDown() }
                assertTrue("First encoded camera frame", started.await(20, TimeUnit.SECONDS)); assertNull(failure)
                val deadline = SystemClock.elapsedRealtime() + 45_000
                var before = snapshot(engine)
                while (before.getLong("lastPtsUs") - before.getLong("firstPtsUs") < 22_000_000 && SystemClock.elapsedRealtime() < deadline) {
                    SystemClock.sleep(250); before = snapshot(engine); assertEquals(before.getString("detail"), "recording", before.getString("state"))
                }
                val extracted = CountDownLatch(1)
                engine.extract { failure = it; extracted.countDown() }
                assertTrue("Extraction completes without stopping capture", extracted.await(15, TimeUnit.SECONDS)); assertNull(failure)
                val after = snapshot(engine)
                assertEquals("recording", after.getString("state"))
                assertTrue(after.getLong("encodedFrames") > before.getLong("encodedFrames"))
                val clipInfo = after.getJSONObject("extraction")
                assertTrue(clipInfo.getBoolean("ready")); assertTrue(clipInfo.getInt("segments") >= 4)
                assertEquals(3, clipInfo.getInt("decodedFrames"))
                assertTrue(clipInfo.getDouble("durationSeconds") in 19.9..25.0)
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(File(engine.directory, "latest-clip.mp4").absolutePath)
                    assertNotEquals("yes", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO))
                    // Decode adjacent actual frames around every file join, rather than checking PTS alone.
                    val rows = File(engine.directory, "clip-frames.csv").readLines().drop(1)
                    var previousSegment = ""; var decoded = 0
                    rows.forEachIndexed { index, row ->
                        val segment = row.substringAfterLast(',')
                        if (previousSegment.isNotEmpty() && previousSegment != segment) {
                            for (frame in listOf(index - 1, index, index + 1)) {
                                val bitmap = retriever.getFrameAtIndex(frame)
                                assertNotNull("Decode boundary frame $frame", bitmap); bitmap!!.recycle(); decoded++
                            }
                        }
                        previousSegment = segment
                    }
                    assertTrue(decoded >= 9)
                } finally { retriever.release() }
                while (snapshot(engine).getDouble("elapsedSeconds") < 36 && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(250)
                val retained = snapshot(engine)
                assertEquals(retained.toString(), "recording", retained.getString("state"))
                assertTrue("Whole-segment overlap bounded", retained.getDouble("bufferedSeconds") in 29.0..41.0)
                assertTrue(retained.getLong("storageBytes") < RollingRecording.MAX_DISK_BYTES)
                assertEquals(0, retained.getInt("pinnedSegments"))
                val stopped = CountDownLatch(1); engine.stop { stopped.countDown() }
                assertTrue(stopped.await(10, TimeUnit.SECONDS))
                val final = snapshot(engine)
                assertEquals("stopped", final.getString("state"))
                // Metadata only; no camera footage is exported or retained by this automated test.
                File(context.cacheDir, "recording-test-result.json").writeText(File(engine.directory, "report.json").readText())
                android.util.Log.i("RecordingTest", final.toString())
            } finally {
                val stopped = CountDownLatch(1); engine.stop { stopped.countDown() }; stopped.await(10, TimeUnit.SECONDS)
                val report = File(engine.directory, "report.json")
                if (report.exists()) File(context.cacheDir, "recording-test-result.json").writeText(report.readText())
                val cleaned = CountDownLatch(1); engine.cleanup { cleaned.countDown() }; cleaned.await(10, TimeUnit.SECONDS)
                engine.destroy()
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            }
        }
    }
}
