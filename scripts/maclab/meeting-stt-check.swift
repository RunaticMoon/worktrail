// Compiled by run-meeting-stt-check.sh alongside the production STT adapter.
// Uses generated, fictional speech only. Never requests microphone access or login.
import Foundation

@main struct MeetingSTTCheck {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { fail("Expected generated fixture path") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let service = MeetingSpeechTranscriber()
        await service.refreshAvailability()
        guard service.isModelReady else {
            print("SKIP: Korean SpeechTranscriber model is not installed/supported; no model download was attempted.")
            exit(77)
        }
        do {
            let text = try await service.transcribe(fileURL: source)
            guard text.contains("회의"), text.contains("테스트"), !service.isTranscribing else {
                fail("Expected Korean meeting terms or idle state missing")
            }
            print("PASS: installed Korean model transcribes the synthetic file and returns to idle")
        } catch { fail("Synthetic file transcription: \(error.localizedDescription)") }

        do {
            _ = try await service.transcribe(fileURL: URL(string: "https://invalid.example/audio.m4a")!)
            fail("Remote audio URL accepted")
        } catch MeetingSpeechError.invalidFile {
            print("PASS: remote audio URL rejected before recognition")
        } catch { fail("Unexpected remote URL error") }

        let task = Task { try await service.transcribe(fileURL: source) }
        for _ in 0..<100 where !service.isTranscribing { await Task.yield() }
        guard service.isTranscribing else { task.cancel(); fail("Cancellation check did not enter transcription") }
        service.cancel()
        do {
            _ = try await task.value
            fail("Cancelled transcription returned content")
        } catch {
            guard !service.isTranscribing, FileManager.default.fileExists(atPath: source.path) else {
                fail("Cancellation failed to settle idle or deleted the source")
            }
            print("PASS: cancellation settles idle and preserves the source for retry")
        }
    }

    private static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }
}
