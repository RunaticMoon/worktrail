#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

struct ReportsScreen: View {
    @Bindable var model: ReportsModel
    let plan: PlanModel
    let quiz: QuizModel
    let calendar: WorkCalendar
    @State private var copyMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("리포트 종류", selection: $model.family) {
                    Text("제출용 주간보고").tag(ReportFamily.submission)
                    Text("상세 성과 리포트").tag(ReportFamily.performance)
                }.pickerStyle(.segmented).disabled(model.isGenerating || model.hasChanges)
                if model.family == .submission { submissionControls }
                else { performanceControls }
                HStack {
                    Toggle("AI로 초안 작성", isOn: $model.useAI).disabled(!model.isAIAvailable || model.isGenerating)
                    if !model.isAIAvailable { Text("AI 연결 없음 · 기록 기반 초안 사용").font(.callout).foregroundStyle(.secondary) }
                }
                HStack {
                    Button(model.version == nil ? "초안 생성" : "새 버전 생성") { Task { await model.generate() } }
                        .buttonStyle(.borderedProminent).disabled(model.isGenerating || model.hasChanges)
                    Button("다시 불러오기") { model.load(); model.checkStale() }.disabled(model.isGenerating)
                }
                if model.isGenerating { ProgressView("리포트 초안 생성 중…") }
                if let error = model.errorMessage { InlineNotice(message: error) }
                if model.hasChanges { Text("본문 변경을 저장하거나 되돌린 뒤 확정·다른 버전 선택·새 생성을 진행하세요.").font(.callout) }
                if !model.visibleReports.isEmpty { reportHistory }
                if let version = model.version { preview(version) }
                else { EmptyMessage(title: "검토할 초안이 없습니다", detail: "기간을 선택하고 초안을 생성하세요. 생성된 본문은 검토한 뒤 확정할 수 있습니다.") }
                if model.family == .submission {
                    Divider()
                    DisclosureGroup("이번 주 계획 확인·확정") {
                        PlanScreen(model: plan, calendar: calendar, embedded: true).frame(minHeight: 360)
                    }
                    QuizCard(model: quiz, reportDate: model.reportDate)
                }
            }.frame(maxWidth: 900, alignment: .leading).padding(WorkLogTheme.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("리포트")
            .onAppear { model.loadSelection(); syncPlan() }
            .onChange(of: model.family) { _, _ in model.loadSelection(); copyMessage = nil }
            .onChange(of: model.reportDate) { _, _ in model.loadSelection(); syncPlan(); copyMessage = nil }
            .onChange(of: model.performanceDate) { _, _ in model.loadSelection(); copyMessage = nil }
            .onChange(of: model.periodType) { _, _ in model.loadSelection(); copyMessage = nil }
            .onChange(of: model.evaluationPeriodId) { _, _ in model.loadSelection(); copyMessage = nil }
            .onChange(of: model.version?.id) { _, _ in copyMessage = nil }
            .onChange(of: plan.items) { _, _ in model.checkStale() }
            .onChange(of: quiz.recorded) { _, _ in model.checkStale() }
    }
    private var submissionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkDatePicker(title: "보고 월요일 (선택한 주의 월요일)", value: $model.reportDate, calendar: calendar)
                .disabled(model.isGenerating || model.hasChanges).frame(maxWidth: 400)
            ReportRangeLabel(title: "지난주 상태", range: model.submissionPeriods.previous)
            ReportRangeLabel(title: "이번 주 확정 계획", range: model.submissionPeriods.plan)
            Text("지난주 종료 상태와 이번 주 확정 계획으로 작성합니다. 공통 업무는 한 번만 포함합니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("집계 방식", selection: Binding(get: { model.evaluationPeriodId != nil }, set: { evaluation in
                model.evaluationPeriodId = evaluation ? model.evaluationPeriods.first?.id : nil
            })) {
                Text("일·주·월·분기").tag(false)
                Text("평가 기간").tag(true)
            }.pickerStyle(.segmented).disabled(model.isGenerating || model.hasChanges || model.evaluationPeriods.isEmpty)
            if model.evaluationPeriodId == nil {
                Picker("기간 유형", selection: $model.periodType) {
                    ForEach([PeriodType.daily, .weekly, .monthly, .quarterly], id: \.self) { type in Text(periodTitle(type)).tag(type) }
                }.disabled(model.isGenerating || model.hasChanges)
                WorkDatePicker(title: "기간에 포함할 날짜", value: $model.performanceDate, calendar: calendar)
                    .disabled(model.isGenerating || model.hasChanges)
            } else {
                Picker("평가 기간", selection: $model.evaluationPeriodId) {
                    ForEach(model.evaluationPeriods) { period in
                        Text("\(period.range.start.iso)부터 \(period.range.endExclusive.iso) 전까지").tag(Optional(period.id))
                    }
                }.disabled(model.isGenerating || model.hasChanges)
            }
            DisclosureGroup("새 평가 기간 만들기") { evaluationForm.padding(.top, 8) }
        }
    }
    private var evaluationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("직전 확정 평가 기간 다음 날부터", isOn: $model.deriveEvaluationStart)
            if !model.deriveEvaluationStart { WorkDatePicker(title: "평가 시작일", value: $model.evaluationStart, calendar: calendar) }
            WorkDatePicker(title: "평가 종료일 (포함)", value: $model.evaluationEnd, calendar: calendar)
            Button("기간 제안 확인") { model.proposeEvaluation() }
            if let proposal = model.proposal {
                ReportRangeLabel(title: "제안 기간", range: proposal.range)
                ForEach(proposal.warnings, id: \.self) { InlineNotice(message: $0) }
                Button("이 기간 저장") { model.createEvaluation() }
            }
        }.disabled(model.isGenerating || model.hasChanges)
    }
    private var reportHistory: some View {
        DisclosureGroup(model.family == .submission ? "제출용 보고 목록" : "성과 리포트 목록") {
            ForEach(model.visibleReports) { report in
                Button { model.selectReport(report.id) } label: {
                    HStack {
                        Text("\(periodTitle(report.periodType)) · \(report.range.start.iso)부터 \(report.range.endExclusive.iso) 전까지")
                        if model.report?.id == report.id { Image(systemName: "checkmark").accessibilityLabel("선택됨") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(model.isGenerating || model.hasChanges).padding(.vertical, 4)
            }
        }
    }
    private func preview(_ version: ReportVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.family == .submission ? "제출용 본문 검토" : "성과 리포트 검토").font(.title2.weight(.semibold))
            if let report = model.report {
                ReportRangeLabel(title: report.family == .submission ? "지난주 기간" : "집계 기간", range: report.range)
                if let range = report.planRange { ReportRangeLabel(title: "계획 기간", range: range) }
            }
            Picker("버전", selection: Binding(get: { version.id }, set: { model.selectVersion($0) })) {
                ForEach(model.versions) { row in Text("버전 \(row.version) · \(stateTitle(row.state))").tag(row.id) }
            }.disabled(model.isGenerating || model.hasChanges)
            Text("작성: \(version.generator == "deterministic" ? "기록 기반" : "AI 초안")" + (version.aiModel.map { " · \($0)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
            if let status = model.aiJobStatus { Text("AI 상태: \(status.rawValue)").font(.callout) }
            if model.usedFallback { InlineNotice(message: "AI 초안 대신 기록 기반 대체 초안을 사용했습니다.") }
            ForEach(Array(model.findings.enumerated()), id: \.offset) { _, finding in InlineNotice(message: "검증 \(finding.severity == .error ? "오류" : "경고"): \(finding.message)") }
            ForEach(Array(version.warnings.enumerated()), id: \.offset) { _, warning in InlineNotice(message: warning) }
            if model.isStale { InlineNotice(message: "원본 변경됨 — 새 버전 생성. 현재 본문과 확정본은 유지됩니다.") }
            if model.family == .submission, let draft = model.submissionDraft {
                ForEach(Array(draft.reviewNotes.enumerated()), id: \.offset) { _, note in InlineNotice(message: note) }
                if model.canEdit && version.state == .draft {
                    DisclosureGroup("보고 항목 포함·제외") {
                        ForEach(Array(draft.groups.enumerated()), id: \.offset) { _, group in
                            Text(group.heading).font(.headline)
                            ForEach(group.items, id: \.itemId) { item in
                                Toggle("\(item.category.koreanLabel): \(item.text)", isOn: Binding(
                                    get: { model.includedSubmissionIds.contains(item.itemId) }, set: { included in
                                        if included { model.includedSubmissionIds.insert(item.itemId) }
                                        else { model.includedSubmissionIds.remove(item.itemId) }
                                    })).toggleStyle(.checkbox)
                            }
                        }
                        Button("선택한 항목을 본문에 반영") { model.applySubmissionSelection() }
                    }.disabled(model.hasChanges)
                }
            }
            if model.canEdit {
                Text("본문에서 문장을 수정하거나 삭제해 포함·제외를 검토하세요.").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.content).font(.body).frame(minHeight: 300)
                    .padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    .accessibilityLabel("리포트 본문 편집")
            } else {
                Text(version.content).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Text(version.state == .confirmed ? "확정본은 읽기 전용입니다. 수정하려면 새 버전을 생성하세요." : "대체된 버전은 읽기 전용입니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { previewActions }
                VStack(alignment: .leading, spacing: 8) { previewActions }
            }
            if let copyMessage { Text(copyMessage).font(.callout) }
            DisclosureGroup("근거 \(model.evidence.count)개") {
                if model.evidence.isEmpty { Text("이 버전에 연결된 근거가 없습니다.").foregroundStyle(.secondary) }
                ForEach(Array(model.evidence.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.sourceId) · 원본 버전 \(row.sourceRevision)").font(.callout).foregroundStyle(.secondary)
                        if let source = model.sources.first(where: { $0.id == row.sourceId }) {
                            if let date = source.workDate { Text("업무일: \(date.iso)").font(.callout) }
                            Text(source.text).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
        }
    }
    @ViewBuilder private var previewActions: some View {
        if model.canEdit {
            Button("본문 저장") { model.saveEdits() }.disabled(!model.hasChanges)
            Button("변경 되돌리기") { model.discardEdits() }.disabled(!model.hasChanges)
            Button("리포트 확정") { model.confirm() }.disabled(model.hasChanges)
        }
        Button("텍스트 복사", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            let success = NSPasteboard.general.setString(model.content, forType: .string)
            copyMessage = success ? "텍스트를 복사했습니다." : "텍스트를 복사하지 못했습니다. 다시 시도하세요."
        }.disabled(model.isGenerating)
    }
    private func syncPlan() { plan.selectWeek(model.reportDate); model.checkStale() }
    private func periodTitle(_ type: PeriodType) -> String {
        switch type { case .daily: return "일간"; case .weekly: return "주간"; case .monthly: return "월간"; case .quarterly: return "분기"; case .yearly: return "평가 기간" }
    }
    private func stateTitle(_ state: ReportVersionState) -> String {
        switch state { case .draft: return "초안"; case .edited: return "편집본"; case .confirmed: return "확정본"; case .superseded: return "대체됨" }
    }
}

struct ReportRangeLabel: View {
    let title: String
    let range: DateRange
    var body: some View {
        Text("\(title): \(range.start.iso)부터 \(range.endExclusive.iso) 전까지")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
