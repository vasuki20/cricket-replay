package com.aadhinitinytales.cricketreplay

import java.io.File

internal data class RecordingConfig(val retentionSeconds: Int = 120, val reviewSeconds: Int = 20) {
    init {
        require(retentionSeconds in 30..180) { "Retention must be an integer from 30 to 180 seconds" }
        require(reviewSeconds in 5..30 && reviewSeconds <= retentionSeconds - 10) { "Review must be 5–30 seconds and at least 10 seconds shorter than retention" }
    }
}

// Owned by the recording Handler, including pin acquisition/release. Worker only reads pinned files.
internal data class RecordingSegment(val file: File, val timestamps: File, val firstUs: Long,
    val lastUs: Long, val frames: Int, val rotation: Int, var pins: Int = 0)

internal class RecordingBuffer(private val config: RecordingConfig) {
    val segments = mutableListOf<RecordingSegment>()
    fun pin(endUs: Long): List<RecordingSegment> {
        val cutoff = endUs - config.reviewSeconds * 1_000_000L
        val selected = segments.filter { it.lastUs >= cutoff && it.firstUs <= endUs }
        check(selected.isNotEmpty() && selected.first().firstUs <= cutoff) { "Not enough buffered footage; wait for the review window" }
        selected.forEach { it.pins++ }
        return selected.toList()
    }
    fun release(selected: List<RecordingSegment>) { selected.forEach { check(it.pins > 0); it.pins-- } }
    fun evict(latestUs: Long) {
        val cutoff = latestUs - config.retentionSeconds * 1_000_000L
        val expired = segments.filter { it.lastUs < cutoff && it.pins == 0 }
        expired.forEach {
            check(!it.file.exists() || it.file.delete()) { "Cannot evict recording segment" }
            check(!it.timestamps.exists() || it.timestamps.delete()) { "Cannot evict frame timestamps" }
            segments.remove(it)
        }
    }
}
