package com.aadhinitinytales.cricketreplay

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class RecordingBufferTest {
    @Test fun configurationRejectsInvalidWindows() {
        for ((retention, review) in listOf(29 to 20, 181 to 20, 120 to 4, 120 to 31, 30 to 25)) {
            try { RecordingConfig(retention, review); fail("Invalid configuration accepted") } catch (_: IllegalArgumentException) {}
        }
        assertEquals(120, RecordingConfig().retentionSeconds)
        RecordingConfig(30, 20); RecordingConfig(180, 30)
    }
    @Test fun pinnedSegmentsSurviveEvictionUntilReleased() {
        val directory = Files.createTempDirectory("recording-buffer-test").toFile()
        try {
            val buffer = RecordingBuffer(RecordingConfig(30, 20))
            for (i in 0..7) buffer.segments.add(RecordingSegment(
                File(directory, "$i.mp4").apply { writeText("video") },
                File(directory, "$i.csv").apply { writeText("timestamps") },
                i * 5_000_000L, (i + 1) * 5_000_000L - 33_333, 150, 0))
            val pinned = buffer.pin(29_966_667)
            assertTrue(pinned.size >= 4)
            buffer.evict(90_000_000)
            assertEquals(pinned, buffer.segments)
            assertTrue(pinned.all { it.file.exists() && it.timestamps.exists() })
            buffer.release(pinned); buffer.evict(90_000_000)
            assertTrue(buffer.segments.isEmpty()); assertTrue(directory.listFiles()!!.isEmpty())
        } finally { directory.deleteRecursively() }
    }
    @Test fun insufficientFootageDoesNotAcquirePins() {
        val buffer = RecordingBuffer(RecordingConfig())
        try { buffer.pin(5_000_000); fail("Missing inputs accepted") } catch (_: IllegalStateException) {}
        assertTrue(buffer.segments.isEmpty())
    }
}
