package com.aadhinitinytales.cricketreplay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Two native endpoints on one phone, generated footage only. Not a physical pairing pass.
@RunWith(AndroidJUnit4::class)
class ReviewFlowTest {
    private fun snapshot(session: LocalSession): JSONObject {
        val done = CountDownLatch(1); var value = JSONObject()
        session.status { value = it; done.countDown() }
        assertTrue(done.await(3, TimeUnit.SECONDS)); return value
    }
    private fun waitFor(detail: String, check: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (System.nanoTime() < end) { if (check()) return; Thread.sleep(20) }
        fail(detail)
    }
    @Test fun encryptedRecordingReviewsDecodeAndRetainSourceTiming() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val address = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && it.name.startsWith("wlan") }
            .flatMap { it.inetAddresses.toList().filterIsInstance<Inet4Address>() }.mapNotNull { it.hostAddress }.firstOrNull(PairingCode::validAddress)
        assertNotNull("Join Wi-Fi for the native loopback test", address)
        val source = SampleVideo.generate(context.cacheDir)
        val first = RecordingFrame.inspect(source, 0)
        val frames = first.getInt("frameCount")
        val last = RecordingFrame.inspect(source, frames - 1)
        val host = LocalSession({ listOf("wlan0: $address") }, {}, File(context.cacheDir, "review-host-${UUID.randomUUID()}"))
        val camera = LocalSession({ listOf("wlan0: $address") }, {}, File(context.cacheDir, "review-camera-${UUID.randomUUID()}"))
        val viewers = (0..1).map { LocalSession({ listOf("wlan0: $address") }, {}, File(context.cacheDir, "viewer-${UUID.randomUUID()}")) }
        viewers.forEach { it.validateReceivedReview = RecordingFrame::validateReview }
        val viewerSecret = PairingCode.newSecret(); val viewerPort = ServerSocket(0).use { it.localPort }
        val secret = PairingCode.newSecret(); val port = ServerSocket(0).use { it.localPort }
        var endpoint = 0L; var unavailable = false; var corrupt = false
        host.validateReceivedReview = RecordingFrame::validateReview
        camera.onReview = { tap, done -> endpoint = tap; done(if (unavailable) IllegalStateException("Requested window is not available") else null) }
        camera.exportReview = { done ->
            val copy = File.createTempFile("review-source-", ".mp4", context.cacheDir)
            source.copyTo(copy, overwrite = true)
            if (corrupt) copy.writeBytes(byteArrayOf(1, 2, 3))
            val origin = endpoint - 20_000_000
            done(copy, JSONObject().put("sourceFirstUs", origin).put("sourceLastUs", origin + last.getLong("timestampUs"))
                .put("requestedHostUs", endpoint).put("requestedSourceUs", endpoint).put("endpointErrorUs", last.getLong("timestampUs") - 20_000_000)
                .put("frames", frames).put("retentionSeconds", 120).put("reviewSeconds", 20), null)
        }
        fun review() = snapshot(host).optJSONObject("review") ?: JSONObject()
        fun calibrate() { host.measureClock(); waitFor("Eight clock samples") { snapshot(host).optJSONObject("clock")?.optInt("samples") == 8 } }
        fun request(delay: Int = 0, tapUs: Double? = null) {
            val done = CountDownLatch(1); var error: Exception? = null
            host.requestReview(delay, tapUs) { error = it; done.countDown() }
            assertTrue(done.await(3, TimeUnit.SECONDS)); assertNull(error)
        }
        try {
            val started = CountDownLatch(1); var error: Exception? = null
            host.startHost(secret, port) { error = it; started.countDown() }
            assertTrue(started.await(3, TimeUnit.SECONDS)); assertNull(error)
            val viewerStarted = CountDownLatch(1)
            host.startViewers(viewerSecret, viewerPort) { assertNull(it); viewerStarted.countDown() }
            assertTrue(viewerStarted.await(3, TimeUnit.SECONDS))
            viewers.forEach { it.connect(address!!, viewerSecret, viewerPort, viewer = true) }
            waitFor("Two viewer connections") { viewers.all { snapshot(it).optBoolean("authenticated") } }
            viewers[0].fetchPublished { assertNull(it) }
            waitFor("No replay yet is explicit") { snapshot(viewers[0]).optJSONObject("review")?.optString("state") == "failed" }
            camera.connect(address!!, secret, port)
            waitFor("Mutual authentication") { snapshot(host).optBoolean("authenticated") && snapshot(camera).optBoolean("authenticated") }
            camera.matchStatus = { done -> done(JSONObject().put("state", "recording").put("elapsedSeconds", 40).put("reviewSeconds", 20)) }
            host.requestMatchStatus { assertTrue(it) }
            waitFor("Camera recording status") { snapshot(host).optJSONObject("peerRecording")?.optString("state") == "recording" }
            for (delay in listOf(0, 2000, 5000)) {
                val tap = android.os.SystemClock.elapsedRealtimeNanos() / 1000.0
                calibrate(); request(delay, tap)
                assertEquals(tap, review().getDouble("tapUs"), 1.0)
                val mappedTap = review().getDouble("peerTapUs")
                waitFor("Verified host recording") { review().optString("state") == "ready" }
                assertTrue(kotlin.math.abs(endpoint - mappedTap) <= 1)
                val transfer = snapshot(host).getJSONObject("transfer")
                assertEquals("recording", transfer.getString("media")); assertTrue(transfer.getBoolean("checksumVerified"))
                if (delay == 0) {
                    val held = CountDownLatch(1)
                    host.acquireReview { file, _ -> assertNotNull(file); held.countDown() }
                    assertTrue(held.await(3, TimeUnit.SECONDS))
                    val tapBefore = endpoint
                    viewers.forEach { it.fetchPublished { failure -> assertNull(failure) } }
                    waitFor("Both viewers verify latest replay while host plays") { viewers.all { snapshot(it).optJSONObject("review")?.optString("state") == "ready" } }
                    assertEquals("Viewer never asks camera to extract", tapBefore, endpoint)
                    viewers.forEach { assertTrue(snapshot(it).getJSONObject("transfer").getBoolean("checksumVerified")) }
                    host.releaseMedia()
                    val forbidden = CountDownLatch(1)
                    viewers[0].endPeerMatch { acknowledged -> assertFalse(acknowledged); forbidden.countDown() }
                    assertTrue(forbidden.await(3, TimeUnit.SECONDS))
                    assertTrue("Viewer cannot end camera session", snapshot(camera).optBoolean("authenticated"))
                    assertTrue("Other viewer stays connected", snapshot(viewers[1]).optBoolean("authenticated"))
                    viewers[0].connect(address!!, viewerSecret, viewerPort, viewer = true)
                    waitFor("Viewer reconnect retains verified replay") { snapshot(viewers[0]).optBoolean("authenticated") && snapshot(viewers[0]).optJSONObject("review")?.optString("state") == "ready" }
                    val retained = CountDownLatch(1)
                    viewers[0].acquireReview { file, info -> assertNotNull(file); assertNotNull(info); retained.countDown() }
                    assertTrue(retained.await(3, TimeUnit.SECONDS)); viewers[0].releaseMedia()
                }
                assertEquals(endpoint - 20_000_000 + last.getLong("timestampUs"), transfer.getJSONObject("recording").getLong("sourceLastUs"))
                val acquired = CountDownLatch(1)
                host.acquireReview { file, metadata ->
                    assertNotNull(file); assertNotNull(metadata)
                    val received = RecordingFrame.inspect(file!!, frames - 1)
                    assertEquals(last.getLong("timestampUs"), received.getLong("timestampUs")); assertEquals(frames, received.getInt("frameCount"))
                    acquired.countDown()
                }
                assertTrue(acquired.await(5, TimeUnit.SECONDS))
                val blocked = CountDownLatch(1)
                host.cleanupTransfer { assertNotNull(it); blocked.countDown() }
                assertTrue(blocked.await(3, TimeUnit.SECONDS))
                host.reviewPlaybackStarted() // Event fixture, not a visible playback measurement.
                waitFor("Playback event timing") { review().has("tapToPlayMs") }
                assertTrue(review().getDouble("tapToPlayMs") >= delay)
                host.releaseMedia()
                waitFor("Camera receipt") { snapshot(camera).getJSONObject("transfer").optString("state") == "complete" }
            }
            val matchQueued = CountDownLatch(1); var matchError: Exception? = null
            val matchTap = android.os.SystemClock.elapsedRealtimeNanos() / 1000.0
            host.requestMatchReview { matchError = it; matchQueued.countDown() }
            assertTrue("Fresh calibration should be reused promptly", matchQueued.await(2, TimeUnit.SECONDS)); assertNull(matchError)
            assertTrue(kotlin.math.abs(review().getDouble("tapUs") - matchTap) < 100_000)
            waitFor("Automatic Match review ready") { review().optString("state") == "ready" }
            waitFor("Automatic Match receipt") { snapshot(camera).getJSONObject("transfer").optString("state") == "complete" }
            unavailable = true; calibrate(); request()
            waitFor("Unavailable window fails") { review().optString("state") == "failed" }
            val unavailableDone = CountDownLatch(1)
            host.acquireReview { file, metadata -> assertNotNull(file); assertNotNull(metadata); unavailableDone.countDown() }
            assertTrue(unavailableDone.await(3, TimeUnit.SECONDS))
            host.releaseMedia()
            assertEquals("failed", review().optString("state"))
            unavailable = false; corrupt = true; calibrate(); request()
            waitFor("Hash-valid invalid media never ready") { review().optString("state") == "failed" && !snapshot(host).optBoolean("authenticated") }
            assertFalse(snapshot(host).getJSONObject("transfer").getBoolean("checksumVerified"))
            val fallback = CountDownLatch(1)
            host.acquireReview { file, metadata -> assertNotNull(file); assertNotNull(metadata); RecordingFrame.inspect(file!!, 0); fallback.countDown() }
            assertTrue(fallback.await(5, TimeUnit.SECONDS)); host.releaseMedia()
            val cleaned = CountDownLatch(1)
            host.cleanupTransfer { assertNull(it); cleaned.countDown() }
            assertTrue(cleaned.await(3, TimeUnit.SECONDS))
            assertFalse(snapshot(host).optBoolean("hasPlayableReview"))
            viewers[1].fetchPublished { assertNull(it) }
            waitFor("Missing new replay explicit") { snapshot(viewers[1]).optJSONObject("review")?.optString("state") == "failed" }
            assertTrue("Viewer keeps previously downloaded replay", snapshot(viewers[1]).optBoolean("hasPlayableReview"))
            camera.stop(); waitFor("Camera stopped") { snapshot(camera).optString("state") == "stopped" }
            camera.connect(address, secret, port)
            waitFor("Reconnect for End") { snapshot(host).optBoolean("authenticated") && snapshot(camera).optBoolean("authenticated") }
            camera.onEndMatch = { done -> done(null) }
            val ended = CountDownLatch(1); var acknowledged = false
            host.endPeerMatch { acknowledged = it; ended.countDown() }
            assertTrue(ended.await(10, TimeUnit.SECONDS)); assertTrue(acknowledged)
            waitFor("Peer stopped after acknowledgement") { snapshot(camera).optString("state") == "stopped" }
        } finally { source.delete(); viewers.forEach { it.destroy() }; host.destroy(); camera.destroy() }
    }
}
