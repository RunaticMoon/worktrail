// Run only in the release signing step. Never print secret material or tool errors.
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 2,
          let encoded = ProcessInfo.processInfo.environment["WORKLOG_SPARKLE_PRIVATE_KEY"],
          let seed = Data(base64Encoded: encoded), seed.count == 32 else { throw KeyError.invalid }
    let expected = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation.base64EncodedString() == expected else { throw KeyError.invalid }
} catch {
    fputs("The dedicated update key does not match the committed public key\n", stderr)
    exit(1)
}

enum KeyError: Error { case invalid }
