package com.aadhinitinytales.cricketreplay

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.widget.VideoView
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import org.hamcrest.Matchers.not
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class ReplayPlayerTest {
    @Test fun rotationKeepsPausedReplayCenteredAndCloseReleasesOnce() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = SampleVideo.generate(instrumentation.targetContext.cacheDir)
        val ready = CountDownLatch(1); val releases = AtomicInteger(); var error: String? = null
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        var player: SamplePlayer? = null
        try {
            scenario.onActivity { player = SamplePlayer(it, file, { result -> error = result; ready.countDown() }, { releases.incrementAndGet() }) }
            assertTrue("MP4 prepared", ready.await(20, TimeUnit.SECONDS)); assertNull(error)
            Thread.sleep(800)
            onView(isAssignableFrom(VideoView::class.java)).check { view, failure ->
                if (failure != null) throw failure
                val stage = view.parent as android.view.View
                val root = stage.parent as android.view.ViewGroup
                if (root.getChildAt(1).visibility != android.view.View.VISIBLE) stage.performClick()
            }
            onView(withText("Pause")).perform(click())
            onView(isAssignableFrom(VideoView::class.java)).check { view, failure ->
                if (failure != null) throw failure
                (view as VideoView).seekTo(5000)
            }
            Thread.sleep(500)
            for ((rotation, orientation) in listOf(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE to Configuration.ORIENTATION_LANDSCAPE, ActivityInfo.SCREEN_ORIENTATION_PORTRAIT to Configuration.ORIENTATION_PORTRAIT)) {
                scenario.onActivity { it.requestedOrientation = rotation }
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (instrumentation.targetContext.resources.configuration.orientation != orientation && System.nanoTime() < deadline) Thread.sleep(50)
                assertEquals(orientation, instrumentation.targetContext.resources.configuration.orientation)
                instrumentation.waitForIdleSync()
                onView(isAssignableFrom(VideoView::class.java)).check { view, failure ->
                    if (failure != null) throw failure
                    val stage = view.parent as android.view.View
                    val root = stage.parent as android.view.ViewGroup
                    if (root.getChildAt(1).visibility != android.view.View.VISIBLE) stage.performClick()
                }
                onView(withText("Close")).check(matches(isDisplayed()))
                onView(withText("Play")).check(matches(isDisplayed()))
                onView(isAssignableFrom(VideoView::class.java)).check { view, failure ->
                    if (failure != null) throw failure
                    val video = view as VideoView; val parent = video.parent as android.view.View
                    assertFalse("Rotation preserves pause", video.isPlaying)
                    assertTrue("Rotation preserves seek", video.currentPosition >= 4500)
                    assertEquals("Centered horizontally", parent.width / 2f, video.left + video.width / 2f, 1f)
                    assertEquals("Centered vertically", parent.height / 2f, video.top + video.height / 2f, 1f)
                }
            }
            // Home suspends the decoder without closing the review or releasing its file.
            scenario.onActivity { player!!.background() }
            scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            assertEquals("Background retains review lease", 0, releases.get())
            scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            scenario.onActivity { player!!.foreground() }
            Thread.sleep(1000)
            onView(isAssignableFrom(VideoView::class.java)).check { view, failure ->
                if (failure != null) throw failure
                val video = view as VideoView
                assertFalse("Home preserves pause", video.isPlaying)
                assertTrue("Home preserves seek", video.currentPosition >= 4500)
            }
            Thread.sleep(3800)
            onView(withText("Close")).check(matches(not(isDisplayed())))
            onView(isAssignableFrom(VideoView::class.java)).perform(click())
            onView(withText("Close")).check(matches(isDisplayed()))
            onView(withText("Fill")).perform(click()); onView(withText("Fit")).check(matches(isDisplayed()))
            onView(withText("Fit")).perform(click())
            onView(withText("Close")).perform(click())
            assertEquals("Close releases media once", 1, releases.get())
            scenario.onActivity { assertEquals("Main returns to portrait", ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, it.requestedOrientation) }
        } finally {
            scenario.onActivity { player?.dismiss(); it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            scenario.close(); file.delete()
        }
    }
}
