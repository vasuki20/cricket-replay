package com.aadhinitinytales.cricketreplay

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.*
import android.media.*
import android.os.*
import android.util.Range
import android.util.Size
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

// One Camera2 repeating request and one encoder per run. Only muxers rotate at sync frames.
// All capture state, buffer mutations and codec callbacks belong to this Handler.
internal class RollingRecording(private val context: Context, private val captureEnded: () -> Unit = {}) {
    init { File(context.cacheDir, "cricket-review-outgoing").deleteRecursively() }
    companion object {
        const val SEGMENT_US = 5_000_000L
        const val MAX_DISK_BYTES = 256L * 1024 * 1024
        const val MAX_REPORT_BYTES = 16L * 1024 * 1024
    }
    private val thread = HandlerThread("replay-recording").apply { start() }
    private val handler = Handler(thread.looper)
    private val worker = Executors.newSingleThreadExecutor()
    val directory = File(context.noBackupFilesDir, "recording-experiment")
    private var config = RecordingConfig()
    private var buffer = RecordingBuffer(config)
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var extractionTiming = JSONObject()
    private var preview: Surface? = null // UI owns this surface; recorder never releases it.
    private var format: MediaFormat? = null
    private var muxer: MediaMuxer? = null
    private var segmentFile: File? = null
    private var segmentCsv: File? = null
    private var frameWriter: BufferedWriter? = null
    private var eventWriter: BufferedWriter? = null
    private var track = -1
    private var segmentFirst = -1L; private var segmentLast = -1L; private var segmentFrames = 0
    private var segmentPrecedingDelta = 0L
    private var firstPts = -1L; private var lastPts = -1L; private var encodedFrames = 0L
    private var firstSensor = -1L; private var lastSensor = -1L; private var sensorFrames = 0L
    private var maxEncodedDelta = 0L; private var encodedGaps = 0L
    private var maxSensorDelta = 0L; private var sensorGaps = 0L; private var captureFailures = 0L
    private var startedMs = 0L; private var stoppedMs = 0L; private var peakBytes = 0L; private var totalVideoBytes = 0L
    private var state = "idle"; private var detail = "No camera recording"
    private var rotation = 0; private var selection = JSONObject()
    private val segmentHistory = JSONArray()
    private val extractionHistory = JSONArray()
    private var extraction = JSONObject().put("state", "idle").put("ready", false)
    private var extracting = false
    private var pendingEnd: Long? = null
    private var pendingDone: ((Exception?) -> Unit)? = null
    private var startDone: ((Exception?) -> Unit)? = null
    private var stopDone: (() -> Unit)? = null
    private var generation = 0
    private var destroyed = false
    private var closed = false
    private var lastSyncRequest = -1L
    private var lastSampleWall = 0L
    private val clip get() = File(directory, "latest-clip.mp4")

    fun status(done: (JSONObject) -> Unit) { handler.post { done(snapshot()) } }
    fun report(done: (String) -> Unit) { handler.post {
        val saved = File(directory, "report.json")
        if (state == "idle" && saved.exists()) { done(saved.readText()); return@post }
        done(snapshot().put("segments", segmentHistory).put("extractions", extractionHistory)
            .put("startedEpochMs", epochMs).put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("os", Build.VERSION.RELEASE).toString(2))
    } }
    private fun snapshot(): JSONObject {
        val now = if (stoppedMs > 0) stoppedMs else SystemClock.elapsedRealtime()
        return JSONObject().put("state", state).put("detail", detail)
            .put("retentionSeconds", config.retentionSeconds).put("reviewSeconds", config.reviewSeconds)
            .put("elapsedSeconds", if (startedMs == 0L) 0.0 else (now - startedMs) / 1000.0)
            .put("selection", selection).put("encodedFrames", encodedFrames).put("sensorFrames", sensorFrames)
            .put("effectiveFps", if (lastPts > firstPts) (encodedFrames - 1) * 1_000_000.0 / (lastPts - firstPts) else 0.0)
            .put("sensorFps", if (lastSensor > firstSensor) (sensorFrames - 1) * 1_000_000_000.0 / (lastSensor - firstSensor) else 0.0)
            .put("maxFrameDeltaMs", maxEncodedDelta / 1000.0).put("intervalsOver50ms", encodedGaps)
            .put("maxSensorDeltaMs", maxSensorDelta / 1_000_000.0).put("sensorIntervalsOver50ms", sensorGaps)
            .put("captureFailures", captureFailures).put("firstPtsUs", firstPts).put("lastPtsUs", lastPts)
            .put("bufferedSeconds", if (firstPts < 0) 0.0 else (lastPts - (buffer.segments.firstOrNull()?.firstUs ?: segmentFirst)) / 1_000_000.0)
            .put("closedSegments", buffer.segments.size).put("pinnedSegments", buffer.segments.count { it.pins > 0 })
            .put("storageBytes", storageBytes()).put("peakStorageBytes", peakBytes).put("totalVideoBytesWritten", totalVideoBytes)
            .put("maxStorageBytes", MAX_DISK_BYTES).put("extraction", extraction)
    }
    private fun storageBytes() = directory.listFiles()?.sumOf { it.length() } ?: 0L
    private fun log(kind: String, timestamp: Long, value: String) {
        eventWriter?.write("$kind,$timestamp,$value\n")
    }
    private fun saveReport() {
        eventWriter?.flush(); frameWriter?.flush()
        val report = snapshot().put("segments", segmentHistory).put("extractions", extractionHistory)
            .put("startedEpochMs", epochMs).put("device", "${Build.MANUFACTURER} ${Build.MODEL}").put("os", Build.VERSION.RELEASE)
            .put("heatObservation", "Requires user observation; no surface temperature measurement")
        val temporary = File(directory, "report.tmp")
        temporary.writeText(report.toString(2))
        check(temporary.renameTo(File(directory, "report.json"))) { "Cannot save recording report" }
    }
    private var epochMs = 0L

    fun start(options: RecordingConfig, displayRotation: Int, previewSurface: Surface? = null,
              configurePreview: ((Int, Int, Int, Int) -> Unit)? = null, done: (Exception?) -> Unit) { handler.post {
        if (state in listOf("starting", "recording", "stopping") || extracting) { done(IllegalStateException("Stop recording and finish extraction first")); return@post }
        try {
            check(!destroyed) { "Recording engine closed" }
            eventWriter?.close(); eventWriter = null
            check(!directory.exists() || directory.deleteRecursively()) { "Cannot clear previous recording experiment" }
            check(directory.mkdirs()) { "Cannot create recording directory" }
            config = options; buffer = RecordingBuffer(config); generation++
            firstPts = -1; lastPts = -1; encodedFrames = 0; firstSensor = -1; lastSensor = -1; sensorFrames = 0
            maxEncodedDelta = 0; encodedGaps = 0; maxSensorDelta = 0; sensorGaps = 0; captureFailures = 0
            peakBytes = 0; totalVideoBytes = 0; stoppedMs = 0; lastSyncRequest = -1; pendingEnd = null
            while (segmentHistory.length() > 0) segmentHistory.remove(0)
            while (extractionHistory.length() > 0) extractionHistory.remove(0)
            extraction = JSONObject().put("state", "idle").put("ready", false)
            startedMs = SystemClock.elapsedRealtime(); epochMs = System.currentTimeMillis(); lastSampleWall = startedMs
            state = "starting"; detail = "Opening rear camera; no audio"; startDone = done
            eventWriter = File(directory, "capture-events.csv").bufferedWriter().apply { write("kind,timestamp,value\n") }
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
                ?: error("No rear camera")
            val chars = manager.getCameraCharacteristics(id)
            val map = checkNotNull(chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP))
            val ranges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.toList().orEmpty()
            val sizes = map.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
            val candidates = listOf(Size(1280, 720), Size(640, 480))
            var selected: Triple<Size, Range<Int>, String>? = null
            for (size in candidates) {
                if (size !in sizes) continue
                val minimum = map.getOutputMinFrameDuration(MediaCodec::class.java, size)
                val range = ranges.filter { it.upper <= 30 && it.upper >= 15 && (minimum == 0L || minimum <= 1_000_000_000L / it.upper + 1_000_000) }
                    .sortedWith(compareByDescending<Range<Int>> { it.upper }.thenByDescending { it.lower }).firstOrNull() ?: continue
                val inputFormat = encoderFormat(size, range.upper)
                val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(inputFormat) ?: continue
                val caps = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.first { it.name == name }.getCapabilitiesForType("video/avc")
                if (caps.videoCapabilities?.areSizeAndRateSupported(size.width, size.height, range.upper.toDouble()) != true) continue
                selected = Triple(size, range, name); break
            }
            val (size, range, encoder) = selected ?: error("No supported rear-camera/AVC combination at 720p or 640×480, 15–30 fps")
            val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            rotation = (sensorOrientation - displayRotation + 360) % 360
            preview = previewSurface
            if (preview != null) {
                val previewSizes = map.getOutputSizes(android.graphics.SurfaceTexture::class.java)?.toList().orEmpty()
                val previewSize = previewSizes.firstOrNull { it == size }
                    ?: previewSizes.filter { it.width <= 1280 && it.height <= 720 }
                        .sortedByDescending { it.width * it.height }.firstOrNull()
                    ?: error("No supported camera preview size")
                configurePreview?.invoke(previewSize.width, previewSize.height, sensorOrientation, displayRotation)
            }
            selection = JSONObject().put("camera", "rear").put("width", size.width).put("height", size.height)
                .put("requestedFps", range.upper).put("aeRange", "${range.lower}–${range.upper}").put("encoder", encoder)
                .put("rotationDegrees", rotation).put("sensorTimestampSource", chars.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE))
                .put("supportedSizes", JSONArray(sizes.map { "${it.width}×${it.height}" }))
                .put("supportedFpsRanges", JSONArray(ranges.map { "${it.lower}–${it.upper}" }))
                .put("fallback", if (size == candidates.first() && range.lower == 30 && range.upper == 30) "None; actual fps still measured" else "Capability fallback; actual fps measured, AE may vary")
            val run = generation
            codec = MediaCodec.createByCodecName(encoder).apply {
                setCallback(object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}
                    override fun onOutputFormatChanged(codec: MediaCodec, output: MediaFormat) {
                        if (run != generation) return
                        try {
                            check(format == null) { "Encoder changed format during recording" }
                            format = output
                            selection.put("encodedWidth", output.getInteger(MediaFormat.KEY_WIDTH)).put("encodedHeight", output.getInteger(MediaFormat.KEY_HEIGHT))
                        } catch (error: Exception) { fail(error.message ?: "Invalid encoder format") }
                    }
                    override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) { if (run == generation) fail("Encoder: ${error.message}") }
                    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                        if (run != generation) return
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                val bytes = checkNotNull(codec.getOutputBuffer(index))
                                writeFrame(bytes, info)
                            }
                            codec.releaseOutputBuffer(index, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) finishStop()
                        } catch (error: Exception) { fail(error.message ?: "Cannot write camera frame") }
                    }
                }, handler)
                configure(encoderFormat(size, range.upper), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                surface = createInputSurface(); start()
            }
            openCamera(manager, id, run, range)
            handler.postDelayed({ if (run == generation && state == "starting") fail("Camera startup timed out") }, 15_000)
            handler.postDelayed(object : Runnable {
                override fun run() {
                    if (run != generation || state !in listOf("starting", "recording")) return
                    try {
                        check(SystemClock.elapsedRealtime() - lastSampleWall < 10_000) { "No encoded frames for ten seconds" }
                        check(File(directory, "capture-events.csv").length() < MAX_REPORT_BYTES) { "Timestamp evidence reached its 16 MiB bound; stop and save results" }
                        val bytes = storageBytes(); peakBytes = maxOf(peakBytes, bytes)
                        check(bytes < MAX_DISK_BYTES && directory.usableSpace > 64L * 1024 * 1024) { "Recording storage limit or low disk space; capture stopped" }
                        if (Build.VERSION.SDK_INT >= 29) log("thermal", SystemClock.elapsedRealtime(), (context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus.toString())
                        saveReport(); handler.postDelayed(this, 1000)
                    } catch (error: Exception) { fail(error.message ?: "Recording watchdog failed") }
                }
            }, 1000)
        } catch (error: Exception) { fail(error.message ?: "Cannot start recording", error) }
    } }
    private fun encoderFormat(size: Size, fps: Int) = MediaFormat.createVideoFormat("video/avc", size.width, size.height).apply {
        setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        setInteger(MediaFormat.KEY_BIT_RATE, 4_000_000); setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
        if (Build.VERSION.SDK_INT >= 29) setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
    }
    @SuppressLint("MissingPermission")
    private fun openCamera(manager: CameraManager, id: String, run: Int, range: Range<Int>) {
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                if (run != generation || state != "starting") { device.close(); return }
                camera = device
                try {
                    device.createCaptureSession(listOfNotNull(checkNotNull(surface), preview), object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(capture: CameraCaptureSession) {
                            if (run != generation || state != "starting") { capture.close(); return }
                            session = capture
                            try {
                                val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                    addTarget(checkNotNull(surface)); set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
                                    preview?.let { addTarget(it) }
                                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                                }.build()
                                capture.setRepeatingRequest(request, object : CameraCaptureSession.CaptureCallback() {
                                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                                        if (run != generation) return
                                        try {
                                            val time = result.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
                                            if (firstSensor < 0) firstSensor = time
                                            val delta = if (lastSensor < 0) 0 else time - lastSensor
                                            maxSensorDelta = maxOf(maxSensorDelta, delta); if (delta > 50_000_000) sensorGaps++
                                            lastSensor = time; sensorFrames++; log("sensor", time, "$delta")
                                        } catch (error: Exception) { fail(error.message ?: "Cannot record sensor timestamp") }
                                    }
                                    override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
                                        if (run == generation) {
                                            try { captureFailures++; log("captureFailure", SystemClock.elapsedRealtime(), failure.reason.toString()) }
                                            catch (error: Exception) { fail(error.message ?: "Cannot record capture failure") }
                                        }
                                    }
                                }, handler)
                                // Resolve only on the first encoded sample, not merely camera configuration.
                            } catch (error: Exception) { fail(error.message ?: "Cannot start repeating camera request") }
                        }
                        override fun onConfigureFailed(capture: CameraCaptureSession) { capture.close(); if (run == generation) fail("Camera session configuration failed") }
                    }, handler)
                } catch (error: Exception) { fail(error.message ?: "Cannot configure camera") }
            }
            override fun onDisconnected(device: CameraDevice) { device.close(); if (run == generation) fail("Rear camera disconnected") }
            override fun onError(device: CameraDevice, error: Int) { device.close(); if (run == generation) fail("Rear camera error $error") }
        }, handler)
    }
    private fun requestSync() { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }); lastSyncRequest = lastPts }
    private fun writeFrame(bytes: ByteBuffer, info: MediaCodec.BufferInfo) {
        val pts = info.presentationTimeUs
        check(lastPts < 0 || pts > lastPts) { "Non-monotonic encoder timestamps; capture stopped" }
        val sync = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        if (muxer == null && !sync) return // Never create a non-decodable initial segment.
        if (muxer != null && sync && (pts - segmentFirst >= SEGMENT_US || pendingEnd != null)) {
            closeSegment()
            pendingEnd?.let { end -> launchExtraction(end) }
        }
        if (muxer == null) {
            val file = File(directory, "segment-$pts.mp4"); segmentFile = file
            segmentCsv = File(directory, "segment-$pts.csv")
            frameWriter = checkNotNull(segmentCsv).bufferedWriter().apply { write("ptsUs,deltaUs,keyframe\n") }
            muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).apply {
                setOrientationHint(rotation); track = addTrack(checkNotNull(format)); start()
            }
            segmentFirst = pts; segmentLast = pts; segmentFrames = 0
            segmentPrecedingDelta = if (lastPts < 0) 0 else pts - lastPts
        }
        if (firstPts < 0) firstPts = pts
        val delta = if (lastPts < 0) 0 else pts - lastPts
        maxEncodedDelta = maxOf(maxEncodedDelta, delta); if (delta > 50_000) encodedGaps++
        val localInfo = MediaCodec.BufferInfo().apply { set(info.offset, info.size, pts - segmentFirst, info.flags) }
        checkNotNull(muxer).writeSampleData(track, bytes, localInfo)
        frameWriter?.write("$pts,$delta,${if (sync) 1 else 0}\n"); log("encoded", pts, "$delta")
        totalVideoBytes += info.size; segmentLast = pts; segmentFrames++; lastPts = pts; encodedFrames++
        lastSampleWall = SystemClock.elapsedRealtime()
        buffer.evict(pts)
        if (state == "starting") { state = "recording"; detail = "Continuous rear-camera capture; keep landscape and foreground"; startDone?.invoke(null); startDone = null }
        if (pts - segmentFirst >= SEGMENT_US && (lastSyncRequest < 0 || pts - lastSyncRequest >= 1_000_000)) requestSync()
        check(pts - segmentFirst < 10_000_000) { "No segment keyframe within ten seconds" }
    }
    private fun closeSegment() {
        val output = muxer ?: return
        muxer = null
        try { output.stop() } finally { output.release(); frameWriter?.close(); frameWriter = null }
        val segment = RecordingSegment(checkNotNull(segmentFile), checkNotNull(segmentCsv), segmentFirst, segmentLast, segmentFrames, rotation)
        buffer.segments.add(segment)
        val row = JSONObject().put("file", segment.file.name).put("firstPtsUs", segmentFirst).put("lastPtsUs", segmentLast)
            .put("frames", segmentFrames).put("bytes", segment.file.length()).put("precedingIntervalUs", segmentPrecedingDelta)
        segmentHistory.put(row); if (segmentHistory.length() > 1000) segmentHistory.remove(0)
        log("segment", segmentFirst, "$segmentLast:${segmentFrames}")
        segmentFile = null; segmentCsv = null
    }

    fun extract(endpointHostUs: Long? = null, done: (Exception?) -> Unit) { handler.post {
        if (state != "recording" || extracting || pendingEnd != null) { done(IllegalStateException("Record first; only one extraction may run")); return@post }
        if (lastPts - firstPts < config.reviewSeconds * 1_000_000L) { done(IllegalStateException("Wait for ${config.reviewSeconds} seconds of footage")); return@post }
        if (endpointHostUs != null && selection.optInt("sensorTimestampSource", -1) != CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME) {
            done(IllegalStateException("Remote review requires a sensor timestamp source tied to elapsed realtime")); return@post
        }
        val target = endpointHostUs ?: lastPts
        val endpoint = minOf(target, lastPts)
        if (endpoint - firstPts < config.reviewSeconds * 1_000_000L) { done(IllegalStateException("Requested window is not available")); return@post }
        extractionTiming = JSONObject()
        if (endpointHostUs != null) extractionTiming.put("requestedHostUs", endpointHostUs).put("requestedSourceUs", target)
        pendingEnd = endpoint; pendingDone = done; extracting = true
        extraction = JSONObject().put("state", "sealing").put("ready", false).put("detail", "Waiting for next keyframe; capture continues")
        if (buffer.segments.any { it.lastUs >= endpoint }) launchExtraction(endpoint)
        else try { requestSync() } catch (error: Exception) { extractionFailed(error) }
        val end = pendingEnd
        handler.postDelayed({ if (pendingEnd != null && pendingEnd == end) extractionFailed(IllegalStateException("Extraction keyframe timed out; capture continues")) }, 5000)
    } }
    private fun launchExtraction(end: Long) {
        pendingEnd = null
        var pinned: List<RecordingSegment>? = null
        try {
            val selected = buffer.pin(end)
            pinned = selected
            extraction = JSONObject().put("state", "extracting").put("ready", false).put("detail", "Pinned input files; capture continues")
            worker.execute {
                var result: JSONObject? = null; var error: Exception? = null
                try { check(!clip.exists() || clip.delete()); result = RecordingClip.extract(selected, end, config.reviewSeconds, clip) }
                catch (failure: Exception) { error = failure }
                handler.post {
                    buffer.release(selected); extracting = false
                    if (error == null) {
                        extractionTiming.keys().forEach { key -> result?.put(key, extractionTiming.get(key)) }
                        if (extractionTiming.has("requestedSourceUs")) result?.put("endpointErrorUs", result!!.getLong("sourceLastUs") - extractionTiming.getLong("requestedSourceUs"))
                        if (extractionTiming.has("requestedSourceUs")) {
                            result!!.put("retentionSeconds", config.retentionSeconds).put("reviewSeconds", config.reviewSeconds)
                            try { SampleTransfer.recordingMetadata(result!!) }
                            catch (failure: Exception) { extractionFailed(failure); return@post }
                        }
                        extraction = checkNotNull(result).put("state", "ready").put("detail", "Clip ready; beginning/middle/end frames decoded")
                        extractionHistory.put(JSONObject(extraction.toString())); if (extractionHistory.length() > 100) extractionHistory.remove(0)
                        pendingDone?.invoke(null); pendingDone = null
                    } else extractionFailed(checkNotNull(error))
                    try { buffer.evict(lastPts); saveReport() } catch (failure: Exception) { fail(failure.message ?: "Cannot update extraction evidence") }
                    if (destroyed && state !in listOf("starting", "recording", "stopping")) shutdown()
                }
            }
        } catch (error: Exception) { pinned?.let { buffer.release(it) }; extractionFailed(error) }
    }
    private fun extractionFailed(error: Exception) {
        pendingEnd = null; extracting = false
        extraction = JSONObject().put("state", "failed").put("ready", false).put("detail", error.message ?: "Extraction failed")
        extractionHistory.put(JSONObject(extraction.toString())); if (extractionHistory.length() > 100) extractionHistory.remove(0)
        pendingDone?.invoke(error); pendingDone = null
    }
    fun exportReview(done: (File?, JSONObject?, Exception?) -> Unit) { handler.post {
        var copy: File? = null
        try {
            check(!extracting && extraction.optBoolean("ready")) { "No complete recording clip" }
            val metadata = SampleTransfer.recordingMetadata(JSONObject(extraction.toString()).put("retentionSeconds", config.retentionSeconds).put("reviewSeconds", config.reviewSeconds))
            val folder = File(context.cacheDir, "cricket-review-outgoing").apply { check(isDirectory || mkdirs()) }
            copy = File.createTempFile("review-", ".mp4", folder)
            clip.copyTo(copy, overwrite = true)
            done(copy, metadata, null)
        } catch (error: Exception) { copy?.delete(); done(null, null, error) }
    } }
    fun completedClip(done: (File?) -> Unit) { handler.post { done(if (!extracting && extraction.optBoolean("ready") && clip.exists()) clip else null) } }
    fun stop(reason: String = "Stopped by user", done: () -> Unit = {}) { handler.post {
        if (state !in listOf("starting", "recording")) { done(); return@post }
        state = "stopping"; detail = reason; stopDone = done
        if (pendingEnd != null) extractionFailed(IllegalStateException("Recording stopped before extraction sealed"))
        startDone?.invoke(IllegalStateException(reason)); startDone = null
        try {
            session?.stopRepeating(); session?.close(); session = null; camera?.close(); camera = null
            if (codec == null) { finishStop(); return@post }
            codec?.signalEndOfInputStream()
            val run = generation
            handler.postDelayed({ if (run == generation && state == "stopping") fail("Encoder stop timed out; last active segment may be incomplete") }, 5000)
        } catch (error: Exception) { fail(error.message ?: "Cannot stop recording") }
    } }
    private fun finishStop() {
        try { closeSegment(); releaseCapture(); state = "stopped"; stoppedMs = SystemClock.elapsedRealtime(); saveReport() }
        catch (error: Exception) { fail(error.message ?: "Cannot finalize recording") }
        captureEnded()
        stopDone?.invoke(); stopDone = null
        if (destroyed && !extracting) shutdown()
    }
    private fun releaseCapture() {
        generation++; runCatching { session?.close() }; session = null; runCatching { camera?.close() }; camera = null
        runCatching { codec?.stop() }; runCatching { codec?.release() }; codec = null
        surface?.release(); surface = null; preview = null; format = null
    }
    private fun fail(message: String, error: Exception = IllegalStateException(message)) {
        android.util.Log.e("RollingRecording", message)
        releaseCapture(); state = "failed"; detail = message; stoppedMs = SystemClock.elapsedRealtime()
        runCatching { closeSegment() }
        if (pendingEnd != null) extractionFailed(error)
        startDone?.invoke(error); startDone = null
        runCatching { saveReport() }; stopDone?.invoke(); stopDone = null
        captureEnded()
        if (destroyed && !extracting) shutdown()
    }
    fun cleanup(done: (Exception?) -> Unit) { handler.post {
        try {
            check(state !in listOf("starting", "recording", "stopping") && !extracting) { "Stop capture and finish extraction before cleanup" }
            eventWriter?.close(); eventWriter = null
            check(!directory.exists() || directory.deleteRecursively()) { "Cannot delete recording files" }
            buffer = RecordingBuffer(config); state = "idle"; detail = "Recording files removed"; startedMs = 0
            stoppedMs = 0; epochMs = 0; selection = JSONObject(); firstPts = -1; lastPts = -1
            firstSensor = -1; lastSensor = -1; sensorFrames = 0; encodedFrames = 0
            maxEncodedDelta = 0; maxSensorDelta = 0; encodedGaps = 0; sensorGaps = 0; captureFailures = 0
            peakBytes = 0; totalVideoBytes = 0
            while (segmentHistory.length() > 0) segmentHistory.remove(0)
            while (extractionHistory.length() > 0) extractionHistory.remove(0)
            extraction = JSONObject().put("state", "idle").put("ready", false); done(null)
        } catch (error: Exception) { done(error) }
    } }
    fun destroy() { handler.post {
        destroyed = true
        if (state in listOf("starting", "recording")) stop("App closed")
        else if (state != "stopping" && !extracting) shutdown()
    } }
    private fun shutdown() {
        if (closed) return
        closed = true; releaseCapture(); runCatching { eventWriter?.close() }; eventWriter = null; worker.shutdown(); thread.quitSafely()
    }
}
