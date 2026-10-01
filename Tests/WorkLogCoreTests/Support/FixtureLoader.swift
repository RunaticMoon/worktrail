import Foundation
import WorkLogCore

/// 픽스처 로딩 실패.
enum FixtureLoaderError: Error {
    case missingResource
}

/// Tests/WorkLogCoreTests/Fixtures/example_data.json 의 가짜 값 구조를 그대로 노출한다.
/// 이후 작업이 events 외에도 projects/tasks/... 를 재사용할 수 있게 한다.
struct ExampleFixture: Decodable {
    var schemaVersion: Int?
    var fixtureOnly: Bool?
    var description: String?
    var clock: FixtureClock?
    var reportContext: FixtureReportContext?
    var projects: [FixtureProject]?
    var tasks: [FixtureTask]?
    var checklists: [FixtureChecklist]?
    var events: [FixtureEvent]?
    var sources: [FixtureSource]?
    var memoTaskLinks: [FixtureMemoTaskLink]?
    var weekPlanItems: [FixtureWeekPlanItem]?
    var evidenceSupplements: [FixtureEvidenceSupplement]?
    var secretTrimCases: [FixtureSecretTrimCase]?
    var secretAutoKeyCase: FixtureSecretAutoKeyCase?
    var secretPartialUpdateCase: FixtureSecretPartialUpdateCase?
    var pasteExamples: [FixturePasteExample]?
    var expected: FixtureExpected?
}

enum FixtureLoader {
    /// Bundle.module의 픽스처 JSON을 로드한다.
    static func load() throws -> ExampleFixture {
        guard let url = Bundle.module.url(forResource: "Fixtures/example_data", withExtension: "json") else {
            throw FixtureLoaderError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExampleFixture.self, from: data)
    }

    /// ISO8601(+09:00 포함) 문자열 → Date.
    static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// "yyyy-MM-dd" → WorkDate.
    static func workDate(_ iso: String) -> WorkDate? { WorkDate(iso) }
}

// MARK: - events → DomainEvent

extension ExampleFixture {
    /// 픽스처 events를 DomainEvent로 변환한다.
    /// kind 매핑: created→.created, started→.started, completed→.completed,
    /// project_planned→.created, project_started→.started, project_completed→.completed.
    func domainEvents() -> [DomainEvent] {
        (events ?? []).compactMap { fe in
            guard let scope = EventScopeType(rawValue: fe.scope),
                  let kind = Self.domainEventKind(fe.kind),
                  let effectiveDate = WorkDate(fe.effectiveDate),
                  let recordedAt = FixtureLoader.date(fe.recordedAt) else { return nil }

            return DomainEvent(
                id: fe.id,
                taskId: fe.taskId,
                scopeType: scope,
                scopeId: fe.scopeId,
                kind: kind,
                toStatus: fe.status.flatMap { TaskStatus(rawValue: $0) },
                effectiveDate: effectiveDate,
                effectiveTime: fe.effectiveTime.flatMap { FixtureLoader.date($0) },
                effectiveOrder: fe.effectiveOrder,
                recordedAt: recordedAt,
                supersedesEventId: fe.supersedesEventId,
                note: fe.note,
                activityId: fe.activityId
            )
        }
    }

    private static func domainEventKind(_ raw: String) -> DomainEventKind? {
        switch raw {
        case "created", "project_planned": return .created
        case "started", "project_started": return .started
        case "completed", "project_completed": return .completed
        default: return DomainEventKind(rawValue: raw)
        }
    }
}

// MARK: - events

struct FixtureEvent: Decodable {
    var id: String
    var taskId: String
    var scope: String
    var scopeId: String
    var kind: String
    var status: String?
    var effectiveDate: String
    var effectiveTime: String?
    var effectiveOrder: Int
    var recordedAt: String
    var supersedesEventId: String?
    var note: String?
    var activityId: String?
}

// MARK: - 최상위 보조 구조

struct FixtureClock: Decodable {
    var timezone: String?
    var now: String?
}

struct FixtureReportContext: Decodable {
    var previousWeekStart: String?
    var previousWeekEndExclusive: String?
    var currentWeekStart: String?
    var currentWeekEndExclusive: String?
    var pastConfirmedSnapshotAt: String?
}

struct FixtureProject: Decodable {
    var id: String?
    var name: String?
}

struct FixtureTask: Decodable {
    var id: String?
    var title: String?
    var projectIds: [String]?
    var projectTrackingMode: String?
    var dueOn: String?
}

struct FixtureChecklist: Decodable {
    var id: String?
    var taskId: String?
    var text: String?
    var projectIds: [String]?
    var done: Bool?
}

struct FixtureSource: Decodable {
    var id: String?
    var kind: String?
    var taskId: String?
    var projectIds: [String]?
    var workDate: String?
    var recordedAt: String?
    var revision: Int?
    var text: String?
    var sourceUrl: String?
    var urlBodyFetched: Bool?
}

struct FixtureMemoTaskLink: Decodable {
    var memoSourceId: String?
    var taskId: String?
    var status: String?
}

struct FixtureWeekPlanItem: Decodable {
    var id: String?
    var taskId: String?
    var scopeType: String?
    var scopeId: String?
    var text: String?
    var status: String?
}

struct FixtureEvidenceSupplement: Decodable {
    var id: String?
    var taskId: String?
    var recordedAt: String?
    var appliesStart: String?
    var appliesEndExclusive: String?
    var question: String?
    var answer: String?
    var countsAsNewActivityOnRecordedDate: Bool?
}

// MARK: - Secret 픽스처

struct FixtureKeyValue: Decodable {
    var key: String?
    var value: String?
}

struct FixtureSecretTrimCase: Decodable {
    var id: String?
    var input: FixtureKeyValue?
    var expected: FixtureKeyValue?
}

struct FixtureSecretAutoKeyCase: Decodable {
    var existingKeys: [String]?
    var input: [FixtureKeyValue]?
    var expected: [FixtureKeyValue]?
}

struct FixtureSecretRow: Decodable {
    var id: String?
    var key: String?
    var value: String?
}

struct FixtureSecretPartialUpdateCase: Decodable {
    var initialRows: [FixtureSecretRow]?
    var patch: FixtureSecretRow?
    var expectedRows: [FixtureSecretRow]?
    var expectedRevisionCountAfterOneSave: Int?
}

struct FixturePasteExample: Decodable {
    var input: String?
    var expectedKey: String?
    var expectedValue: String?
}

// MARK: - expected

struct FixtureExpected: Decodable {
    var taskStateOnSundayKnownMonday: [String: String?]?
    var taskStateOnSundayKnownSunday: [String: String?]?
    var taskStateMondayNow: [String: String?]?
    var taskAProjectStates: [String: String?]?
    var taskCDerivedStartDate: String?
    var confirmedPlanIds: [String]?
    var excludedCandidateIds: [String]?
    var uniqueTaskCountKnownMonday: Int?
    var projectAssociationCount: Int?
    var weeklySubmissionCommonTaskAppearancesPerCategory: [String: Int]?
    var secretAIRequestCount: Int?
    var secretValuesAllowedInGeneralAIInput: Bool?
    var previousConfirmedReportMustMutate: Bool?
    var linkFetchRequiredForMVP: Bool?
}
