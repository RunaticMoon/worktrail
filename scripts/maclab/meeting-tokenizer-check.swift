import Foundation
import WhisperKit

private enum ExpectedFailure: Error { case unexpectedlySucceeded }

@main struct TokenizerChecks {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let localHub = HubApiWrapper(downloadBase: folder, hfToken: "")
        do {
            _ = try await AutoTokenizerWrapper.from(modelFolder: folder, hubApi: localHub)
            throw ExpectedFailure.unexpectedlySucceeded
        } catch ExpectedFailure.unexpectedlySucceeded { throw ExpectedFailure.unexpectedlySucceeded }
        catch { print("PASS actual SDK local tokenizer factory rejects missing files offline") }

        try Data("not JSON".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data("not JSON".utf8).write(to: folder.appendingPathComponent("tokenizer_config.json"))
        do {
            _ = try await AutoTokenizerWrapper.from(modelFolder: folder, hubApi: localHub)
            throw ExpectedFailure.unexpectedlySucceeded
        } catch ExpectedFailure.unexpectedlySucceeded { throw ExpectedFailure.unexpectedlySucceeded }
        catch { print("PASS actual SDK local tokenizer factory rejects corrupt files offline") }

        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                      verbose: false, load: false, download: false)
        let pipeline = try await MeetingOfflineWhisperKit(config)
        do {
            try await pipeline.loadTokenizerIfNeeded()
            throw ExpectedFailure.unexpectedlySucceeded
        } catch is MeetingLocalModelError {
            print("PASS WorkLog override rejects lazy tokenizer fallback without downloading")
        }
    }
}
