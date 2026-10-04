import Foundation

struct PairingCode: Codable {
    let kind: String
    let version: Int
    let address: String
    let port: Int
    let secret: String

    static func validAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ part in Int(part).map { (0...255).contains($0) && String($0) == part } ?? false }) else { return false }
        let values = parts.map { Int($0)! }
        return values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1])) ||
            (values[0] == 192 && values[1] == 168) || (values[0] == 169 && values[1] == 254)
    }
    var valid: Bool {
        kind == "cricket-replay-pairing" && version == 1 && Self.validAddress(address) &&
            (1024...65535).contains(port) && LocalSession.validSecret(secret)
    }
    static func decode(_ text: String) -> PairingCode? {
        guard text.utf8.count <= 1024, let code = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), code.valid else { return nil }
        return code
    }
    var result: [String: Any] { ["address": address, "port": port, "secret": secret] }
}
