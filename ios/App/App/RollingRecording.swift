import Foundation
import AVFoundation
import VideoToolbox

// One capture session and compression session per run; MP4 writers only wrap compressed samples.
final class RollingRecording: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let segmentUs: Int64 = 5_000_000
    static let maxDiskBytes = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "cricket.recording")
    private let worker = DispatchQueue(label: "cricket.recording-extract")
    let directory: URL
    var captureEnded: (() -> Void)?
    private var config = try! RecordingConfig()
    private var buffer = RecordingBuffer(config: try! RecordingConfig())
    private var capture: AVCaptureSession?
    private var encoderEpoch = 0
    private var extractionTiming: [String: Any] = [:]
    #if os(iOS)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    #endif
    private var device: AVCaptureDevice?
    private var compression: VTCompressionSession?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var active: RecordingSegment?
    private var events: FileHandle?
    private var framesCSV: FileHandle?
    private var state = "idle"; private var detail = "No camera recording"
    private var selection: [String: Any] = [:]
    private var extraction: [String: Any] = ["state": "idle", "ready": false]
    private var segmentHistory: [[String: Any]] = []; private var extractionHistory: [[String: Any]] = []
    private var firstPts: Int64 = -1; private var lastPts: Int64 = -1; private var encodedFrames = 0
    private var firstInput: Int64 = -1; private var lastInput: Int64 = -1; private var inputFrames = 0
    private var maxEncodedDelta: Int64 = 0; private var encodedGaps = 0
    private var maxInputDelta: Int64 = 0; private var inputGaps = 0
    private var droppedInput = 0; private var droppedEncoder = 0
    private var epochMs: Int64 = 0; private var started: Double = 0; private var stopped: Double = 0
    private var peakBytes = 0; private var totalVideoBytes = 0
    private var run = 0; private var inFlight = 0; private var finalizing = 0
    private var closingWriters: [String: AVAssetWriter] = [:]
    private var lastSampleWall: Double = 0
    private var pendingEnd: Int64?
    private var extracting = false
    private var extractDone: ((Error?) -> Void)?
    private var startDone: ((Error?) -> Void)?
    private var stopDone: [() -> Void] = []
    private var forceSync = false
    private var precedingInterval: Int64 = 0
    private var clip: URL { directory.appendingPathComponent("latest-clip.mp4") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recording-experiment", isDirectory: true)
        super.init()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("cricket-review-outgoing"))
    }
    func status(_ done: @escaping ([String: Any]) -> Void) { queue.async { done(self.snapshot()) } }
    func report(_ done: @escaping (Result<String, Error>) -> Void) { queue.async {
        do {
            let saved = self.directory.appendingPathComponent("report.json")
            if self.state == "idle", FileManager.default.fileExists(atPath: saved.path) {
                done(.success(try String(contentsOf: saved, encoding: .utf8))); return
            }
            done(.success(String(decoding: try JSONSerialization.data(withJSONObject: self.fullReport(), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)))
        } catch { done(.failure(error)) }
    } }
    private func diskBytes() -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func snapshot() -> [String: Any] {
        ["state": state, "detail": detail, "retentionSeconds": config.retentionSeconds, "reviewSeconds": config.reviewSeconds,
         "elapsedSeconds": started == 0 ? 0 : (stopped > 0 ? stopped : ProcessInfo.processInfo.systemUptime) - started,
         "selection": selection, "encodedFrames": encodedFrames, "sensorFrames": inputFrames,
         "effectiveFps": lastPts > firstPts ? Double(encodedFrames - 1) * 1_000_000 / Double(lastPts - firstPts) : 0,
         "sensorFps": lastInput > firstInput ? Double(inputFrames - 1) * 1_000_000 / Double(lastInput - firstInput) : 0,
         "maxFrameDeltaMs": Double(maxEncodedDelta) / 1000, "intervalsOver50ms": encodedGaps,
         "maxSensorDeltaMs": Double(maxInputDelta) / 1000, "sensorIntervalsOver50ms": inputGaps,
         "captureFailures": droppedInput + droppedEncoder, "droppedInputFrames": droppedInput, "droppedEncoderFrames": droppedEncoder,
         "firstPtsUs": firstPts, "lastPtsUs": lastPts,
         "bufferedSeconds": firstPts < 0 ? 0 : Double(lastPts - (buffer.segments.first?.firstUs ?? active?.firstUs ?? firstPts)) / 1_000_000,
         "closedSegments": buffer.segments.count, "pinnedSegments": buffer.segments.filter { $0.pins > 0 }.count,
         "storageBytes": diskBytes(), "peakStorageBytes": peakBytes, "totalVideoBytesWritten": totalVideoBytes,
         "maxStorageBytes": Self.maxDiskBytes, "extraction": extraction]
    }
    private func fullReport() -> [String: Any] {
        var report = snapshot(); report["segments"] = segmentHistory; report["extractions"] = extractionHistory
        report["startedEpochMs"] = epochMs; report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["heatObservation"] = "Requires user observation; thermal state is not a surface temperature"
        return report
    }
    private func saveReport() throws {
        try events?.synchronize(); try framesCSV?.synchronize()
        peakBytes = max(peakBytes, diskBytes())
        try JSONSerialization.data(withJSONObject: fullReport(), options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }
    private func log(_ kind: String, _ pts: Int64, _ value: String) throws {
        try events?.write(contentsOf: Data("\(kind),\(pts),\(value.replacingOccurrences(of: ",", with: ":"))\n".utf8))
    }
    private func prepare(_ options: RecordingConfig, done: @escaping (Error?) -> Void) throws {
        guard !["starting", "recording", "stopping"].contains(state), !extracting, finalizing == 0 else {
            throw RecordingError.invalid("Stop recording and finish extraction/finalization first")
        }
        try events?.close(); events = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        config = options; buffer = RecordingBuffer(config: options); run += 1
        firstPts = -1; lastPts = -1; firstInput = -1; lastInput = -1; encodedFrames = 0; inputFrames = 0
        maxEncodedDelta = 0; maxInputDelta = 0; encodedGaps = 0; inputGaps = 0; droppedInput = 0; droppedEncoder = 0
        peakBytes = 0; totalVideoBytes = 0; inFlight = 0; finalizing = 0; stopped = 0; selection = [:]
        pendingEnd = nil; forceSync = false; segmentHistory = []; extractionHistory = []
        extraction = ["state": "idle", "ready": false]; state = "starting"; detail = "Opening rear camera; no audio"
        startDone = done; started = ProcessInfo.processInfo.systemUptime; epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        lastSampleWall = started
        let csv = directory.appendingPathComponent("capture-events.csv")
        FileManager.default.createFile(atPath: csv.path, contents: Data("kind,timestampUs,value\n".utf8)); events = try FileHandle(forWritingTo: csv)
    }

    #if os(iOS)
    func start(config options: RecordingConfig, orientation: AVCaptureVideoOrientation,
               preview: AVCaptureVideoPreviewLayer? = nil, done: @escaping (Error?) -> Void) {
        queue.async {
            guard !["starting", "recording", "stopping"].contains(self.state), !self.extracting, self.finalizing == 0 else {
                done(RecordingError.invalid("Stop recording and finish extraction/finalization first")); return
            }
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw RecordingError.invalid("Camera access denied or not requested. Enable Camera in Settings.") }
                guard [.landscapeLeft, .landscapeRight].contains(orientation) else { throw RecordingError.invalid("Hold the phone in landscape before starting") }
                try self.prepare(options, done: done)
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw RecordingError.invalid("Rear camera unavailable") }
                let candidates: [(Int32, Int32)] = [(1280, 720), (640, 480)]
                var selected: (AVCaptureDevice.Format, Int32)?
                for (width, height) in candidates {
                    for fps: Int32 in [30, 24, 15] {
                        if let format = device.formats.first(where: {
                            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                            return size.width == width && size.height == height && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
                        }) { selected = (format, fps); break }
                    }
                    if selected != nil { break }
                }
                guard let (format, fps) = selected else { throw RecordingError.invalid("No 720p or 640×480 rear-camera format at 30/24/15 fps") }
                let capture = AVCaptureSession(); self.capture = capture; self.device = device
                capture.beginConfiguration()
                defer { capture.commitConfiguration() }
                capture.sessionPreset = .inputPriority
                let cameraInput = try AVCaptureDeviceInput(device: device)
                guard capture.canAddInput(cameraInput) else { throw RecordingError.invalid("Cannot add rear camera input") }; capture.addInput(cameraInput)
                self.previewLayer = preview
                preview?.session = capture
                if let previewConnection = preview?.connection, previewConnection.isVideoOrientationSupported {
                    previewConnection.videoOrientation = orientation
                    if previewConnection.isVideoMirroringSupported {
                        previewConnection.automaticallyAdjustsVideoMirroring = false; previewConnection.isVideoMirrored = false
                    }
                }
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
                if device.isVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false; device.isVideoHDREnabled = false }
                device.unlockForConfiguration()
                let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                let pixel = output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                guard output.availableVideoPixelFormatTypes.contains(pixel) else { throw RecordingError.invalid("No supported NV12 capture output") }
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard capture.canAddOutput(output) else { throw RecordingError.invalid("Cannot add video sample output") }; capture.addOutput(output)
                guard let connection = output.connection(with: .video), connection.isVideoOrientationSupported else { throw RecordingError.invalid("Landscape capture unavailable") }
                connection.videoOrientation = orientation
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                self.selection = ["camera": "rear", "device": device.modelID, "width": size.width, "height": size.height,
                    "requestedFps": fps, "aeRange": "\(fps)–\(fps)", "encoder": "VideoToolbox H.264 Baseline",
                    "rotationDegrees": 0, "fallback": size.width == 1280 && fps == 30 ? "None; actual fps still measured" : "Capability fallback; actual fps measured",
                    "sensorMetric": "AVCapture delivered input frames, not sensor exposure timestamps",
                    "supportedSizes": Array(Set(device.formats.map { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return "\(d.width)×\(d.height)" })).sorted(),
                    "supportedFpsRanges": format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)–\($0.maxFrameRate)" }]
                let current = self.run
                for notification in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
                    self.observers.append(NotificationCenter.default.addObserver(forName: notification, object: capture, queue: nil) { [weak self] note in
                        let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera session interrupted"
                        self?.queue.async { guard let self, self.run == current else { return }; self.stopOnQueue("\(reason); foreground and explicitly start a new experiment", interrupted: true) }
                    })
                }
                // startRunning must happen after commitConfiguration, on the same non-UI queue.
                self.queue.async { if self.run == current && self.state == "starting" { capture.startRunning(); self.watchdog(current) } }
            } catch {
                if self.state == "starting" { self.fail(error) } else { done(error) }
            }
        }
    }
    #endif

    private func createEncoder(width: Int32, height: Int32) throws {
        var compression: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &compression)
        guard result == noErr, let compression else { throw RecordingError.invalid("H.264 encoder unavailable (\(result))") }
        self.compression = compression
        let settings: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false, kVTCompressionPropertyKey_AverageBitRate: 4_000_000,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1, kVTCompressionPropertyKey_MaxKeyFrameInterval: 30,
            kVTCompressionPropertyKey_ExpectedFrameRate: selection["requestedFps"] ?? 30]
        for (key, value) in settings {
            let status = VTSessionSetProperty(compression, key: key, value: value as CFTypeRef)
            guard status == noErr else { throw RecordingError.invalid("Encoder rejected \(key) (\(status))") }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(compression) == noErr else { throw RecordingError.invalid("Cannot prepare encoder") }
        selection["encodedWidth"] = width; selection["encodedHeight"] = height
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        encodeInput(sample)
    }
    private func encodeInput(_ sample: CMSampleBuffer) {
        guard state == "starting" || state == "recording" else { return }
        do {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { throw RecordingError.invalid("Missing camera image") }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample); let us = RecordingMedia.microseconds(pts)
            guard lastInput < 0 || us > lastInput else { throw RecordingError.invalid("Non-monotonic capture timestamps") }
            if firstInput < 0 { firstInput = us }
            let delta = lastInput < 0 ? 0 : us - lastInput
            maxInputDelta = max(maxInputDelta, delta); if delta > 50_000 { inputGaps += 1 }
            lastInput = us; inputFrames += 1; try log("input", us, "\(delta)")
            let width = Int32(CVPixelBufferGetWidth(image)), height = Int32(CVPixelBufferGetHeight(image))
            guard width >= height else { throw RecordingError.invalid("Capture output is not landscape") }
            if compression == nil { try createEncoder(width: width, height: height) }
            guard inFlight < 16, let compression else { throw RecordingError.invalid("Encoder backlog exceeded sixteen frames; recording stopped") }
            inFlight += 1
            let current = run
            let currentEncoder = encoderEpoch
            let properties = forceSync ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            forceSync = false
            let result = VTCompressionSessionEncodeFrame(compression, imageBuffer: image, presentationTimeStamp: pts,
                duration: CMSampleBufferGetDuration(sample), frameProperties: properties, infoFlagsOut: nil) { [self] status, flags, encoded in
                queue.async { [self] in
                    guard run == current, encoderEpoch == currentEncoder else { return }; inFlight -= 1
                    do {
                        guard status == noErr else { throw RecordingError.invalid("Encoder callback failed (\(status))") }
                        guard let encoded, !flags.contains(.frameDropped) else {
                            droppedEncoder += 1; try log("encoderDrop", us, "frame dropped"); finishIfStopped(); return
                        }
                        try acceptEncoded(encoded)
                        if state == "stopping" { finishIfStopped() }
                    } catch { fail(error) }
                }
            }
            guard result == noErr else { inFlight -= 1; throw RecordingError.invalid("Cannot encode camera frame (\(result))") }
        } catch { fail(error) }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state == "recording" || state == "starting" else { return }
        do {
            droppedInput += 1
            let reason = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
            try log("inputDrop", RecordingMedia.microseconds(CMSampleBufferGetPresentationTimeStamp(sample)), reason.map { String(describing: $0) } ?? "unknown")
        } catch { fail(error) }
    }

    private func acceptEncoded(_ sample: CMSampleBuffer) throws {
        guard ["starting", "recording", "stopping"].contains(state) else { return }
        let pts = RecordingMedia.microseconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard lastPts < 0 || pts > lastPts else { throw RecordingError.invalid("Non-monotonic encoded timestamps") }
        let sync = RecordingMedia.sync(sample)
        if active == nil && !sync { throw RecordingError.invalid("Encoder did not begin with a sync frame") }
        if let active, sync, pts - active.firstUs >= Self.segmentUs || pendingEnd != nil && sync { try seal() }
        if active == nil {
            let segment = RecordingSegment(url: directory.appendingPathComponent("segment-\(pts).mp4"), firstUs: pts)
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw RecordingError.invalid("Missing encoder format") }
            let newWriter = try AVAssetWriter(outputURL: segment.url, fileType: .mp4)
            let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
            newInput.expectsMediaDataInRealTime = true; newInput.mediaTimeScale = 1_000_000
            guard newWriter.canAdd(newInput) else { throw RecordingError.invalid("Cannot add compressed video") }; newWriter.add(newInput)
            guard newWriter.startWriting() else { throw newWriter.error ?? RecordingError.invalid("Cannot start segment") }
            newWriter.startSession(atSourceTime: .zero)
            writer = newWriter; input = newInput; active = segment; precedingInterval = lastPts < 0 ? 0 : pts - lastPts
            FileManager.default.createFile(atPath: segment.csv.path, contents: Data("ptsUs,deltaUs,keyframe\n".utf8))
            framesCSV = try FileHandle(forWritingTo: segment.csv)
        }
        guard let writer, let input, let active, input.isReadyForMoreMediaData else {
            throw RecordingError.invalid("Segment writer backpressure; capture stopped rather than silently dropping frames")
        }
        // Store local PTS directly; avoid edit-list rounding of a large capture clock origin.
        let copy = try RecordingMedia.retime(sample, ptsUs: pts - active.firstUs)
        guard input.append(copy) else { throw writer.error ?? RecordingError.invalid("Cannot append compressed frame") }
        let delta = lastPts < 0 ? 0 : pts - lastPts
        if firstPts < 0 { firstPts = pts }; maxEncodedDelta = max(maxEncodedDelta, delta); if delta > 50_000 { encodedGaps += 1 }
        try framesCSV?.write(contentsOf: Data("\(pts),\(delta),\(sync ? 1 : 0)\n".utf8)); try log("encoded", pts, "\(delta)")
        lastPts = pts; encodedFrames += 1; active.lastUs = pts; active.frames += 1
        totalVideoBytes += CMSampleBufferGetTotalSampleSize(sample); lastSampleWall = ProcessInfo.processInfo.systemUptime
        try buffer.evict(latestUs: pts)
        if state == "starting" { state = "recording"; detail = "Continuous rear-camera capture; keep landscape and foreground"; startDone?(nil); startDone = nil }
        if pts - active.firstUs >= Self.segmentUs { forceSync = true }
        guard pts - active.firstUs < 10_000_000 else { throw RecordingError.invalid("No segment keyframe within ten seconds") }
    }
    private func seal() throws {
        guard let writer, let input, let active else { return }
        self.writer = nil; self.input = nil; self.active = nil
        try framesCSV?.close(); framesCSV = nil
        buffer.segments.append(active); finalizing += 1
        closingWriters[active.url.lastPathComponent] = writer
        input.markAsFinished(); let current = run; let boundaryDelta = precedingInterval
        writer.finishWriting { [self] in queue.async { [self] in
            guard run == current else { return }
            finalizing -= 1
            closingWriters.removeValue(forKey: active.url.lastPathComponent)
            guard writer.status == .completed else { fail(writer.error ?? RecordingError.invalid("Cannot finalize recording segment")); return }
            active.finalizing = false
            segmentHistory.append(["file": active.url.lastPathComponent, "firstPtsUs": active.firstUs, "lastPtsUs": active.lastUs,
                "frames": active.frames, "precedingIntervalUs": boundaryDelta, "bytes": (try? active.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0])
            if segmentHistory.count > 1000 { segmentHistory.removeFirst() }
            do { try launchIfSealed(); try buffer.evict(latestUs: lastPts); try saveReport(); finishIfStopped() } catch { fail(error) }
        } }
        queue.asyncAfter(deadline: .now() + 10) { [self] in
            if run == current && active.finalizing { writer.cancelWriting(); fail(RecordingError.invalid("Segment finalization exceeded ten seconds")) }
        }
    }
    func extract(endpointHostUs: Int64? = nil, _ done: @escaping (Error?) -> Void) { queue.async {
        guard self.state == "recording", !self.extracting else { done(RecordingError.invalid("Record first; only one extraction may run")); return }
        guard self.lastPts - self.firstPts >= Int64(self.config.reviewSeconds) * 1_000_000 else { done(RecordingError.invalid("Wait for the configured review duration")); return }
        var target = self.lastPts
        self.extractionTiming = [:]
        if let endpointHostUs {
            let sessionClock: CMClock?
            if #available(iOS 15.4, macOS 12.3, *) { sessionClock = self.capture?.synchronizationClock }
            else { sessionClock = self.capture?.masterClock }
            guard let clock = sessionClock else { done(RecordingError.invalid("Capture clock unavailable")); return }
            let converted = CMSyncConvertTime(CMTime(value: endpointHostUs, timescale: 1_000_000), from: CMClockGetHostTimeClock(), to: clock)
            guard converted.isNumeric else { done(RecordingError.invalid("Capture clock mapping unavailable")); return }
            target = RecordingMedia.microseconds(converted)
            self.extractionTiming = ["requestedHostUs": endpointHostUs, "requestedSourceUs": target]
        }
        let endpoint = min(target, self.lastPts)
        guard endpoint - self.firstPts >= Int64(self.config.reviewSeconds) * 1_000_000 else { done(RecordingError.invalid("Requested window is not available")); return }
        self.pendingEnd = endpoint; self.forceSync = true; self.extractDone = done; self.extracting = true
        self.extraction = ["state": "sealing", "ready": false, "detail": "Waiting for next keyframe and file finalization; capture continues"]
        do { try self.launchIfSealed() } catch { self.extractionFailed(error) }
        let end = self.pendingEnd
        self.queue.asyncAfter(deadline: .now() + 5) {
            if self.pendingEnd != nil && self.pendingEnd == end { self.extractionFailed(RecordingError.invalid("Extraction sealing timed out; recording continues")) }
        }
    } }
    private func launchIfSealed() throws {
        guard let end = pendingEnd else { return }
        let needed = buffer.segments.filter { $0.lastUs >= end - Int64(config.reviewSeconds) * 1_000_000 && $0.firstUs <= end }
        guard needed.last?.lastUs ?? -1 >= end, needed.allSatisfy({ !$0.finalizing }) else { return }
        let selected = try buffer.pin(endUs: end); pendingEnd = nil
        extraction = ["state": "extracting", "ready": false, "detail": "Pinned inputs; capture continues"]
        let review = config.reviewSeconds
        worker.async { [self] in
            let result: Result<[String: Any], Error> = Result {
                if FileManager.default.fileExists(atPath: clip.path) { try FileManager.default.removeItem(at: clip) }
                return try RecordingClip.extract(segments: selected, endUs: end, reviewSeconds: review, output: clip)
            }
            queue.async { [self] in
                buffer.release(selected); extracting = false
                switch result {
                case .success(var info):
                    for (key, value) in extractionTiming { info[key] = value }
                    if let target = extractionTiming["requestedSourceUs"] as? Int64, let actual = info["sourceLastUs"] as? Int64 {
                        info["endpointErrorUs"] = actual - target
                    }
                    if extractionTiming["requestedSourceUs"] != nil {
                        info["retentionSeconds"] = config.retentionSeconds; info["reviewSeconds"] = config.reviewSeconds
                        do { _ = try SampleTransfer.recordingMetadata(info) }
                        catch { extractionFailed(error); return }
                    }
                    info["state"] = "ready"; info["detail"] = "Clip ready; beginning/middle/end frames decoded"; extraction = info
                    extractionHistory.append(info); if extractionHistory.count > 100 { extractionHistory.removeFirst() }
                    extractDone?(nil); extractDone = nil
                case .failure(let error): extractionFailed(error)
                }
                do { try buffer.evict(latestUs: lastPts); try saveReport() } catch { fail(error) }
            }
        }
    }
    private func extractionFailed(_ error: Error) {
        pendingEnd = nil; extracting = false
        extraction = ["state": "failed", "ready": false, "detail": error.localizedDescription]
        extractionHistory.append(extraction); if extractionHistory.count > 100 { extractionHistory.removeFirst() }
        extractDone?(error); extractDone = nil
    }
    func exportReview(_ done: @escaping (Result<(URL, [String: Any]), Error>) -> Void) { queue.async {
        var exportedURL: URL?
        do {
            guard !self.extracting, self.extraction["ready"] as? Bool == true else { throw RecordingError.invalid("No complete recording clip") }
            var info = self.extraction
            info["retentionSeconds"] = self.config.retentionSeconds; info["reviewSeconds"] = self.config.reviewSeconds
            let metadata = try SampleTransfer.recordingMetadata(info)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-review-outgoing")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(UUID().uuidString + ".mp4")
            exportedURL = copy
            try FileManager.default.copyItem(at: self.clip, to: copy)
            done(.success((copy, metadata)))
        } catch {
            if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
            done(.failure(error))
        }
    } }
    func completedClip(_ done: @escaping (URL?) -> Void) { queue.async {
        done(!self.extracting && self.extraction["ready"] as? Bool == true && FileManager.default.fileExists(atPath: self.clip.path) ? self.clip : nil)
    } }
    func stop(reason: String = "Stopped by user", interrupted: Bool = false, done: @escaping () -> Void = {}) { queue.async {
        if self.state == "stopping" { self.stopDone.append(done); return }
        guard ["starting", "recording"].contains(self.state) else { done(); return }
        self.stopDone.append(done); self.stopOnQueue(reason, interrupted: interrupted)
    } }
    private func stopOnQueue(_ reason: String, interrupted: Bool = false) {
        guard ["starting", "recording"].contains(state) else { return }
        state = "stopping"; detail = reason
        if pendingEnd != nil { extractionFailed(RecordingError.invalid("Recording stopped before extraction sealed")) }
        startDone?(RecordingError.invalid(reason)); startDone = nil
        capture?.stopRunning(); detachPreview(); removeObservers(); capture = nil; device = nil; timer?.cancel(); timer = nil
        if let compression {
            let result = VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            if result != noErr {
                guard interrupted && result == kVTInvalidSessionErr else {
                    fail(RecordingError.invalid("Cannot drain encoder (\(result))")); return
                }
                // iOS can revoke the hardware encoder on background/lock. Preserve frames
                // already appended, disclose any unfinished tail, and fence late callbacks.
                droppedEncoder += inFlight
                do { try log("interruptedEncoder", lastPts, "invalid session; \(inFlight) pending frames discarded") }
                catch { fail(error); return }
                detail = "\(reason). Encoder unavailable; retained completed frames, unfinished tail may be missing. Tap Start to record again."
                releaseEncoder(); inFlight = 0
            }
        }
        finishIfStopped()
        let current = run
        queue.asyncAfter(deadline: .now() + 10) { if self.run == current && self.state == "stopping" { self.fail(RecordingError.invalid("Recording stop timed out")) } }
    }
    private func finishIfStopped() {
        guard state == "stopping", inFlight == 0 else { return }
        do { try seal() } catch { fail(error); return }
        guard finalizing == 0 else { return }
        releaseEncoder(); state = "stopped"; stopped = ProcessInfo.processInfo.systemUptime
        do { try saveReport() } catch { fail(error); return }
        captureEnded?(); let completions = stopDone; stopDone = []; completions.forEach { $0() }
    }
    private func fail(_ error: Error) {
        state = "failed"; detail = error.localizedDescription; stopped = ProcessInfo.processInfo.systemUptime
        run += 1; capture?.stopRunning(); detachPreview(); capture = nil; device = nil; removeObservers(); timer?.cancel(); timer = nil
        releaseEncoder(); writer?.cancelWriting(); writer = nil; input = nil; active = nil
        for closing in closingWriters.values where closing.status == .writing { closing.cancelWriting() }; closingWriters = [:]
        try? framesCSV?.close(); framesCSV = nil; finalizing = 0; inFlight = 0
        if pendingEnd != nil { extractionFailed(error) }
        startDone?(error); startDone = nil; try? saveReport(); captureEnded?()
        let completions = stopDone; stopDone = []; completions.forEach { $0() }
    }
    private func releaseEncoder() {
        encoderEpoch += 1
        if let compression { VTCompressionSessionInvalidate(compression) }; compression = nil
    }
    private func detachPreview() {
        #if os(iOS)
        previewLayer?.session = nil; previewLayer = nil
        #endif
    }
    private func removeObservers() { observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = [] }
    private func watchdog(_ current: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.run == current, ["starting", "recording"].contains(self.state) else { return }
            do {
                guard ProcessInfo.processInfo.systemUptime - self.lastSampleWall < 10 else { throw RecordingError.invalid("No encoded frame for ten seconds") }
                let resources = try self.directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                guard self.diskBytes() < Self.maxDiskBytes, (resources.volumeAvailableCapacity ?? 0) > 64 * 1024 * 1024 else { throw RecordingError.invalid("Recording storage bound reached or disk space low") }
                let eventBytes = try self.directory.appendingPathComponent("capture-events.csv").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard eventBytes < 16 * 1024 * 1024 else { throw RecordingError.invalid("Timestamp evidence reached its 16 MiB bound") }
                try self.log("thermal", Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), "\(ProcessInfo.processInfo.thermalState.rawValue)")
                #if os(iOS)
                if let device = self.device { try self.log("pressure", Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), device.systemPressureState.level.rawValue) }
                #endif
                try self.saveReport()
            } catch { self.fail(error) }
        }
        timer.resume()
    }
    func cleanup(_ done: @escaping (Error?) -> Void) { queue.async {
        do {
            guard !["starting", "recording", "stopping"].contains(self.state), !self.extracting, self.finalizing == 0 else { throw RecordingError.invalid("Stop capture and finish extraction/finalization before cleanup") }
            try self.events?.close(); self.events = nil
            if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
            self.buffer = RecordingBuffer(config: self.config); self.state = "idle"; self.detail = "Recording files removed"
            self.started = 0; self.stopped = 0; self.epochMs = 0; self.firstPts = -1; self.lastPts = -1; self.firstInput = -1; self.lastInput = -1
            self.encodedFrames = 0; self.inputFrames = 0; self.maxEncodedDelta = 0; self.maxInputDelta = 0; self.encodedGaps = 0; self.inputGaps = 0
            self.droppedInput = 0; self.droppedEncoder = 0; self.selection = [:]; self.peakBytes = 0; self.totalVideoBytes = 0
            self.segmentHistory = []; self.extractionHistory = []; self.extraction = ["state": "idle", "ready": false]; done(nil)
        } catch { done(error) }
    } }

    #if RECORDING_TEST
    // Test-only fixture input. Not exposed in the installed Capacitor plugin; no camera is opened.
    func beginFixture(config: RecordingConfig) throws { try queue.sync {
        try prepare(config, done: { _ in }); selection = ["requestedFps": 30, "source": "synthetic test fixture"]
    } }
    func appendFixture(_ sample: CMSampleBuffer) throws { try queue.sync { try acceptEncoded(sample) } }
    func appendRawFixture(_ sample: CMSampleBuffer) { queue.sync { encodeInput(sample) } }
    func stopInvalidatedFixture(interrupted: Bool, done: @escaping () -> Void) { queue.async {
        if let compression = self.compression { VTCompressionSessionInvalidate(compression) }
        self.stopDone.append(done); self.stopOnQueue("Fixture interruption", interrupted: interrupted)
    } }
    #endif
}
