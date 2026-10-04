package com.aadhinitinytales.cricketreplay

import android.media.MediaMetadataRetriever
import androidx.test.core.app.ActivityScenario
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

@RunWith(AndroidJUnit4::class)
class TransferTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun cryptoKitEncryptedFixturesAndTamperRejection() {
        val fixtures = JSONArray(InstrumentationRegistry.getInstrumentation().context.assets.open("swift-transfer-v2.json").bufferedReader().use { it.readText() })
        val outgoing = JSONArray()
        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(index)
            val auth = SessionAuthentication(fixture.getString("secret"), fixture.getString("role"), fixture.getString("nonce"))
            assertTrue(auth.acceptHello(fixture.getJSONObject("hello")))
            val id = fixture.getString("id"); val encoded = fixture.getString("encrypted")
            val decoded = auth.decrypt(encoded, id)
            assertEquals("chunk", decoded.getString("kind")); assertEquals(128, decoded.getInt("offset"))
            assertEquals(fixture.getJSONObject("packet").getString("data"), decoded.getString("data"))
            try { auth.decrypt(encoded, UUID.randomUUID().toString()); fail("Changed request ID accepted") } catch (_: Exception) {}
            val corrupted = Base64.decode(encoded, Base64.DEFAULT); corrupted[corrupted.lastIndex] = (corrupted.last().toInt() xor 1).toByte()
            try { auth.decrypt(Base64.encodeToString(corrupted, Base64.NO_WRAP), id); fail("Corrupted ciphertext accepted") } catch (_: Exception) {}
            val fresh = SessionAuthentication(fixture.getString("secret"), fixture.getString("role"))
            assertTrue(fresh.acceptHello(fixture.getJSONObject("hello")))
            try { fresh.decrypt(encoded, id); fail("Cross-session ciphertext accepted") } catch (_: Exception) {}
            val host = SessionAuthentication(fixture.getString("secret"), "host")
            val camera = SessionAuthentication(fixture.getString("secret"), "camera")
            assertTrue(host.acceptHello(camera.hello())); assertTrue(camera.acceptHello(host.hello()))
            assertEquals(128, host.decrypt(camera.encrypt(decoded, id), id).getInt("offset"))
            assertEquals(128, camera.decrypt(host.encrypt(decoded, id), id).getInt("offset"))
            // Export only public fixture-based ciphertext for independent CryptoKit verification.
            outgoing.put(JSONObject(fixture.toString()).put("androidEncrypted", auth.encrypt(decoded, id)))
        }
        File(context.cacheDir, "android-transfer-test-output.json").writeText(outgoing.toString())
    }
    @Test fun corruptedPartialFilesNeverBecomePlayable() {
        val queue = Executors.newSingleThreadScheduledExecutor()
        val directory = File(context.cacheDir, "transfer-engine-test-${UUID.randomUUID()}")
        val receiver = SampleTransfer(queue, directory)
        try { queue.submit {
            val id = UUID.randomUUID().toString()
            fun offer() = receiver.receive(id, JSONObject().put("kind", "offer").put("bytes", 3).put("sha256", "0".repeat(64)), true)
            offer()
            receiver.receive(id, JSONObject().put("kind", "chunk").put("offset", 0).put("data", "AQID"), true)
            assertEquals(3, receiver.state.getInt("bytes")); assertFalse(receiver.state.getBoolean("checksumVerified")); assertNull(receiver.completed)
            receiver.receive(id, JSONObject().put("kind", "end"), true)
            assertEquals("failed", receiver.state.getString("state")); assertNull(receiver.completed); assertTrue(directory.listFiles()!!.isEmpty())
            offer(); receiver.receive(id, JSONObject().put("kind", "chunk").put("offset", 1).put("data", "AQ=="), true)
            assertEquals("failed", receiver.state.getString("state")); assertTrue(directory.listFiles()!!.isEmpty())
            receiver.receive(id, JSONObject().put("kind", "offer").put("bytes", SampleTransfer.MAX_BYTES + 1).put("sha256", "0".repeat(64)), true)
            assertEquals("failed", receiver.state.getString("state"))
            receiver.cleanup(); assertFalse(directory.exists())
        }.get() } finally { queue.shutdownNow(); directory.deleteRecursively() }
    }
    @Test fun generatedSampleEncodesAndDecodesOnThisPhone() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            // Temporary window flag only; closes with the test Activity, no system-setting change.
            scenario.onActivity { it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
            val file = SampleVideo.generate(context.cacheDir)
            try {
                assertTrue(file.length() in 1..SampleTransfer.MAX_BYTES.toLong())
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(file.absolutePath)
                    val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
                    assertTrue("Approximately 20 seconds: $duration ms", duration in 19_950..20_050)
                    assertEquals("640", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH))
                    assertEquals("360", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT))
                    assertNotEquals("yes", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO))
                    val first = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST)!!
                    val later = retriever.getFrameAtTime(10_000_000, MediaMetadataRetriever.OPTION_CLOSEST)!!
                    assertFalse("Visible motion/progress", first.sameAs(later)); first.recycle(); later.recycle()
                } finally { retriever.release() }
                val prepared = CountDownLatch(1); var error: String? = null; var player: SamplePlayer? = null
                try {
                    scenario.onActivity { activity -> player = SamplePlayer(activity, file, { error = it; prepared.countDown() }, {}) }
                    assertTrue("Native VideoView prepares", prepared.await(20, TimeUnit.SECONDS)); assertNull(error)
                } finally { scenario.onActivity { player?.dismiss() } }
            } finally { file.delete() }
        }
    }
}
