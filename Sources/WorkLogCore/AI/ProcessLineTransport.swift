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
    // 종료 알림은 stdout EOF와 프로세스 종료가 모두 관찰된 뒤에 보낸다(응답 직후 종료하는 경우의 경쟁 방지).
    private var stdoutEOF = false
    private var exitStatus: Int32?
    /// 프로세스 종료 후 stdout EOF를 기다리는 최대 시간(자손 프로세스가 파이프를 붙잡는 경우 대비).
    private let eofGraceAfterExit: TimeInterval = 1.0

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
            self?.processDidExit(proc.terminationStatus)
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
            stdoutDidReachEOF()
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

    /// stdout EOF: 남은 버퍼를 전달하고, 프로세스가 이미 종료됐으면 종료를 알린다.
    /// readabilityHandler 안에서 호출되므로 이 시점까지 읽은 모든 줄은 이미 전달된 상태다.
    private func stdoutDidReachEOF() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        flushStdoutBuffer()
        lock.lock()
        stdoutEOF = true
        let status = exitStatus
        lock.unlock()
        if let status { emitClose(.exited(status)) }
    }

    private func processDidExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let eof = stdoutEOF
        lock.unlock()
        if eof {
            emitClose(.exited(status))
            return
        }
        // 자손 프로세스가 stdout을 계속 열어 두면 EOF가 오지 않으므로 유예 후 강제로 알린다.
        DispatchQueue.global().asyncAfter(deadline: .now() + eofGraceAfterExit) { [weak self] in
            self?.flushStdoutBuffer()
            self?.emitClose(.exited(status))
        }
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
