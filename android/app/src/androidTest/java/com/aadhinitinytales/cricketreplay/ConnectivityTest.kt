package com.aadhinitinytales.cricketreplay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
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

@RunWith(AndroidJUnit4::class)
class ConnectivityTest {
    @Test fun swiftProtocolFixtures() {
        // Public deterministic TEST secret, never a real pairing credential.
        val text = InstrumentationRegistry.getInstrumentation().context.assets.open("swift-protocol-v2.json").bufferedReader().use { it.readText() }
        val fixtures = JSONArray(text)
        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(index)
            val auth = SessionAuthentication(fixture.getString("secret"), fixture.getString("role"), fixture.getString("nonce"))
            assertTrue(auth.acceptHello(fixture.getJSONObject("hello")))
            assertFalse(auth.acceptHello(fixture.getJSONObject("hello")))
            val frames = fixture.getJSONArray("frames")
            for (frameIndex in 0 until frames.length()) {
                val frame = frames.getJSONObject(frameIndex)
                val tampered = JSONObject(frame.toString()).put("payload", "changed")
                assertFalse(auth.verify(tampered))
                assertTrue("Actual Swift HMAC verifies on Android", auth.verify(frame))
                assertFalse("Replay rejected", auth.verify(frame))
            }
            val expectedOutgoing = fixtures.getJSONObject(1 - index).getJSONArray("frames")
            for (frameIndex in 0 until expectedOutgoing.length()) {
                val expected = expectedOutgoing.getJSONObject(frameIndex)
                val actual = auth.signed(expected.getString("type"), expected.getString("id"), expected.optString("payload", ""))
                assertEquals("Android-generated HMAC matches actual Swift output", expected.getString("mac"), actual.getString("mac"))
            }
            assertFalse("Reflection rejected", auth.verify(auth.signed("ping")))
        }
    }
    @Test fun pairingValidation() {
        val code = PairingCode("192.168.1.10", 8765, PairingCode.newSecret())
        assertEquals(code, PairingCode.decode(code.json().toString()))
        assertNull(PairingCode.decode("https://example.com"))
        assertNull(PairingCode.decode(code.json().put("version", 2).toString()))
        assertNull(PairingCode.decode(code.json().put("port", 70000).toString()))
        assertNull(PairingCode.decode(code.json().put("port", 8765.5).toString()))
        assertNull(PairingCode.decode(code.json().put("secret", "short").toString()))
        listOf("8.8.8.8", "127.0.0.1", "010.0.0.1", "192.168.1.10.extra", "192.168.1.256", "１９２.168.1.1").forEach { assertFalse(PairingCode.validAddress(it)) }
    }
    private fun snapshot(session: LocalSession): JSONObject {
        val done = CountDownLatch(1); var result = JSONObject()
        session.status { result = it; done.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS)); return result
    }
    private fun waitFor(detail: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
        while (System.nanoTime() < deadline) { if (condition()) return; Thread.sleep(20) }
        fail(detail)
    }
    @Test fun onDeviceConnectionRetryAndWrongSecret() {
        // Runs both native endpoints on this phone's Wi-Fi address. Not two-phone evidence.
        val address = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && it.name.startsWith("wlan") }
            .flatMap { it.inetAddresses.toList().filterIsInstance<Inet4Address>() }
            .mapNotNull { it.hostAddress }.firstOrNull(PairingCode::validAddress)
        assertNotNull("Join Wi-Fi before this on-device test", address)
        val host = LocalSession({ listOf("wlan0: $address") }, {}, File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "connect-test-${UUID.randomUUID()}"))
        val camera = LocalSession({ listOf("wlan0: $address") }, {}, File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "connect-test-${UUID.randomUUID()}"))
        val port = ServerSocket(0).use { it.localPort }
        val secret = PairingCode.newSecret()
        try {
            val started = CountDownLatch(1); var startError: Exception? = null
            host.startHost(secret, port) { startError = it; started.countDown() }
            assertTrue(started.await(2, TimeUnit.SECONDS)); assertNull(startError)
            camera.connect(address!!, secret, port)
            waitFor("Mutual authentication") { snapshot(host).optBoolean("authenticated") && snapshot(camera).optBoolean("authenticated") }
            host.ping(false) { assertTrue(it) }; camera.ping(true) { assertTrue(it) }
            waitFor("Bidirectional ping/status") { snapshot(host).optInt("repliesReceived") == 1 && snapshot(camera).optInt("repliesReceived") == 1 }
            assertTrue(snapshot(host).getDouble("lastRoundTripMs") >= 0)
            val source = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "transfer-test-${UUID.randomUUID()}")
            val bytes = ByteArray(100_000) { (it % 251).toByte() }; source.writeBytes(bytes)
            fun transfer(peer: LocalSession) = snapshot(peer).getJSONObject("transfer")
            fun send(slow: Boolean = false) {
                val done = CountDownLatch(1); var sendError: Exception? = null
                camera.sendSample(source, slow) { sendError = it; done.countDown() }
                assertTrue(done.await(2, TimeUnit.SECONDS)); assertNull(sendError)
            }
            fun checkCompleted() {
                val done = CountDownLatch(1); var received: File? = null
                host.completedSample { received = it; done.countDown() }
                assertTrue(done.await(2, TimeUnit.SECONDS)); assertNotNull(received)
                assertArrayEquals(bytes, received!!.readBytes())
            }
            try {
                for (attempt in 1..3) {
                    send()
                    waitFor("Encrypted transfer completes") { transfer(host).optString("state") == "ready" && transfer(camera).optString("state") == "complete" }
                    assertTrue(transfer(host).getBoolean("checksumVerified"))
                    assertEquals(attempt, transfer(host).getJSONArray("attempts").length())
                    assertTrue(transfer(host).getDouble("durationSeconds") > 0)
                    assertTrue(transfer(host).getDouble("throughputMBps") > 0); checkCompleted()
                }
                send(true)
                waitFor("Partial receiving") { transfer(host).optString("state") == "receiving" }
                camera.stop()
                waitFor("Interrupted transfer never ready") { transfer(host).optString("state") == "failed" }
                assertFalse(transfer(host).getBoolean("checksumVerified"))
                val done = CountDownLatch(1); var received: File? = null
                host.completedSample { received = it; done.countDown() }
                assertTrue(done.await(2, TimeUnit.SECONDS)); assertNull(received)
                camera.connect(address, secret, port)
                waitFor("Reconnect after interrupted transfer") { snapshot(host).optBoolean("authenticated") && snapshot(camera).optBoolean("authenticated") }
                send()
                waitFor("Retry completes") { transfer(host).optString("state") == "ready" && transfer(camera).optString("state") == "complete" }
                checkCompleted()
                val cleaned = CountDownLatch(1)
                host.cleanupTransfer { assertNull(it); cleaned.countDown() }
                assertTrue(cleaned.await(2, TimeUnit.SECONDS)); assertEquals("idle", transfer(host).getString("state"))
            } finally { source.delete() }
            camera.stop()
            waitFor("Host permits reconnect") { snapshot(host).optString("state") == "listening" && !snapshot(host).optBoolean("authenticated") }
            camera.connect(address, secret, port)
            waitFor("Reconnect") { snapshot(host).optBoolean("authenticated") && snapshot(camera).optBoolean("authenticated") }
            camera.stop()
            waitFor("Disconnected") { !snapshot(host).optBoolean("authenticated") }
            camera.connect(address, PairingCode.newSecret(), port)
            waitFor("Wrong secret rejected") { snapshot(camera).optString("state") == "failed" }
            assertFalse(snapshot(host).optBoolean("authenticated"))
            host.stop("Background simulation")
            waitFor("Stop clears listener/authentication") { snapshot(host).optString("state") == "stopped" && !snapshot(host).optBoolean("authenticated") }
        } finally { host.destroy(); camera.destroy() }
    }
}
