import Foundation
import CryptoKit
import CoreFoundation

enum TransferError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

// All operations run on LocalSession's serial queue. Negotiated bursts of at most 32 ordered chunks in flight.
final class SampleTransfer {
    static let chunkSize = 16 * 1024
    static let maxBytes = 32 * 1024 * 1024
    private let queue: DispatchQueue
    private let directory: URL
    private let availableBytes: (URL) throws -> Int
    private var handle: FileHandle?
    private var partial: URL?
    private(set) var completed: URL?
    private var id = ""
    private var total = 0
    private var window = 1
    private var chunksSinceAck = 0
    private var dataMs = 0.0
    private var verificationMs = 0.0
    private var hashMs = 0.0
    private var offset = 0
    private var checksum = ""
    private var digest = SHA256()
    private var started = 0.0
    private var timer: DispatchWorkItem?
    private var sending = false
    private var slow = false
    private var phase = "idle"
    private var media = "sample"
    private(set) var recording: [String: Any]?
    private var reviewID = ""
    var acceptOffer: ((String, String) throws -> Void)?
    var validateRecording: ((URL, [String: Any]) throws -> Void)?
    // Only explicit, bounded integer timing fields are accepted across platforms.
    static func recordingMetadata(_ input: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["sourceFirstUs", "sourceLastUs", "requestedHostUs", "requestedSourceUs", "endpointErrorUs", "frames", "retentionSeconds", "reviewSeconds"] {
            guard let value = input[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  abs(value.doubleValue) <= 9_007_199_254_740_991 else { throw TransferError.invalid("Invalid recording timing field: \(key)") }
            result[key] = value.int64Value
        }
        func n(_ key: String) -> Int64 { result[key] as! Int64 }
        guard n("sourceFirstUs") >= 0, n("sourceLastUs") > n("sourceFirstUs"),
              n("requestedHostUs") >= 0, n("requestedSourceUs") >= 0,
              n("endpointErrorUs") == n("sourceLastUs") - n("requestedSourceUs"),
              (-100_000...0).contains(n("endpointErrorUs")), (2...10000).contains(n("frames")),
              (30...180).contains(n("retentionSeconds")), (5...30).contains(n("reviewSeconds")),
              n("reviewSeconds") <= n("retentionSeconds") - 10,
              n("sourceLastUs") - n("sourceFirstUs") >= n("reviewSeconds") * 1_000_000 - 100_000,
              n("sourceLastUs") - n("sourceFirstUs") <= (n("reviewSeconds") + 5) * 1_000_000 else {
            throw TransferError.invalid("Unavailable/partial review window or inconsistent recording metadata")
        }
        return result
    }
    private var history: [[String: Any]] = []
    private(set) var state: [String: Any] = ["state": "idle", "bytes": 0, "totalBytes": 0, "checksumVerified": false]
    var onSend: ((String, [String: Any]) -> Void)?
    var onChange: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var active: Bool { ["offer", "sending", "receiving", "finishing"].contains(phase) }

    init(queue: DispatchQueue, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-transfer-" + UUID().uuidString), availableBytes: @escaping (URL) throws -> Int = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0 }) {
        self.queue = queue; self.directory = directory; self.availableBytes = availableBytes
        // No recovery of killed transfers: stale partial/ready files never restore a ready state.
        try? FileManager.default.removeItem(at: directory)
    }
    static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: chunkSize), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func update(_ phase: String, _ detail: String) {
        self.phase = phase
        let description = media == "recording" ? detail.replacingOccurrences(of: "sample", with: "recording clip") : detail
        state = ["state": phase, "detail": description, "requestId": id, "bytes": offset, "totalBytes": total,
                 "sha256": checksum, "checksumVerified": phase == "ready" || phase == "complete", "attempts": history]
        state["media"] = media
        if let recording { state["recording"] = recording; state["reviewId"] = reviewID }
        if phase == "ready" || phase == "complete" {
            let seconds = max(ProcessInfo.processInfo.systemUptime - started, 0.000001)
            state["durationSeconds"] = seconds; state["throughputMBps"] = Double(total) / seconds / 1_000_000
            var result = state; result.removeValue(forKey: "attempts")
            history.append(result); history = Array(history.suffix(10)); state["attempts"] = history.filter { $0["media"] as? String == media }
        }
        state["media"] = media
        if let recording { state["recording"] = recording; state["reviewId"] = reviewID }
        state["windowChunks"] = window; state["dataMs"] = dataMs; state["verificationMs"] = verificationMs; state["hashMs"] = hashMs
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
        completed = nil; recording = nil; media = "sample"; reviewID = ""; history = []; id = ""; offset = 0; total = 0; checksum = ""
        update("idle", "Temporary received files removed")
    }
    private func prepare() throws {
        guard !active else { throw TransferError.invalid("A transfer is already active") }
        clearPartial()
        if let completed { try FileManager.default.removeItem(at: completed) }; completed = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window = 1; chunksSinceAck = 0; dataMs = 0; verificationMs = 0; hashMs = 0
        offset = 0; digest = SHA256(); started = ProcessInfo.processInfo.systemUptime
    }
    func begin(_ url: URL, slow: Bool = false, recording info: [String: Any]? = nil, reviewId: String = "") throws {
        guard !active else { throw TransferError.invalid("A transfer is already active") }
        let metadata = try info.map { try Self.recordingMetadata($0) }
        if metadata != nil, UUID(uuidString: reviewId) == nil { throw TransferError.invalid("Invalid review ID") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maxBytes else { throw TransferError.invalid("Sample must be 1–32 MiB") }
        let hashStart = ProcessInfo.processInfo.systemUptime
        let hash = try Self.checksum(url)
        let hashElapsed = (ProcessInfo.processInfo.systemUptime - hashStart) * 1000
        try prepare(); hashMs = hashElapsed; id = UUID().uuidString.lowercased(); total = size; checksum = hash; sending = true; self.slow = slow
        recording = metadata; media = metadata == nil ? "sample" : "recording"; reviewID = reviewId
        handle = try FileHandle(forReadingFrom: url)
        update("offer", "Waiting for host to accept sample")
        var offer: [String: Any] = ["kind": "offer", "windowChunks": slow ? 1 : 8, "maxWindowChunks": slow ? 1 : 32, "bytes": total, "sha256": checksum, "media": media]
        if let recording { offer["recording"] = recording; offer["reviewId"] = reviewID }
        send(offer)
    }
    private func fail(_ message: String) { clearPartial(); update("failed", message); onFailure?(message) }
    func receive(id incomingID: String, packet: [String: Any], isHost: Bool) {
        do {
            guard UUID(uuidString: incomingID) != nil, let kind = packet["kind"] as? String else { throw TransferError.invalid("Invalid transfer message") }
            if kind == "offer" {
                guard isHost, let bytes = packet["bytes"] as? Int, (1...Self.maxBytes).contains(bytes),
                      let hash = packet["sha256"] as? String, hash.count == 64,
                      hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw TransferError.invalid("Invalid sample offer") }
                let offeredMedia = packet["media"] as? String ?? "sample"
                guard ["sample", "recording"].contains(offeredMedia) else { throw TransferError.invalid("Unknown media kind") }
                let offeredID = packet["reviewId"] as? String ?? ""
                let metadata: [String: Any]?
                if offeredMedia == "recording" {
                    guard UUID(uuidString: offeredID) != nil, let input = packet["recording"] as? [String: Any], validateRecording != nil else { throw TransferError.invalid("Recording validation unavailable") }
                    metadata = try Self.recordingMetadata(input)
                } else { metadata = nil }
                try acceptOffer?(offeredMedia, offeredID)
                try prepare(); window = packet["windowChunks"] as? Int == 8 ? (packet["maxWindowChunks"] as? Int == 32 ? 32 : 8) : 1; recording = metadata; media = offeredMedia; reviewID = offeredID; id = incomingID; total = bytes; checksum = hash; sending = false; slow = false
                let path = directory.appendingPathComponent(id + ".part.mp4")
                guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw TransferError.invalid("Cannot create partial file") }
                partial = path
                let free = try availableBytes(directory)
                guard free >= total + 64 * 1024 * 1024 else { throw TransferError.invalid("Low storage; review transfer unavailable") }
                handle = try FileHandle(forWritingTo: path)
                update("receiving", "Receiving encrypted sample")
                send(["kind": "ack", "offset": 0, "windowChunks": window]); return
            }
            guard active, incomingID == id else { throw TransferError.invalid("Unexpected transfer/request ID") }
            switch kind {
            case "ack":
                guard sending, ["offer", "sending"].contains(phase), packet["offset"] as? Int == offset else { throw TransferError.invalid("Invalid chunk acknowledgement") }
                if phase == "offer" { window = !slow && [8, 32].contains(packet["windowChunks"] as? Int ?? 1) ? (packet["windowChunks"] as? Int ?? 1) : 1 }
                if offset == total {
                    dataMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    try handle?.close(); handle = nil; update("finishing", "Waiting for host checksum verification")
                    send(["kind": "end"])
                } else {
                    for _ in 0..<window {
                        if offset < total {
                            guard let bytes = try handle?.read(upToCount: min(Self.chunkSize, total - offset)), !bytes.isEmpty else { throw TransferError.invalid("Sample read failed") }
                            let start = offset; offset += bytes.count
                            update("sending", "Sending encrypted sample")
                            send(["kind": "chunk", "offset": start, "data": bytes.base64EncodedString()])
                        }
                    }
                }
            case "chunk":
                guard !sending, phase == "receiving", packet["offset"] as? Int == offset,
                      let encoded = packet["data"] as? String, encoded.count <= Self.chunkSize * 2,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= Self.chunkSize,
                      offset + bytes.count <= total, let handle else { throw TransferError.invalid("Invalid, oversized or out-of-order chunk") }
                try handle.write(contentsOf: bytes); digest.update(data: bytes); offset += bytes.count
                update("receiving", "Receiving encrypted sample")
                chunksSinceAck += 1
                if chunksSinceAck == window || offset == total {
                    chunksSinceAck = 0
                    if offset == total { dataMs = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                    send(["kind": "ack", "offset": offset])
                }
            case "end":
                guard !sending, phase == "receiving", offset == total, let partial else { throw TransferError.invalid("Incomplete sample") }
                let verifyStart = ProcessInfo.processInfo.systemUptime
                let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == checksum else { throw TransferError.invalid("Checksum mismatch; partial sample discarded") }
                try handle?.synchronize(); try handle?.close(); handle = nil
                if let recording { try validateRecording?(partial, recording) }
                let ready = directory.appendingPathComponent(id + ".mp4")
                try FileManager.default.moveItem(at: partial, to: ready); self.partial = nil; completed = ready
                timer?.cancel(); timer = nil; verificationMs = (ProcessInfo.processInfo.systemUptime - verifyStart) * 1000; update("ready", "Complete sample verified; ready to play")
                onSend?(id, ["kind": "complete", "bytes": total, "sha256": actual])
            case "complete":
                guard sending, phase == "finishing", packet["bytes"] as? Int == total, packet["sha256"] as? String == checksum else { throw TransferError.invalid("Invalid completion receipt") }
                timer?.cancel(); timer = nil; update("complete", "Host verified the complete sample")
            default: throw TransferError.invalid("Unknown transfer message")
            }
        } catch { fail(error.localizedDescription) }
    }
}
