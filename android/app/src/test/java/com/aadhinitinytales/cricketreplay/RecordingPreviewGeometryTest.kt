package com.aadhinitinytales.cricketreplay

import org.junit.Assert.*
import org.junit.Test

class RecordingPreviewGeometryTest {
    @Test fun bothLandscapeDirectionsCancelDeviceRotation() {
        for (sensor in listOf(90, 270)) for (display in listOf(90, 270)) {
            val result = previewGeometry(320, 180, 1280, 720, sensor, display)
            assertEquals(180, result.width); assertEquals(320, result.height)
            assertEquals(-display.toFloat(), result.rotation, 0.01f)

        }
    }
    @Test fun fourByThreePreviewFitsWithoutStretching() {
        val result = previewGeometry(320, 180, 640, 480, 90, 90)
        assertEquals(180, result.width); assertEquals(240, result.height)
        assertEquals(480f / 640, result.width.toFloat() / result.height, 0.001f)
    }
}
