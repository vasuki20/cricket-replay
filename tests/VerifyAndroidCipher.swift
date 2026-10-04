import Foundation
import CryptoKit
@main struct Verify {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  for f in fixtures {
   let role = f["role"] as! String, own = f["nonce"] as! String, hello = f["hello"] as! [String: Any], peer = hello["nonce"] as! String
   let host = role == "host" ? own : peer, camera = role == "camera" ? own : peer
   let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data((f["secret"] as! String).utf8)), salt: Data("\(host)|\(camera)".utf8), info: Data("cricket-p0-v2-aes-gcm-\(role)".utf8), outputByteCount: 32)
   let box = try AES.GCM.SealedBox(combined: Data(base64Encoded: f["androidEncrypted"] as! String)!)
   let plain = try AES.GCM.open(box, using: key, authenticating: Data((f["id"] as! String).utf8))
   let packet = try JSONSerialization.jsonObject(with: plain) as! NSDictionary
   guard packet.isEqual(to: f["packet"] as! [String: Any]) else { fatalError("Wrong decrypted packet") }
  }
  print("PASS: Android-generated ciphertext decrypts and matches expected packets in CryptoKit in both directions")
 }
}
