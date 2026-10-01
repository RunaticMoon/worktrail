import Foundation

/// 일반 업무 원문(work.sqlite)의 영속화. Secret 평문을 다루지 않는다.
/// 기능별 메서드는 WorkRepository+*.swift 확장에 둔다.
public final class WorkRepository: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let clock: Clock
    public let ids: IDGenerator
    public let calendar: WorkCalendar

    /// 원문이 바뀌면 호출된다 (검색 인덱스 갱신·초안 캐시 무효화). (sourceType, sourceId)
    public var onSourceChanged: ((String, String) -> Void)?

    public init(db: SQLiteDatabase, clock: Clock = SystemClock(), ids: IDGenerator = UUIDGenerator(),
                calendar: WorkCalendar = WorkCalendar()) throws {
        self.db = db; self.clock = clock; self.ids = ids; self.calendar = calendar
        try Migrator.migrate(db, migrations: WorkSchema.migrations)
    }

    /// 테스트용 메모리 저장소
    public static func inMemory(clock: Clock = SystemClock(), ids: IDGenerator = UUIDGenerator(),
                                calendar: WorkCalendar = WorkCalendar()) throws -> WorkRepository {
        try WorkRepository(db: SQLiteDatabase(path: ":memory:"), clock: clock, ids: ids, calendar: calendar)
    }
}
