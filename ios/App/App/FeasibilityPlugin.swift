import UIKit
import AVFoundation
import Capacitor

@objc(FeasibilityPlugin)
public class FeasibilityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FeasibilityPlugin"
    public let jsName = "Feasibility"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "ping", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestCameraPermission", returnType: CAPPluginReturnPromise)
    ]

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
