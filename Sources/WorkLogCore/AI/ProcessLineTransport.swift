import Foundation

// Foundation Process로 자식 실행 파일을 띄워 stdio로 줄 단위 JSON-RPC를 주고받는 전송.
// stdout = 프로토콜(줄 단위 JSON), stderr = 진단(줄 수만 보관, 내용은 저장하지 않음).
// Linux·macOS 공통으로 동작해야 한다.

/// 전송 쓰기 실패 이유.
public enum LineTransportError: Error, Equatable, Sendable {
    case notRunning
    case writeFailed(String)
}

public final class ProcessLineTransport: LineTransport, @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let currentDirectoryURL: URL?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var _stderrLineCount = 0
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var onLine: (@Sendable (String) -> Void)?
    private var onClose: (@Sendable (TransportCloseReason) -> Void)?
    private var didClose = false

    public init(executableURL: URL,
                arguments: [String],
                environment: [String: String]? = nil,
                currentDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    /// 수신한 stderr 줄 수 (내용은 저장하지 않음).
    public var stderrLineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stderrLineCount
    }

    public func start(onLine: @escaping @Sendable (String) -> Void,
                      onClose: @escaping @Sendable (TransportCloseReason) -> Void) throws {
        lock.lock()
        self.onLine = onLine
        self.onClose = onClose
        lock.unlock()

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            self?.emitClose(.exited(proc.terminationStatus))
        }

        try process.run()
    }

    public func send(line: String) throws {
        lock.lock()
        let closed = didClose
        lock.unlock()
        if closed { throw LineTransportError.notRunning }
        guard process.isRunning else { throw LineTransportError.notRunning }
        let data = Data((line + "\n").utf8)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw LineTransportError.writeFailed(String(describing: error))
        }
    }

    public func close() {
        lock.lock()
        let alreadyClosed = didClose
        lock.unlock()
        if process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
        if !alreadyClosed {
            emitClose(.closedByClient)
        }
    }

    // MARK: - 수신 버퍼링

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else {
            flushStdoutBuffer()
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        stdoutBuffer += text
        var lines: [String] = []
        while let index = stdoutBuffer.firstIndex(of: "\n") {
            var line = String(stdoutBuffer[stdoutBuffer.startIndex..<index])
            stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: index)...])
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
        }
        let handler = self.onLine
        lock.unlock()

        for line in lines { handler?(line) }
    }

    private func flushStdoutBuffer() {
        lock.lock()
        let remaining = stdoutBuffer
        stdoutBuffer = ""
        let handler = self.onLine
        lock.unlock()
        guard !remaining.isEmpty else { return }
        var line = remaining
        if line.hasSuffix("\r") { line.removeLast() }
        handler?(line)
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        stderrBuffer += text
        var count = 0
        while let index = stderrBuffer.firstIndex(of: "\n") {
            stderrBuffer = String(stderrBuffer[stderrBuffer.index(after: index)...])
            count += 1
        }
        _stderrLineCount += count
        lock.unlock()
    }

    private func emitClose(_ reason: TransportCloseReason) {
        lock.lock()
        if didClose {
            lock.unlock()
            return
        }
        didClose = true
        let handler = onClose
        lock.unlock()
        handler?(reason)
    }
}
