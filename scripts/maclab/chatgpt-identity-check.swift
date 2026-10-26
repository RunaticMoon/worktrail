import Foundation
import Security

@main struct ChatGPTIdentityCheck {
    static func main() throws {
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                     kSecAttrKeySizeInBits as String: 2048,
                                     kSecAttrIsPermanent as String: false]
        guard let privateKey = SecKeyCreateRandomKey(options as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let exported = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { fatalError("Fixture key creation failed") }
        var outerOffset = 0
        let sequence = try readDER(Array(exported), offset: &outerOffset, tag: 0x30)
        var offset = 0
        let modulus = try readDER(sequence, offset: &offset, tag: 0x02)
        let exponent = try readDER(sequence, offset: &offset, tag: 0x02)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "fake-key", "kty": "RSA", "alg": "RS256",
            "n": base64(Data(modulus.drop(while: { $0 == 0 }))), "e": base64(Data(exponent))]]])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let baseClaims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp-fake", "sub": "fake-subject",
                                        "nonce": "fake-nonce", "exp": now.timeIntervalSince1970 + 3600]
        func signed(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fake-key"])
            let payload = try JSONSerialization.data(withJSONObject: claims)
            let text = base64(header) + "." + base64(payload)
            guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(text.utf8) as CFData, nil) else { fatalError("Fixture signing failed") }
            return text + "." + base64(signature as Data)
        }
        func validate(_ token: String) throws -> (subject: String, email: String?) {
            try ChatGPTLoginIdentity.validate(idToken: token, jwks: jwks, clientID: "oaiapp-fake", nonce: "fake-nonce", now: now)
        }
        let token = try signed(baseClaims)
        guard try validate(token).subject == "fake-subject" else { fatalError("Valid identity rejected") }
        print("PASS: valid RSA-signed identity")
        let wrongs: [(String, Any)] = [("iss", "https://example.invalid"), ("aud", "other-client"),
                                      ("nonce", "other-nonce"), ("exp", now.timeIntervalSince1970 - 1),
                                      ("nbf", now.timeIntervalSince1970 + 3600)]
        for (field, value) in wrongs {
            var claims = baseClaims; claims[field] = value
            do { _ = try validate(signed(claims)); fatalError("Invalid \(field) accepted") }
            catch { print("PASS: invalid \(field) rejected") }
        }
        var parts = token.split(separator: ".").map(String.init)
        var tampered = baseClaims; tampered["sub"] = "tampered"
        parts[1] = base64(try JSONSerialization.data(withJSONObject: tampered))
        do { _ = try validate(parts.joined(separator: ".")); fatalError("Invalid signature accepted") }
        catch { print("PASS: tampered signature rejected") }
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    enum FixtureError: Error { case malformed }
    static func readDER(_ data: [UInt8], offset: inout Int, tag: UInt8) throws -> [UInt8] {
        guard offset + 2 <= data.count, data[offset] == tag else { throw FixtureError.malformed }
        offset += 1
        var length = Int(data[offset]); offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f; length = 0
            guard count <= 4, offset + count <= data.count else { throw FixtureError.malformed }
            for _ in 0..<count { length = (length << 8) | Int(data[offset]); offset += 1 }
        }
        guard offset + length <= data.count else { throw FixtureError.malformed }
        defer { offset += length }
        return Array(data[offset ..< offset + length])
    }
}
