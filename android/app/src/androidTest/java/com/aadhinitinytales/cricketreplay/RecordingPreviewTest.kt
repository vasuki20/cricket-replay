package com.aadhinitinytales.cricketreplay

import androidx.coordinatorlayout.widget.CoordinatorLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.getcapacitor.JSObject
import com.getcapacitor.PluginCall
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// No camera: exercise TextureView creation and real Capacitor parent layout/traversal.
@RunWith(AndroidJUnit4::class)
class RecordingPreviewTest {
    @Test fun previewSurvivesRealContainerLayoutAndHide() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var preview: RecordingPreview
            val ready = CountDownLatch(1)
            var failure: String? = null
            fun call(visible: Boolean, y: Double = 20.0) = object : PluginCall(null, "Feasibility", "test", "setRecordingPreview",
                JSObject().put("visible", visible).put("x", 10.0).put("y", y)
                    .put("width", 160.0).put("height", 90.0).put("viewportWidth", 360.0)) {
                override fun resolve() { ready.countDown() }
                override fun reject(message: String) { failure = message; ready.countDown() }
            }
            scenario.onActivity { activity ->
                val web = activity.bridge.webView
                assertTrue(web.parent is CoordinatorLayout)
                preview = RecordingPreview(activity, web)
                preview.layout(call(true))
            }
            try {
                assertTrue("Preview surface did not become available; unlock the phone", ready.await(5, TimeUnit.SECONDS))
                assertNull(failure)
                instrumentation.waitForIdleSync()
                scenario.onActivity { activity ->
                    val parent = activity.bridge.webView.parent as CoordinatorLayout
                    for (index in 0 until parent.childCount) {
                        assertTrue(parent.getChildAt(index).layoutParams is CoordinatorLayout.LayoutParams)
                    }
                    val surface = preview.output(); assertNotNull(surface)
                    preview.configure(640, 480, 180)
                    preview.layout(call(true, -40.0))
                    preview.layout(call(false))
                    assertSame("Hiding must retain the configured camera target", surface, preview.output())
                    preview.layout(call(true))
                    assertSame(surface, preview.output())
                }
                instrumentation.waitForIdleSync()
                assertNull(failure)
            } finally { scenario.onActivity { preview.destroy() } }
        }
    }
}
