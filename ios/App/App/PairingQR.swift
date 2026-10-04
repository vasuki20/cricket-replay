import Foundation
import CoreImage
import UIKit
import AVFoundation

extension PairingCode {
    func imageURL() -> String? {
        guard valid, let data = try? JSONEncoder().encode(self), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent), let png = UIImage(cgImage: cg).pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

final class PairingScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "cricket.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()
    private var finished = false
    var completion: ((PairingCode?, String?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.text = "Point at the host’s pairing QR code"
        message.textColor = .white; message.backgroundColor = .black
        message.numberOfLines = 0; message.textAlignment = .center
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal); cancel.tintColor = .white
        cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        view.addSubview(message); view.addSubview(cancel)
        message.translatesAutoresizingMaskIntoConstraints = false; cancel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancel.heightAnchor.constraint(equalToConstant: 48),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: capture)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.runtimeErrorNotification, object: capture)
        configure()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !finished { finish(nil, "Scan cancelled") }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func configure() {
        queue.async {
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    DispatchQueue.main.async { self.finish(nil, "Rear camera unavailable") }; return
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                self.capture.beginConfiguration()
                guard self.capture.canAddInput(input) else {
                    self.capture.commitConfiguration(); DispatchQueue.main.async { self.finish(nil, "Cannot open camera") }; return
                }
                self.capture.addInput(input)
                guard self.capture.canAddOutput(output) else {
                    self.capture.commitConfiguration(); DispatchQueue.main.async { self.finish(nil, "QR scanning unavailable") }; return
                }
                self.capture.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.capture.commitConfiguration(); DispatchQueue.main.async { self.finish(nil, "QR scanning unavailable") }; return
                }
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                self.capture.commitConfiguration()
                DispatchQueue.main.async {
                    guard !self.finished else { return }
                    let layer = AVCaptureVideoPreviewLayer(session: self.capture)
                    layer.videoGravity = .resizeAspectFill; layer.frame = self.view.bounds
                    self.view.layer.insertSublayer(layer, at: 0); self.preview = layer
                    self.queue.async { self.capture.startRunning() }
                }
            } catch { DispatchQueue.main.async { self.finish(nil, "Cannot start scanner: \(error.localizedDescription)") } }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !finished, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        guard let code = PairingCode.decode(text) else { message.text = "This is not a valid Replay pairing code. Scan the host’s code."; return }
        finish(code, nil)
    }
    @objc private func cancelScan() { finish(nil, "Scan cancelled") }
    @objc private func backgrounded() { finish(nil, "Scan stopped when app went to background") }
    @objc private func interrupted() { DispatchQueue.main.async { self.finish(nil, "Camera interrupted; try scanning again") } }
    private func finish(_ code: PairingCode?, _ error: String?) {
        guard !finished else { return }; finished = true
        queue.async { self.capture.stopRunning() }
        dismiss(animated: true) { self.completion?(code, error); self.completion = nil }
    }
}
