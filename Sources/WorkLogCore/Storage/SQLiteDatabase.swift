import Foundation
import CSQLite

/// SQLite 값. 모든 SQL은 바인딩을 사용하며 문자열 결합으로 값을 넣지 않는다.
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension WorkDate: SQLBindable { public var sqlValue: SQLValue { .text(iso) } }
/// Date는 ISO8601(UTC, 밀리초) 문자열로 저장한다. 문자열 정렬 = 시간 정렬.
extension Date: SQLBindable { public var sqlValue: SQLValue { .text(SQLDate.format(self)) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self.map { $0.sqlValue } ?? .null }
}
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }

public enum SQLDate {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// 조회 결과 한 행. 컬럼 이름으로 접근한다.
public struct SQLRow: Sendable {
    public let columns: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name] ?? .null }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        default: return nil
        }
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        if case .text(let s) = self[name] { return Data(s.utf8) }
        return nil
    }
    public func date(_ name: String) -> Date? { string(name).flatMap(SQLDate.parse) }
    public func workDate(_ name: String) -> WorkDate? { string(name).flatMap { WorkDate($0) } }
}

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// 얇은 SQLite 연결 래퍼. 하나의 연결을 직렬 큐로 보호한다.
public final class SQLiteDatabase: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// path가 ":memory:"이면 메모리 DB.
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        if !readOnly {
            try execute("PRAGMA foreign_keys = ON")
            if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
        }
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle { sqlite3_close_v2(h); handle = nil }
    }

    var rawHandle: OpaquePointer? { handle }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    /// 여러 문장을 실행(파라미터 없음). migration DDL에 사용.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    /// 단일 문장 실행(INSERT/UPDATE/DELETE). 변경된 행 수를 반환.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLBindable] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var cols: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: cols[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: cols[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: cols[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if n > 0, let p = sqlite3_column_blob(stmt, i) { cols[name] = .blob(Data(bytes: p, count: n)) }
                    else { cols[name] = .blob(Data()) }
                default: cols[name] = .null
                }
            }
            rows.append(SQLRow(columns: cols))
        }
        return rows
    }

    public func queryOne(_ sql: String, _ params: [SQLBindable] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        guard let row = try queryOne(sql, params), let v = row.columns.values.first else { return 0 }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    /// 트랜잭션. 블록이 throw하면 롤백한다. 중첩 호출은 SAVEPOINT로 처리.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE SAVEPOINT \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO SAVEPOINT \(name)")
            try? execute("RELEASE SAVEPOINT \(name)")
            throw error
        }
    }

    /// 실행 중에도 일관된 snapshot을 dest 경로에 만든다 (SQLite Online Backup API).
    public func backup(to destinationPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        var dest: OpaquePointer?
        let rc = sqlite3_open_v2(destinationPath, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let dest else { sqlite3_close(dest); throw SQLiteError(code: rc, message: "backup open failed") }
        defer { sqlite3_close(dest) }
        guard let b = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw SQLiteError(code: sqlite3_errcode(dest), message: String(cString: sqlite3_errmsg(dest)))
        }
        let step = sqlite3_backup_step(b, -1)
        let fin = sqlite3_backup_finish(b)
        guard step == SQLITE_DONE, fin == SQLITE_OK else {
            throw SQLiteError(code: step == SQLITE_DONE ? fin : step, message: "backup step failed")
        }
    }

    /// PRAGMA integrity_check 결과가 "ok"인지.
    public func integrityCheck() throws -> Bool {
        try query("PRAGMA integrity_check").first?.string("integrity_check") == "ok"
    }

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    /// 이 SQLite 빌드가 FTS5 trigram tokenizer를 지원하는지.
    public func supportsFTS5Trigram() -> Bool {
        do {
            try execute("CREATE VIRTUAL TABLE temp.__fts_probe USING fts5(x, tokenize='trigram')")
            try execute("DROP TABLE temp.__fts_probe")
            return true
        } catch { return false }
    }

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch p.sqlValue {
            case .null: brc = sqlite3_bind_null(stmt, idx)
            case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): brc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): brc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                brc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), transient)
                }
            }
            if brc != SQLITE_OK { sqlite3_finalize(stmt); throw error(brc) }
        }
        return stmt
    }
}

/// 순서가 있는 migration. 실패하면 롤백되고 user_version은 바뀌지 않는다.
public struct Migration: Sendable {
    public let version: Int
    public let sql: String
    public init(version: Int, sql: String) { self.version = version; self.sql = sql }
}

public enum Migrator {
    /// 아직 적용하지 않은 migration을 순서대로 적용한다.
    /// beforeMigrate는 실제로 적용할 migration이 있을 때 한 번 호출된다(예: 마이그레이션 직전 백업).
    public static func migrate(_ db: SQLiteDatabase, migrations: [Migration],
                               beforeMigrate: ((Int, Int) throws -> Void)? = nil) throws {
        let current = db.userVersion
        let pending = migrations.filter { $0.version > current }.sorted { $0.version < $1.version }
        guard let target = pending.last?.version else { return }
        try beforeMigrate?(current, target)
        for m in pending {
            try db.transaction {
                try db.execute(m.sql)
                try db.setUserVersion(m.version)
            }
        }
    }
}
