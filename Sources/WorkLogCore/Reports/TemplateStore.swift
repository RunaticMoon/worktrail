import Foundation

/// 업무별 프롬프트 템플릿 저장소.
///
/// - 기본값(P-00 ~ P-07)을 시드하고, 사용자 수정은 새 버전으로 남긴다(템플릿 버전은 불변).
/// - 팀 변경 문구는 복제로 분리한다.
/// - AI 호출·네트워크·Secret은 다루지 않는다.
///
/// 원본 규칙: docs/mac_worklog_ai_handoff/05_RUNTIME_PROMPTS.md §0, §1.
public final class TemplateStore {

    private let repo: WorkRepository
    private var db: SQLiteDatabase { repo.db }
    private var clock: Clock { repo.clock }
    private var ids: IDGenerator { repo.ids }

    public init(repo: WorkRepository) {
        self.repo = repo
    }

    // MARK: - 시드

    /// 없는 기본 템플릿만 version 1로 삽입하고 active로 설정한다.
    /// 이미 있는 id는 절대 덮어쓰지 않는다(사용자 수정 보존). 삽입한 템플릿 개수를 반환한다.
    @discardableResult
    public func seedDefaults() throws -> Int {
        var inserted = 0
        try db.transaction {
            for template in DefaultPrompts.all {
                if try db.queryOneV("SELECT 1 AS x FROM report_template WHERE id = ?", template.id) != nil {
                    continue
                }
                let versionId = ids.make()
                try db.runV("""
                    INSERT INTO report_template (id, purpose, name, active_version_id, archived_at)
                    VALUES (?, ?, ?, NULL, NULL)
                    """, template.id, template.purpose.rawValue, template.name)
                try insertVersion(id: versionId, templateId: template.id, version: 1,
                                  instructions: template.instructions,
                                  outputExample: template.outputExample, skillRef: nil,
                                  createdAt: clock.now())
                try db.runV("UPDATE report_template SET active_version_id = ? WHERE id = ?",
                            versionId, template.id)
                inserted += 1
            }
        }
        return inserted
    }

    // MARK: - 조회

    public func template(id: String) throws -> ReportTemplate? {
        try db.queryOneV("SELECT * FROM report_template WHERE id = ?", id).map { try templateRow($0) }
    }

    /// name, id 순. 기본은 보관되지 않은 템플릿만.
    public func templates(purpose: TemplatePurpose? = nil, includeArchived: Bool = false) throws -> [ReportTemplate] {
        var sql = "SELECT * FROM report_template WHERE 1 = 1"
        var params: [SQLBindable] = []
        if let purpose {
            sql += " AND purpose = ?"
            params.append(purpose.rawValue)
        }
        if !includeArchived {
            sql += " AND archived_at IS NULL"
        }
        sql += " ORDER BY name ASC, id ASC"
        return try db.query(sql, params).map { try templateRow($0) }
    }

    /// version 오름차순.
    public func versions(templateId: String) throws -> [TemplateVersion] {
        try db.queryV("""
            SELECT * FROM template_version WHERE template_id = ? ORDER BY version ASC
            """, templateId).map { try versionRow($0) }
    }

    public func version(id: String) throws -> TemplateVersion? {
        try db.queryOneV("SELECT * FROM template_version WHERE id = ?", id).map { try versionRow($0) }
    }

    public func activeVersion(templateId: String) throws -> TemplateVersion? {
        guard let template = try template(id: templateId), let activeId = template.activeVersionId else {
            return nil
        }
        return try version(id: activeId)
    }

    // MARK: - 쓰기

    /// 새 버전 = max(version)+1, active로 설정한다.
    /// active와 instructions·outputExample·skillRef가 모두 같으면 새 버전을 만들지 않고 active를 반환한다.
    /// instructions가 trim 후 비면 validation 오류.
    public func saveNewVersion(templateId: String, instructions: String, outputExample: String,
                               skillRef: String?) throws -> TemplateVersion {
        guard try template(id: templateId) != nil else {
            throw WorkLogError.notFound("template \(templateId)")
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkLogError.validation("템플릿 지침이 비어 있습니다.")
        }
        return try db.transaction {
            if let active = try activeVersion(templateId: templateId),
               active.instructions == instructions,
               active.outputExample == outputExample,
               active.skillRef == skillRef {
                return active
            }
            let next = try db.scalarIntV("SELECT COALESCE(MAX(version), 0) + 1 FROM template_version WHERE template_id = ?",
                                         templateId)
            let versionId = ids.make()
            try insertVersion(id: versionId, templateId: templateId, version: next,
                              instructions: instructions, outputExample: outputExample,
                              skillRef: skillRef, createdAt: clock.now())
            try db.runV("UPDATE report_template SET active_version_id = ? WHERE id = ?", versionId, templateId)
            guard let saved = try version(id: versionId) else {
                throw WorkLogError.storage("template_version \(versionId) 삽입 후 조회 실패")
            }
            return saved
        }
    }

    /// 이전 버전으로 되돌리기. 새 버전을 만들지 않고 active 포인터만 바꾼다.
    /// 다른 템플릿의 버전이면 validation 오류.
    public func setActiveVersion(templateId: String, versionId: String) throws {
        guard try template(id: templateId) != nil else {
            throw WorkLogError.notFound("template \(templateId)")
        }
        guard let target = try version(id: versionId) else {
            throw WorkLogError.notFound("template_version \(versionId)")
        }
        guard target.templateId == templateId else {
            throw WorkLogError.validation("버전 \(versionId)는 템플릿 \(templateId)의 것이 아닙니다.")
        }
        try db.transaction {
            _ = try db.runV("UPDATE report_template SET active_version_id = ? WHERE id = ?", versionId, templateId)
        }
    }

    /// 팀 변경용 복제. 새 id, 같은 purpose, 새 name, 원본 active 버전 내용을 version 1로 복사한다.
    /// 원본은 변하지 않는다.
    public func clone(templateId: String, newName: String) throws -> ReportTemplate {
        guard let source = try template(id: templateId) else {
            throw WorkLogError.notFound("template \(templateId)")
        }
        guard let sourceActive = try activeVersion(templateId: templateId) else {
            throw WorkLogError.validation("복제할 active 버전이 없습니다: \(templateId)")
        }
        let newId = ids.make()
        let newVersionId = ids.make()
        return try db.transaction {
            try db.runV("""
                INSERT INTO report_template (id, purpose, name, active_version_id, archived_at)
                VALUES (?, ?, ?, NULL, NULL)
                """, newId, source.purpose.rawValue, newName)
            try insertVersion(id: newVersionId, templateId: newId, version: 1,
                              instructions: sourceActive.instructions,
                              outputExample: sourceActive.outputExample,
                              skillRef: sourceActive.skillRef, createdAt: clock.now())
            try db.runV("UPDATE report_template SET active_version_id = ? WHERE id = ?", newVersionId, newId)
            guard let created = try template(id: newId) else {
                throw WorkLogError.storage("report_template \(newId) 삽입 후 조회 실패")
            }
            return created
        }
    }

    public func archive(templateId: String) throws {
        try db.transaction {
            let n = try db.runV("UPDATE report_template SET archived_at = ? WHERE id = ?",
                                clock.now(), templateId)
            if n == 0 { throw WorkLogError.notFound("template \(templateId)") }
        }
    }

    /// purpose의 기본 사용 템플릿. 보관되지 않은 것 중 DefaultPrompts id 우선, 없으면 name 순 첫 번째.
    public func preferredTemplate(for purpose: TemplatePurpose) throws -> ReportTemplate? {
        let candidates = try templates(purpose: purpose)
        let defaultId = DefaultPrompts.template(for: purpose).id
        if let preferred = candidates.first(where: { $0.id == defaultId }) {
            return preferred
        }
        return candidates.first
    }

    /// AI 지시문 조립.
    /// DefaultPrompts.commonInstructions + "\n\n" + version.instructions
    /// (+ outputExample이 비어 있지 않으면 "\n\n출력 예시:\n" + outputExample).
    /// 공통 보호 규칙은 항상 맨 앞에 포함되며 사용자 템플릿이 제거할 수 없다.
    public func composeInstructions(versionId: String) throws -> String {
        guard let version = try version(id: versionId) else {
            throw WorkLogError.notFound("template_version \(versionId)")
        }
        var composed = DefaultPrompts.commonInstructions + "\n\n" + version.instructions
        if !version.outputExample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composed += "\n\n출력 예시:\n" + version.outputExample
        }
        return composed
    }

    // MARK: - 내부

    private func insertVersion(id: String, templateId: String, version: Int, instructions: String,
                               outputExample: String, skillRef: String?, createdAt: Date) throws {
        try db.runV("""
            INSERT INTO template_version
                (id, template_id, version, instructions, output_example, skill_ref, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, id, templateId, version, instructions, outputExample, skillRef, createdAt)
    }

    private func templateRow(_ row: SQLRow) throws -> ReportTemplate {
        guard let id = row.string("id"), let purposeRaw = row.string("purpose"),
              let purpose = TemplatePurpose(rawValue: purposeRaw), let name = row.string("name") else {
            throw WorkLogError.storage("report_template row 손상")
        }
        return ReportTemplate(id: id, purpose: purpose, name: name,
                              activeVersionId: row.string("active_version_id"),
                              archivedAt: row.date("archived_at"))
    }

    private func versionRow(_ row: SQLRow) throws -> TemplateVersion {
        guard let id = row.string("id"), let templateId = row.string("template_id"),
              let version = row.int("version"), let instructions = row.string("instructions"),
              let outputExample = row.string("output_example") else {
            throw WorkLogError.storage("template_version row 손상")
        }
        return TemplateVersion(id: id, templateId: templateId, version: version,
                               instructions: instructions, outputExample: outputExample,
                               skillRef: row.string("skill_ref"),
                               createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }
}
