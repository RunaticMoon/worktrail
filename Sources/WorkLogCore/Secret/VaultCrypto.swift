import Foundation
import Crypto

/// Secret 본문 암호화. 직접 만든 알고리즘이 아니라 swift-crypto의 AES-GCM만 사용한다.
/// Apple 플랫폼에서는 CryptoKit을 그대로 재노출한다.
/// 이 파일은 값·키를 로그로 남기지 않는다.
public enum VaultCrypto {
    /// 256비트 무작위 키.
    public static func generateKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    /// AES.GCM.seal. 매번 무작위 nonce. combined 형식(nonce + ciphertext + tag)을 반환한다.
    public static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw WorkLogError.integrity("Secret 암호화에 실패했습니다.")
        }
        return combined
    }

    /// 복호화. 변조·AAD 불일치·키 불일치면 WorkLogError.integrity. 부분 평문은 반환하지 않는다.
    public static func open(_ combined: Data, key: Data, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw WorkLogError.integrity("Secret 암호문을 확인할 수 없습니다.")
        }
    }

    /// revision AAD. secret ID·revision ID·version·schema를 암호문에 바인딩한다.
    public static func aad(secretId: String, revisionId: String, version: Int, schemaVersion: Int) -> Data {
        Data("worklog.secret|v\(schemaVersion)|\(secretId)|\(revisionId)|\(version)".utf8)
    }
}
