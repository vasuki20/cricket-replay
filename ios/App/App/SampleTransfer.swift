import Foundation
import CryptoKit

enum TransferError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

// All operations run on LocalSession's serial queue. One bounded, acknowledged chunk in flight.
final class SampleTransfer {
    static let chunkSize = 16 * 1024
    static let maxBytes = 32 * 1024 * 1024
    private let queue: DispatchQueue
    private let directory: URL
    private var handle: FileHandle?
    private var partial: URL?
    private(set) var completed: URL?
    private var id = ""
    private var total = 0
    private var offset = 0
    private var checksum = ""
    private var digest = SHA256()
    private var started = 0.0
    private var timer: DispatchWorkItem?
    private var sending = false
    private var slow = false
    private var phase = "idle"
    private var history: [[String: Any]] = []
    private(set) var state: [String: Any] = ["state": "idle", "bytes": 0, "totalBytes": 0, "checksumVerified": false]
    var onSend: ((String, [String: Any]) -> Void)?
    var onChange: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var active: Bool { ["offer", "sending", "receiving", "finishing"].contains(phase) }

    init(queue: DispatchQueue, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-transfer-" + UUID().uuidString)) {
        self.queue = queue; self.directory = directory
    }
    static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: chunkSize), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func update(_ phase: String, _ detail: String) {
        self.phase = phase
        state = ["state": phase, "detail": detail, "requestId": id, "bytes": offset, "totalBytes": total,
                 "sha256": checksum, "checksumVerified": phase == "ready" || phase == "complete", "attempts": history]
        if phase == "ready" || phase == "complete" {
            let seconds = max(ProcessInfo.processInfo.systemUptime - started, 0.000001)
            state["durationSeconds"] = seconds; state["throughputMBps"] = Double(total) / seconds / 1_000_000
            var result = state; result.removeValue(forKey: "attempts")
            history.append(result); history = Array(history.suffix(10)); state["attempts"] = history
        }
        onChange?(state)
    }
    private func arm() {
        timer?.cancel()
        guard active else { return }
        let current = id
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.id == current, self.active else { return }
            self.fail("Transfer timed out; reconnect and retry")
        }
        timer = item; queue.asyncAfter(deadline: .now() + 30, execute: item)
    }
    private func send(_ packet: [String: Any]) {
        arm()
        if slow && packet["kind"] as? String == "chunk" {
            let request = id
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.id == request, self.active else { return }; self.onSend?(request, packet)
            }
        } else { onSend?(id, packet) }
    }
    private func clearPartial() {
        timer?.cancel(); timer = nil; try? handle?.close(); handle = nil
        if let partial { try? FileManager.default.removeItem(at: partial) }; partial = nil
    }
    func cancel(_ reason: String) {
        let interrupted = active
        clearPartial()
        if interrupted { update("failed", reason) }
    }
    func cleanup() throws {
        guard !active else { throw TransferError.invalid("Stop the transfer before cleaning files") }
        clearPartial()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        completed = nil; history = []; id = ""; offset = 0; total = 0; checksum = ""
        update("idle", "Temporary received files removed")
    }
    private func prepare() throws {
        guard !active else { throw TransferError.invalid("A transfer is already active") }
        clearPartial()
        if let completed { try FileManager.default.removeItem(at: completed) }; completed = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        offset = 0; digest = SHA256(); started = ProcessInfo.processInfo.systemUptime
    }
    func begin(_ url: URL, slow: Bool = false) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maxBytes else { throw TransferError.invalid("Sample must be 1–32 MiB") }
        let hash = try Self.checksum(url)
        try prepare(); id = UUID().uuidString.lowercased(); total = size; checksum = hash; sending = true; self.slow = slow
        handle = try FileHandle(forReadingFrom: url)
        update("offer", "Waiting for host to accept sample")
        send(["kind": "offer", "bytes": total, "sha256": checksum])
    }
    private func fail(_ message: String) { clearPartial(); update("failed", message); onFailure?(message) }
    func receive(id incomingID: String, packet: [String: Any], isHost: Bool) {
        do {
            guard UUID(uuidString: incomingID) != nil, let kind = packet["kind"] as? String else { throw TransferError.invalid("Invalid transfer message") }
            if kind == "offer" {
                guard isHost, let bytes = packet["bytes"] as? Int, (1...Self.maxBytes).contains(bytes),
                      let hash = packet["sha256"] as? String, hash.count == 64,
                      hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw TransferError.invalid("Invalid sample offer") }
                try prepare(); id = incomingID; total = bytes; checksum = hash; sending = false; slow = false
                let path = directory.appendingPathComponent(id + ".part")
                guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw TransferError.invalid("Cannot create partial file") }
                partial = path; handle = try FileHandle(forWritingTo: path)
                update("receiving", "Receiving encrypted sample")
                send(["kind": "ack", "offset": 0]); return
            }
            guard active, incomingID == id else { throw TransferError.invalid("Unexpected transfer/request ID") }
            switch kind {
            case "ack":
                guard sending, ["offer", "sending"].contains(phase), packet["offset"] as? Int == offset else { throw TransferError.invalid("Invalid chunk acknowledgement") }
                if offset == total {
                    try handle?.close(); handle = nil; update("finishing", "Waiting for host checksum verification")
                    send(["kind": "end"])
                } else {
                    guard let bytes = try handle?.read(upToCount: min(Self.chunkSize, total - offset)), !bytes.isEmpty else { throw TransferError.invalid("Sample read failed") }
                    let start = offset; offset += bytes.count
                    update("sending", "Sending encrypted sample")
                    send(["kind": "chunk", "offset": start, "data": bytes.base64EncodedString()])
                }
            case "chunk":
                guard !sending, phase == "receiving", packet["offset"] as? Int == offset,
                      let encoded = packet["data"] as? String, encoded.count <= Self.chunkSize * 2,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= Self.chunkSize,
                      offset + bytes.count <= total, let handle else { throw TransferError.invalid("Invalid, oversized or out-of-order chunk") }
                try handle.write(contentsOf: bytes); digest.update(data: bytes); offset += bytes.count
                update("receiving", "Receiving encrypted sample")
                send(["kind": "ack", "offset": offset])
            case "end":
                guard !sending, phase == "receiving", offset == total, let partial else { throw TransferError.invalid("Incomplete sample") }
                let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == checksum else { throw TransferError.invalid("Checksum mismatch; partial sample discarded") }
                try handle?.synchronize(); try handle?.close(); handle = nil
                let ready = directory.appendingPathComponent(id + ".mp4")
                try FileManager.default.moveItem(at: partial, to: ready); self.partial = nil; completed = ready
                timer?.cancel(); timer = nil; update("ready", "Complete sample verified; ready to play")
                onSend?(id, ["kind": "complete", "bytes": total, "sha256": actual])
            case "complete":
                guard sending, phase == "finishing", packet["bytes"] as? Int == total, packet["sha256"] as? String == checksum else { throw TransferError.invalid("Invalid completion receipt") }
                timer?.cancel(); timer = nil; update("complete", "Host verified the complete sample")
            default: throw TransferError.invalid("Unknown transfer message")
            }
        } catch { fail(error.localizedDescription) }
    }
}
