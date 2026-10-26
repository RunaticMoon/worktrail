#if os(macOS)
import Foundation
import Security

/// Pure RS256 validation, separate from credential storage and HTTP for offline fixture checks.
enum ChatGPTLoginIdentity {
    enum ValidationError: Error { case invalid }
    static func validate(idToken: String, jwks: Data, clientID: String, nonce: String, now: Date) throws -> (subject: String, email: String?) {
        let invalid = ValidationError.invalid
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let claimsData = decode(parts[1]),
              let signature = decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let document = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = document["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              (jwk["use"] as? String ?? "sig") == "sig", (jwk["alg"] as? String ?? "RS256") == "RS256",
              let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = decode(n), modulus.count >= 256, let exponent = decode(e), !exponent.isEmpty else { throw invalid }
        let keyData = der(0x30, integer(modulus) + integer(exponent))
        let options = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let key = SecKeyCreateWithData(keyData as CFData, options, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              claims["nonce"] as? String == nonce,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970 else { throw invalid }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID), audience.count == 1 || claims["azp"] as? String == clientID else { throw invalid }
        if let authorizedParty = claims["azp"] as? String, authorizedParty != clientID { throw invalid }
        if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 + 30 { throw invalid }
        return (subject, claims["email"] as? String)
    }
    private static func decode(_ text: String) -> Data? {
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    private static func integer(_ value: Data) -> Data {
        var bytes = Array(value)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return der(0x02, Data(bytes))
    }
    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count; var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 } while length > 0
        return Data([tag] + (value.count < 128 ? [UInt8(value.count)] : [0x80 | UInt8(bytes.count)] + bytes)) + value
    }
}
#endif
