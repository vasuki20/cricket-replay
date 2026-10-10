import UIKit
import AVFoundation
import AVKit
import Capacitor

@objc(FeasibilityPlugin)
public class FeasibilityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FeasibilityPlugin"
    public let jsName = "Feasibility"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setRecordingPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordingStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordingReport", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "extractRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playRecordingClip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cleanupRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ping", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestCameraPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "generateSessionSecret", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startHost", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connectCamera", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sessionStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendSessionPing", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createPairingQR", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scanPairingQR", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "generateSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sampleStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playReceivedSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cleanupSamples", returnType: CAPPluginReturnPromise)
    ]
    private let session = LocalSession()
    private var backgroundObserver: NSObjectProtocol?
    private var scanner: PairingScanner?
    private var requestingScan = false
    private var sampleURL: URL?
    private var sampleInfo: [String: Any] = ["ready": false]
    private var generating = false
    private let recording = RollingRecording()
    private var cameraRecording = false
    private var previousIdleTimer: Bool?
    private var recordingPreview: RecordingPreviewView?
    private var recordingPreviewContainer: UIView?
    @objc func setRecordingPreview(_ call: CAPPluginCall) { DispatchQueue.main.async {
        let visible = call.getBool("visible") ?? false
        if !visible && self.recordingPreview == nil { call.resolve(); return }
        guard let web = self.bridge?.webView, let parent = web.superview,
              let x = call.getDouble("x"), let y = call.getDouble("y"), let width = call.getDouble("width"),
              let height = call.getDouble("height"), let viewport = call.getDouble("viewportWidth"),
              [x, y, width, height, viewport].allSatisfy({ $0.isFinite }), width > 0, height > 0, viewport > 0 else {
            call.reject("Invalid camera preview bounds"); return
        }
        let preview = self.recordingPreview ?? RecordingPreviewView()
        let container = self.recordingPreviewContainer ?? UIView()
        container.frame = web.frame; container.clipsToBounds = true; container.isUserInteractionEnabled = false
        if self.recordingPreview == nil {
            parent.addSubview(container); container.addSubview(preview)
            self.recordingPreview = preview; self.recordingPreviewContainer = container
        }
        let scale = web.bounds.width / CGFloat(viewport)
        let frame = web.convert(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale,
                                      width: CGFloat(width) * scale, height: CGFloat(height) * scale), to: container)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = frame; preview.isHidden = !visible
        CATransaction.commit()
        call.resolve()
    } }

    @objc func recordingStatus(_ call: CAPPluginCall) { recording.status { call.resolve($0) } }
    @objc func recordingReport(_ call: CAPPluginCall) { recording.report { result in
        switch result { case .success(let report): call.resolve(["report": report]); case .failure(let error): call.reject(error.localizedDescription) }
    } }
    @objc func startRecording(_ call: CAPPluginCall) { DispatchQueue.main.async {
        guard !self.cameraRecording, !self.generating, !self.requestingScan, self.scanner == nil,
              self.bridge?.viewController?.presentedViewController == nil, UIApplication.shared.applicationState == .active else {
            call.reject("Stop capture, close scanning/playback and foreground the app first"); return
        }
        guard let retention = call.getValue("retentionSeconds") as? NSNumber, let review = call.getValue("reviewSeconds") as? NSNumber,
              CFGetTypeID(retention) != CFBooleanGetTypeID(), CFGetTypeID(review) != CFBooleanGetTypeID(),
              retention.doubleValue.isFinite, review.doubleValue.isFinite,
              retention.doubleValue.rounded() == retention.doubleValue, review.doubleValue.rounded() == review.doubleValue,
              (30...180).contains(retention.doubleValue), (5...30).contains(review.doubleValue) else {
            call.reject("Retention/review must be whole seconds within the experiment bounds"); return
        }
        guard let scene = self.bridge?.viewController?.view.window?.windowScene, scene.interfaceOrientation.isLandscape else {
            call.reject("Hold the phone in landscape before starting (disable orientation lock if needed)"); return
        }
        do {
            let config = try RecordingConfig(retentionSeconds: retention.intValue, reviewSeconds: review.intValue)
            self.cameraRecording = true; self.previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            let orientation: AVCaptureVideoOrientation = scene.interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
            self.recording.start(config: config, orientation: orientation, preview: self.recordingPreview?.previewLayer) { error in
                if let error { DispatchQueue.main.async { self.restoreRecordingScreen() }; call.reject(error.localizedDescription) }
                else { call.resolve() }
            }
        } catch { call.reject(error.localizedDescription) }
    } }
    @objc func stopRecording(_ call: CAPPluginCall) { recording.stop { call.resolve() } }
    @objc func extractRecording(_ call: CAPPluginCall) { DispatchQueue.main.async {
        guard self.bridge?.viewController?.presentedViewController == nil else { call.reject("Close playback before replacing the clip"); return }
        self.recording.extract { error in if let error { call.reject(error.localizedDescription) } else { call.resolve() } }
    } }
    @objc func playRecordingClip(_ call: CAPPluginCall) { recording.completedClip { url in
        guard let url else { call.reject("No completed recording clip"); return }
        DispatchQueue.main.async {
            guard let presenter = self.bridge?.viewController, presenter.presentedViewController == nil,
                  UIApplication.shared.applicationState == .active else { call.reject("Close playback and foreground the app first"); return }
            let player = RecordingPlayer(url: url) { error in
                if let error { call.reject(error) } else { call.resolve() }
            }
            presenter.present(player, animated: true)
        }
    } }
    @objc func cleanupRecording(_ call: CAPPluginCall) { DispatchQueue.main.async {
        guard self.bridge?.viewController?.presentedViewController == nil else { call.reject("Close playback before cleanup"); return }
        self.recording.cleanup { error in if let error { call.reject(error.localizedDescription) } else { call.resolve() } }
    } }
    private func restoreRecordingScreen() {
        cameraRecording = false
        recordingPreview?.isHidden = true
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }; previousIdleTimer = nil
    }

    @objc func sampleStatus(_ call: CAPPluginCall) { DispatchQueue.main.async { call.resolve(self.sampleInfo) } }
    @objc func generateSample(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard !self.cameraRecording else { call.reject("Stop recording before synthetic generation"); return }
            guard !self.generating else { call.reject("Already generating"); return }
            // Reuse the same independent sample for all three timed attempts.
            if self.sampleURL != nil { call.resolve(self.sampleInfo); return }
            self.generating = true
            SampleVideo.generate { result in
                do {
                    let url = try result.get()
                    let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    let hash = try SampleTransfer.checksum(url)
                    DispatchQueue.main.async {
                        self.generating = false; self.sampleURL = url
                        self.sampleInfo = ["ready": true, "bytes": bytes, "sha256": hash, "durationSeconds": 20]
                        call.resolve(self.sampleInfo)
                    }
                } catch { DispatchQueue.main.async { self.generating = false; call.reject(error.localizedDescription) } }
            }
        }
    }
    @objc func sendSample(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let url = self.sampleURL else { call.reject("Generate the sample first"); return }
            self.session.sendSample(url, slow: call.getBool("slow") ?? false) { error in
                if let error { call.reject(error.localizedDescription) } else { call.resolve() }
            }
        }
    }
    @objc func playReceivedSample(_ call: CAPPluginCall) {
        session.completedSample { url in
            guard let url else { call.reject("No complete, checksum-verified sample"); return }
            DispatchQueue.main.async {
                guard let presenter = self.bridge?.viewController, presenter.presentedViewController == nil,
                      UIApplication.shared.applicationState == .active else { call.reject("Return to the app before playback"); return }
                let player = AVPlayerViewController(); player.player = AVPlayer(url: url)
                presenter.present(player, animated: true) { player.player?.play(); call.resolve() }
            }
        }
    }
    @objc func cleanupSamples(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard !self.generating, self.bridge?.viewController?.presentedViewController == nil else { call.reject("Finish generation/playback before cleanup"); return }
            self.session.cleanupTransfer { error in
                DispatchQueue.main.async {
                    if let error { call.reject(error.localizedDescription); return }
                    do {
                        if let url = self.sampleURL { try FileManager.default.removeItem(at: url) }
                        self.sampleURL = nil; self.sampleInfo = ["ready": false]; call.resolve()
                    } catch { call.reject(error.localizedDescription) }
                }
            }
        }
    }

    @objc func createPairingQR(_ call: CAPPluginCall) {
        guard let (secret, port) = options(call) else { return }
        guard let address = call.getString("address") else { call.reject("Pairing address missing"); return }
        let code = PairingCode(kind: "cricket-replay-pairing", version: 1, address: address, port: Int(port), secret: secret)
        guard let image = code.imageURL() else { call.reject("Cannot create QR for this address"); return }
        call.resolve(["image": image])
    }
    @objc func scanPairingQR(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard !self.cameraRecording else { call.reject("Stop recording before opening the QR camera"); return }
            guard !self.requestingScan, self.scanner == nil else { call.reject("Scanner already open"); return }
            self.requestingScan = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.requestingScan = false
                    guard granted else { call.reject("Camera access denied. Enable Camera in Settings to scan."); return }
                    guard UIApplication.shared.applicationState == .active,
                          let presenter = self.bridge?.viewController, presenter.presentedViewController == nil else {
                        call.reject("Return to the app before scanning"); return
                    }
                    let scanner = PairingScanner(); self.scanner = scanner
                    scanner.modalPresentationStyle = .fullScreen
                    scanner.completion = { [weak self] code, error in
                        self?.scanner = nil
                        if let code { call.resolve(code.result) } else { call.reject(error ?? "Scan cancelled") }
                    }
                    presenter.present(scanner, animated: true)
                }
            }
        }
    }

    public override func load() {
        recording.captureEnded = { [weak self] in DispatchQueue.main.async { self?.restoreRecordingScreen() } }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "Finalize recording") {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            }
            self.recording.stop(reason: "App backgrounded/locked; foreground and explicitly start a new experiment", interrupted: true) {
                DispatchQueue.main.async {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
                }
            }
            self.restoreRecordingScreen()
            self.session.stop(reason: "App backgrounded; foreground and restart/reconnect")
        }
    }
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        session.stop()
        recording.stop(reason: "App closed")
    }
    @objc func generateSessionSecret(_ call: CAPPluginCall) { call.resolve(["secret": LocalSession.newSecret()]) }
    private func options(_ call: CAPPluginCall) -> (String, UInt16)? {
        guard let secret = call.getString("secret"), LocalSession.validSecret(secret),
              let port = call.getInt("port"), (1024...65535).contains(port) else {
            call.reject("Use the generated 32-character lowercase hex secret and port 1024–65535"); return nil
        }
        return (secret, UInt16(port))
    }
    @objc func startHost(_ call: CAPPluginCall) {
        guard let (secret, port) = options(call) else { return }
        session.startHost(secret: secret, port: port) { error in
            if let error { call.reject(error.localizedDescription) } else { call.resolve() }
        }
    }
    @objc func connectCamera(_ call: CAPPluginCall) {
        guard let (secret, port) = options(call) else { return }
        guard let address = call.getString("address") else { call.reject("Enter the host IPv4 address"); return }
        guard PairingCode.validAddress(address) else {
            call.reject("Enter the host's private/local IPv4 address, without a port"); return
        }
        session.connect(address: address, secret: secret, port: port); call.resolve()
    }
    @objc func sessionStatus(_ call: CAPPluginCall) { session.status { call.resolve($0) } }
    @objc func sendSessionPing(_ call: CAPPluginCall) {
        session.ping(status: call.getBool("status") ?? false) { sent in
            if sent { call.resolve() } else { call.reject("Connect and authenticate first; at most four requests may be outstanding") }
        }
    }
    @objc func stopSession(_ call: CAPPluginCall) { session.stop(); call.resolve() }

    private func diagnostics() -> [String: Any] {
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = "granted"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        case .notDetermined: permission = "not requested"
        @unknown default: permission = "unknown"
        }
        return ["platform": "ios",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "osVersion": UIDevice.current.systemVersion,
                "cameraPermission": permission]
    }

    @objc func ping(_ call: CAPPluginCall) {
        call.resolve(diagnostics())
    }

    @objc func requestCameraPermission(_ call: CAPPluginCall) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { call.resolve(self.diagnostics()) }
        }
    }
}

private final class RecordingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false; clipsToBounds = true; backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
}

@objc(FeasibilityViewController)
class FeasibilityViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(FeasibilityPlugin())
    }
}
