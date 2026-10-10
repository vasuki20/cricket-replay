import Foundation
@main struct TransferBenchmark {
 static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("burst-benchmark-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("fixture.bin")
  try Data(repeating: 0x5a, count: 10_000_123).write(to: file)
  var times: [Double] = []
  for window in [1, 8, 32] {
   let q = DispatchQueue(label: "benchmark")
   let sender = SampleTransfer(queue: q, directory: root.appendingPathComponent("sender-\(window)"))
   let receiver = SampleTransfer(queue: q, directory: root.appendingPathComponent("receiver-\(window)"))
   let secret = LocalSession.newSecret()
   let a = SessionAuthentication(secret: secret, role: "camera"), b = SessionAuthentication(secret: secret, role: "host")
   precondition(a.acceptHello(b.hello()) && b.acceptHello(a.hello()))
   let done = DispatchSemaphore(value: 0)
   var failure: String?, acknowledgements = 0
   sender.onFailure = { failure = $0; done.signal() }; receiver.onFailure = { failure = $0; done.signal() }
   func route(_ id: String, _ original: [String: Any], _ from: SessionAuthentication, _ to: SessionAuthentication, _ engine: SampleTransfer, _ host: Bool) {
    do {
     var packet = original
     if packet["kind"] as? String == "offer" {
      if window == 1 { packet.removeValue(forKey: "windowChunks"); packet.removeValue(forKey: "maxWindowChunks") } else { packet["windowChunks"] = 8; packet["maxWindowChunks"] = window }
     }
     if window == 1 && packet["kind"] as? String == "ack" { packet.removeValue(forKey: "windowChunks") }
     if packet["kind"] as? String == "ack" { acknowledgements += 1 }
     let encrypted = try from.encrypt(packet, id: id)
     let signed = from.signed(type: "transfer", id: id, payload: encrypted)!
     q.asyncAfter(deadline: .now() + 0.01) {
      do { precondition(to.verify(signed)); engine.receive(id: id, packet: try to.decrypt(encrypted, id: id), isHost: host) }
      catch { failure = error.localizedDescription; done.signal() }
     }
    } catch { failure = error.localizedDescription; done.signal() }
   }
   sender.onSend = { route($0, $1, a, b, receiver, true) }
   receiver.onSend = { route($0, $1, b, a, sender, false) }
   sender.onChange = { if $0["state"] as? String == "complete" { done.signal() } }
   q.async { do { try sender.begin(file) } catch { failure = error.localizedDescription; done.signal() } }
   precondition(done.wait(timeout: .now() + 60) == .success, "benchmark timeout")
   q.sync {
    precondition(failure == nil, failure ?? "failure")
    precondition(receiver.state["checksumVerified"] as? Bool == true)
    precondition(try! Data(contentsOf: receiver.completed!) == Data(contentsOf: file))
    let duration = receiver.state["durationSeconds"] as! Double; times.append(duration)
    print("window=\(window) bytes=10000123 acknowledgements=\(acknowledgements) seconds=\(duration) dataMs=\(receiver.state["dataMs"]!) verificationMs=\(receiver.state["verificationMs"]!)")
   }
  }
  precondition(times[1] < times[0] * 0.5, "burst must improve controlled-RTT transfer")
  print("PASS: encrypted exact-byte 10 MB benchmark, 20ms simulated RTT, speedup=\(times[0] / times[2])x; not phone throughput")
 }
}
