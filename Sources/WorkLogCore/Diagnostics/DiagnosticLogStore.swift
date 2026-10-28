import Foundation

/// Private, bounded JSONL storage. Recording failures never interrupt app operations.
/// One store instance is shared by all app subsystems. The lock also serializes pruning and exports.
public final class DiagnosticLogStore: @unchecked Sendable {
    private let directory: URL
    private let clock: any Clock
    private let policy: DiagnosticRetentionPolicy
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var droppedEventCount = 0
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, clock: any Clock = SystemClock(),
                policy: DiagnosticRetentionPolicy = .default) {
        self.directory = directory.standardizedFileURL
        self.clock = clock
        self.policy = policy
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = maintenance()
    }

    @discardableResult
    public func record(_ event: DiagnosticEvent, category: DiagnosticCategory,
                       level: DiagnosticLevel = .info,
                       fields: [DiagnosticField: DiagnosticValue] = [:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let now = clock.now()
            try prepareDirectory()
            var files = try prune(now: now)
            let entry = DiagnosticEntry(timestamp: now, category: category, event: event,
                                        level: level, fields: fields)
            var line = try encoder.encode(entry)
            line.append(0x0A)
            guard line.count <= policy.maximumFileBytes else { throw DiagnosticLogError.unavailable }
            let target: URL
            if let last = files.last, last.started <= now,
               last.bytes + line.count + 1 <= policy.maximumFileBytes {
                target = last.url
                try validateFile(target)
                // A process interruption may leave the last row incomplete. Isolate it so the next
                // valid event remains readable, without interpreting or copying the partial payload.
                let reader = try FileHandle(forReadingFrom: target)
                defer { try? reader.close() }
                var needsSeparator = false
                if last.bytes > 0 {
                    try reader.seek(toOffset: UInt64(last.bytes - 1))
                    needsSeparator = try reader.read(upToCount: 1)?.first != 0x0A
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if needsSeparator { try handle.write(contentsOf: Data([0x0A])) }
                try handle.write(contentsOf: line)
            } else {
                target = try nextFileURL(now: now)
                guard fileManager.createFile(atPath: target.path, contents: line,
                                             attributes: [.posixPermissions: 0o600]) else {
                    throw DiagnosticLogError.unavailable
                }
            }
            files = try ownedFiles()
            try enforceTotalLimit(files)
            return true
        } catch {
            droppedEventCount += 1
            return false
        }
    }

    @discardableResult
    public func maintenance() -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try prepareDirectory()
            _ = try prune(now: clock.now())
            return true
        } catch { return false }
    }

    public func status() -> DiagnosticLogStatus {
        lock.lock(); defer { lock.unlock() }
        do {
            try prepareDirectory()
            let now = clock.now()
            let files = try prune(now: now)
            let count = try files.reduce(0) { try $0 + entries(in: $1, now: now).count }
            return DiagnosticLogStatus(fileCount: files.count, byteCount: files.reduce(0) { $0 + $1.bytes },
                                       eventCount: count, retentionDays: policy.retentionDays,
                                       droppedEventCount: droppedEventCount, storageAvailable: true)
        } catch {
            return DiagnosticLogStatus(fileCount: 0, byteCount: 0, eventCount: 0,
                                       retentionDays: policy.retentionDays,
                                       droppedEventCount: droppedEventCount, storageAvailable: false)
        }
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        for file in try ownedFiles() { try fileManager.removeItem(at: file.url) }
        droppedEventCount = 0
    }

    /// Returns one sanitized JSON document; caller explicitly chooses where to save it.
    /// We decode and re-encode known fields, never attach raw files or traverse other app storage.
    public func exportReport(metadata: DiagnosticReportMetadata) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        let now = clock.now()
        let files = try prune(now: now)
        let events = try files.flatMap { try entries(in: $0, now: now) }.sorted { $0.timestamp < $1.timestamp }
        let report = DiagnosticReport(schemaVersion: 1, generatedAt: now, metadata: metadata,
                                      retentionDays: policy.retentionDays,
                                      droppedEventCount: droppedEventCount, events: events)
        return try encoder.encode(report)
    }

    private struct LogFile {
        let url: URL
        let bytes: Int
        let started: Date
    }

    private func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            // A dangling link must not be replaced or traversed.
            if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                throw DiagnosticLogError.unsafeDirectory
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw DiagnosticLogError.unsafeDirectory
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func validateFile(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw DiagnosticLogError.unsafeFile
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func ownedFiles() throws -> [LogFile] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            guard let started = Self.startDate(for: url.lastPathComponent) else { return nil }
            // Skip links, directories, and hard links rather than collecting or mutating their targets.
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                  let bytes = (attributes[.size] as? NSNumber)?.intValue else { return nil }
            return LogFile(url: url, bytes: bytes, started: started)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private static func startDate(for name: String) -> Date? {
        // Exact names owned by this store only: no recursion, arbitrary JSONL, or report attachments.
        let parts = name.split(separator: "-")
        guard parts.count == 3, parts[0] == "events", parts[1].count == 20,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              parts[2].hasSuffix(".jsonl") else { return nil }
        let sequence = parts[2].dropLast(6)
        guard sequence.count == 6, sequence.utf8.allSatisfy({ (48...57).contains($0) }),
              let milliseconds = Double(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private func nextFileURL(now: Date) throws -> URL {
        let timestamp = now.timeIntervalSince1970 * 1000
        guard timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max) else {
            throw DiagnosticLogError.unavailable
        }
        let prefix = String(format: "events-%020lld", Int64(timestamp))
        for sequence in 0..<1_000_000 {
            let url = directory.appendingPathComponent(prefix + String(format: "-%06d.jsonl", sequence))
            if (try? fileManager.attributesOfItem(atPath: url.path)) == nil { return url }
        }
        throw DiagnosticLogError.unavailable
    }

    private func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
    }

    private func entries(in file: LogFile, now: Date) throws -> [DiagnosticEntry] {
        guard file.bytes <= policy.maximumFileBytes else { return [] }
        try validateFile(file.url)
        let data = try Data(contentsOf: file.url)
        guard data.count <= policy.maximumFileBytes else { return [] }
        let minimum = cutoff(now: now)
        return data.split(separator: 0x0A).compactMap { line in
            guard let entry = try? decoder.decode(DiagnosticEntry.self, from: Data(line)),
                  entry.timestamp > minimum, entry.timestamp <= now else { return nil }
            return entry
        }
    }

    private func prune(now: Date) throws -> [LogFile] {
        for file in try ownedFiles() {
            if file.bytes > policy.maximumFileBytes {
                try fileManager.removeItem(at: file.url)
            } else if file.started <= cutoff(now: now) {
                // A file can contain entries on both sides of the boundary. Retain only unexpired rows.
                let retained = try entries(in: file, now: now)
                if retained.isEmpty { try fileManager.removeItem(at: file.url) }
                else {
                    var data = Data()
                    for entry in retained { data.append(try encoder.encode(entry)); data.append(0x0A) }
                    try validateFile(file.url)
                    try data.write(to: file.url, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
                }
            }
        }
        try enforceTotalLimit(ownedFiles())
        return try ownedFiles()
    }

    private func enforceTotalLimit(_ files: [LogFile]) throws {
        var bytes = files.reduce(0) { $0 + $1.bytes }
        for file in files where bytes > policy.maximumTotalBytes {
            try fileManager.removeItem(at: file.url)
            bytes -= file.bytes
        }
    }
}
