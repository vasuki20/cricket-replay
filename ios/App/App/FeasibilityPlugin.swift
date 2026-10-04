import UIKit
import AVFoundation
import AVKit
import Capacitor

@objc(FeasibilityPlugin)
public class FeasibilityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FeasibilityPlugin"
    public let jsName = "Feasibility"
    public let pluginMethods: [CAPPluginMethod] = [
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

    @objc func sampleStatus(_ call: CAPPluginCall) { DispatchQueue.main.async { call.resolve(self.sampleInfo) } }
    @objc func generateSample(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
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
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.session.stop(reason: "App backgrounded; foreground and restart/reconnect")
        }
    }
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        session.stop()
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

@objc(FeasibilityViewController)
class FeasibilityViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(FeasibilityPlugin())
    }
}
