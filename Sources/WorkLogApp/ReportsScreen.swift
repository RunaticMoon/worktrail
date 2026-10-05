#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

@MainActor
struct WeeklyReportScreen: View {
    let model: ReportsModel
    let plan: PlanModel
    let quiz: QuizModel
    let calendar: WorkCalendar
    let onManageTemplates: () -> Void

    var body: some View {
        ReportWorkspace(model: model, family: .submission, plan: plan, quiz: quiz,
                        calendar: calendar, onManageTemplates: onManageTemplates)
    }
}

@MainActor
struct PerformanceReportScreen: View {
    let model: ReportsModel
    let calendar: WorkCalendar
    let onManageTemplates: () -> Void

    var body: some View {
        ReportWorkspace(model: model, family: .performance, plan: nil, quiz: nil,
                        calendar: calendar, onManageTemplates: onManageTemplates)
    }
}

/// Existing routing remains usable until the separate sidebar destinations are connected.
@MainActor
struct ReportsScreen: View {
    @Bindable var model: ReportsModel
    let plan: PlanModel
    let quiz: QuizModel
    let calendar: WorkCalendar
    var onManageTemplates: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Picker("보고서 목적", selection: $model.family) {
                Text("주간보고 · 팀 제출용").tag(ReportFamily.submission)
                Text("성과자료 · 성과평가용").tag(ReportFamily.performance)
            }
            .pickerStyle(.segmented)
            .disabled(model.isGenerating || model.hasChanges)
            .padding(WorkLogTheme.contentInset)
            ReportWorkspace(model: model, family: model.family, plan: plan, quiz: quiz,
                            calendar: calendar, onManageTemplates: onManageTemplates)
                .id(model.family)
        }
    }
}

@MainActor
private struct ReportWorkspace: View {
    @Bindable var model: ReportsModel
    let family: ReportFamily
    let plan: PlanModel?
    let quiz: QuizModel?
    let calendar: WorkCalendar
    let onManageTemplates: (() -> Void)?
    @State private var evidenceExpanded = false
    @State private var comparisonExpanded = false
    @State private var copyFailed = false
    @State private var retryAction: RetryAction = .load

    private enum RetryAction { case load, generate, save, confirm, apply, propose, createEvaluation }
    private var isWeekly: Bool { family == .submission }
    private var title: String { isWeekly ? "주간보고" : "성과자료" }
    private var selectionLocked: Bool { model.isGenerating || model.hasChanges }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: title, purpose: isWeekly ? "팀 제출용" : "성과평가용 상세 기록")
                    if model.family != family {
                        familyTransitionNotice
                    } else {
                        if isWeekly { submissionControls } else { performanceControls }
                        templateControls
                        if let pending = model.pendingRegeneration { regenerationNotice(pending) }
                        if let error = model.errorMessage {
                            RecoveryNotice(failed: error, preserved: "기록과 저장한 보고서 버전은 그대로 보존됩니다.",
                                           retryTitle: retryTitle, retry: { retry() })
                                .disabled(model.isGenerating)
                        }
                        if model.isGenerating {
                            StateView(kind: .loading, title: "보고서 초안 생성 중…",
                                      detail: "현재 본문과 계획은 계속 확인할 수 있습니다.")
                        }
                        workLayout(width: geometry.size.width)
                    }
                }
                .frame(maxWidth: 1200, alignment: .leading)
                .padding(WorkLogTheme.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(title)
        .task(id: model.reportDate) { await prepareScreen() }
        .onChange(of: model.hasChanges) { _, changed in
            if !changed && model.family != family && !model.isGenerating {
                Task { await prepareScreen() }
            }
        }
        .onChange(of: model.isGenerating) { _, generating in
            if !generating && model.family != family { Task { await prepareScreen() } }
        }
        .onChange(of: model.performanceDate) { _, _ in if !isWeekly { loadSelection() } }
        .onChange(of: model.periodType) { _, _ in if !isWeekly { loadSelection() } }
        .onChange(of: model.evaluationPeriodId) { _, _ in if !isWeekly { loadSelection() } }
        .onChange(of: model.version?.id) { _, _ in copyFailed = false }
        .onChange(of: model.pendingRegeneration?.id) { _, _ in comparisonExpanded = false }
        .onChange(of: plan?.items) { _, _ in model.checkStale() }
        .onChange(of: quiz?.recorded) { _, _ in model.checkStale() }
    }

    private func workLayout(width: CGFloat) -> some View {
        // Sidebar consumes part of the window. Use the actual content width, not the screen size.
        // AnyLayout preserves the editor, plan selection and question drafts on resize.
        let horizontal = isWeekly && width >= 940
        let layout: AnyLayout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return layout {
            reportBody.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            if isWeekly, let plan, let quiz {
                VStack(alignment: .leading, spacing: 16) {
                    PlanScreen(model: plan, calendar: calendar, embedded: true)
                    Divider()
                    QuizCard(model: quiz, reportDate: model.reportDate)
                }
                .frame(width: horizontal ? 340 : nil, alignment: .leading)
                .frame(maxWidth: horizontal ? 340 : .infinity, alignment: .leading)
            }
        }
    }

    private var submissionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.previousPeriodLabel)
            Text(model.planPeriodLabel)
            WorkDatePicker(title: "보고 주 선택", value: $model.reportDate, calendar: calendar)
                .frame(maxWidth: 400).disabled(selectionLocked)
            Text("공통 업무는 한 번만 묶고, 사용자 확정 계획만 예정에 포함합니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var templateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { templateActions }
                VStack(alignment: .leading, spacing: 8) { templateActions }
            }
            SectionDisclosure(title: "작성 옵션", summary: model.useAI && model.isAIAvailable ? "AI로 다시 쓰기" : "기록 기반 초안",
                              isExpanded: $writingOptionsExpanded) {
                Toggle("AI로 다시 쓰기", isOn: $model.useAI)
                    .disabled(!model.isAIAvailable || model.isGenerating)
                    .worklogHelp("다음 초안을 AI로 다시 작성")
                if !model.isAIAvailable {
                    StateView(kind: .aiUnavailable, title: "AI에 연결되어 있지 않습니다",
                              detail: "기록 기반 초안과 편집·복사·확정은 그대로 사용할 수 있습니다.")
                }
                if let version = model.version {
                    Text("작성: \(version.generator == "deterministic" ? "기록 기반" : "AI 초안")" + (version.aiModel.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                if let status = model.aiJobStatus { Text("AI 상태: \(status.rawValue)").font(.caption) }
            }
            if !model.isAIAvailable && !writingOptionsExpanded {
                Text("AI 연결 없음 · 기록 기반 초안 사용 가능").font(.caption).foregroundStyle(WorkLogTheme.muted)
            }
        }
    }
    @State private var writingOptionsExpanded = false

    @ViewBuilder private var templateActions: some View {
        Text("양식: \(model.templateLabel ?? "활성 양식 없음")").font(.callout)
        if let onManageTemplates {
            Button("양식 관리", action: onManageTemplates).worklogHelp("보고서 양식과 프롬프트 관리")
        } else {
            Text("양식 관리: 설정 → 작업별 스킬·프롬프트").font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
    }

    private var reportBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let version = model.version {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { versionControls(version) }
                    VStack(alignment: .leading, spacing: 8) { versionControls(version) }
                }
                if model.hasChanges {
                    StatusBadge(label: "저장하지 않은 변경", systemImage: "pencil.circle", tone: .warning)
                    Text("본문을 저장하거나 되돌린 뒤 확정·버전 선택·재생성을 진행하세요.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                if model.canEdit {
                    TextEditor(text: $model.content).font(.body).frame(minHeight: 380)
                        .worklogCard(padding: 8)
                        .accessibilityLabel("\(title) 본문 편집")
                        .accessibilityHint("문장을 수정한 뒤 Command S로 저장하세요.")
                } else {
                    Text(model.content.isEmpty ? "본문이 비어 있습니다." : model.content)
                        .font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                        .worklogCard()
                }
                if let reason = model.readOnlyReason {
                    Label(reason, systemImage: "lock").font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { reportActions }
                    VStack(alignment: .leading, spacing: 8) { reportActions }
                }
                if let status = model.statusMessage {
                    Label(status, systemImage: "checkmark.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel(status)
                }
                if copyFailed {
                    RecoveryNotice(failed: "보고서를 복사하지 못했습니다.", preserved: "현재 본문과 확정 상태는 그대로입니다.",
                                   retryTitle: "다시 복사", retry: { copyReport() })
                }
                if model.isStale {
                    Label("원본이 변경되었습니다. 새 초안을 만들면 최신 기록·계획을 반영합니다.", systemImage: "arrow.clockwise")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                generationControls
                reviewDetails(version)
                evidenceDetails
            } else {
                if !model.isGenerating && model.errorMessage == nil {
                    StateView(kind: .empty, title: "검토할 초안이 없습니다",
                              detail: isWeekly ? "지난주 기록과 이번 주 확정 계획으로 초안을 준비합니다." : "기간을 선택하고 초안을 만드세요. 생성은 직접 실행할 때 시작합니다.",
                              actionTitle: "초안 만들기", action: { generate() })
                }
                generationControls
            }
            reportHistory
        }
    }

    @ViewBuilder private func versionControls(_ version: ReportVersion) -> some View {
        StatusBadge(label: model.stateLabel, systemImage: stateSymbol(version.state), tone: stateTone(version.state))
        Picker("버전", selection: Binding(get: { version.id }, set: { model.selectVersion($0) })) {
            ForEach(model.versions) { row in Text("v\(row.version) · \(stateTitle(row.state))").tag(row.id) }
        }.fixedSize(horizontal: false, vertical: true).disabled(selectionLocked)
    }

    @ViewBuilder private var reportActions: some View {
        Button { copyReport() } label: { ShortcutLabel(title: "보고서 복사", keys: "⇧⌘C") }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent).worklogHelp("현재 본문 복사 · 제출 상태는 바뀌지 않습니다", keys: "⇧⌘C")
        Button { retryAction = .save; model.saveEdits() } label: { ShortcutLabel(title: "저장", keys: "⌘S") }
            .keyboardShortcut("s", modifiers: .command).disabled(!model.canEdit || !model.hasChanges)
            .worklogHelp("본문 변경 저장", keys: "⌘S")
        Button("되돌리기") { model.discardEdits() }.disabled(!model.hasChanges)
            .worklogHelp("마지막 저장 본문으로 되돌리기")
        Button("확정") { retryAction = .confirm; model.confirm() }
            .disabled(!model.canEdit || model.hasChanges)
            .worklogHelp("현재 버전을 확정본으로 보존합니다. 이후 수정은 새 버전으로 남습니다")
    }

    private var generationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { generationActions }
            VStack(alignment: .leading, spacing: 8) { generationActions }
        }
    }
    @ViewBuilder private var generationActions: some View {
        Button(model.version == nil ? "초안 만들기" : model.regenerateTitle) { generate() }
            .disabled(selectionLocked || model.pendingRegeneration != nil)
            .worklogHelp("기록과 확정 계획으로 새 버전 만들기 · 저장한 수정본과 확정본 보존")
        Button("다시 불러오기") { loadSelection() }.disabled(selectionLocked)
            .worklogHelp("선택한 기간의 보고서와 원본 변경 여부 확인")
    }

    private func regenerationNotice(_ pending: ReportVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBadge(label: "새 초안 v\(pending.version)이 준비됨", systemImage: "doc.badge.plus", tone: .info)
            Text("현재 본문은 유지됩니다. 닫아도 새 초안은 버전 목록에 남습니다.").font(.callout)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pendingActions }
                VStack(alignment: .leading, spacing: 8) { pendingActions }
            }
            if model.hasChanges {
                Text("새 초안을 적용하려면 현재 편집 내용을 먼저 저장하거나 되돌리세요.").font(.callout)
            }
            if comparisonExpanded { ReportDiffView(pendingDiff: model.pendingDiff) }
        }.worklogCard()
    }
    @ViewBuilder private var pendingActions: some View {
        Button(comparisonExpanded ? "비교 접기" : "변경 비교") { comparisonExpanded.toggle() }
            .worklogHelp("현재 본문과 새 초안의 추가·삭제 줄 비교")
        Button("새 초안 적용") { retryAction = .apply; model.applyPendingRegeneration() }
            .disabled(selectionLocked).worklogHelp("새 초안을 편집 대상으로 열기 · 이전 버전은 보존")
        Button("닫기") { model.dismissPendingRegeneration() }
            .worklogHelp("현재 본문 유지 · 새 초안은 이력에 보존")
    }

    @ViewBuilder private func reviewDetails(_ version: ReportVersion) -> some View {
        if model.usedFallback { InlineNotice(message: "AI 초안 대신 기록 기반 대체 초안을 사용했습니다.") }
        ForEach(Array(model.findings.enumerated()), id: \.offset) { _, finding in
            InlineNotice(message: "검증 \(finding.severity == .error ? "오류" : "경고"): \(finding.message)")
        }
        ForEach(Array(version.warnings.enumerated()), id: \.offset) { _, warning in InlineNotice(message: warning) }
        if isWeekly, let draft = model.submissionDraft {
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
                    Button("선택 항목을 본문에 반영") { model.applySubmissionSelection() }
                        .worklogHelp("선택 항목으로 본문 구성 · 변경 후 저장 필요")
                }.disabled(model.hasChanges)
            }
        }
    }

    private var evidenceDetails: some View {
        SectionDisclosure(title: "상세 성과 근거", summary: "근거 \(model.evidence.count)개", isExpanded: $evidenceExpanded) {
            if model.evidence.isEmpty { Text("이 버전에 연결된 근거가 없습니다.").foregroundStyle(WorkLogTheme.muted) }
            ForEach(Array(model.evidence.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.sourceId) · 원본 버전 \(row.sourceRevision)").font(.caption).foregroundStyle(WorkLogTheme.muted)
                    if let source = model.sources.first(where: { $0.id == row.sourceId }) {
                        if let date = source.workDate { Text("업무일: \(date.iso)").font(.callout) }
                        Text(source.text).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var reportHistory: some View {
        if !model.visibleReports.isEmpty {
            Picker("이전 보고서", selection: Binding(get: { model.report?.id ?? "" }, set: { model.selectReport($0) })) {
                Text("보고서 선택").tag("")
                ForEach(model.visibleReports) { report in
                    Text("\(periodTitle(report.periodType)) · \(KoreanDateLabel.range(report.range, calendar: calendar))").tag(report.id)
                }
            }.disabled(selectionLocked).worklogHelp("이전 기간의 보고서 선택")
        }
    }

    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("집계 방식", selection: Binding(get: { model.evaluationPeriodId != nil }, set: { evaluation in
                model.evaluationPeriodId = evaluation ? model.evaluationPeriods.first?.id : nil
            })) {
                Text("일·주·월·분기").tag(false)
                Text("평가 기간").tag(true)
            }.pickerStyle(.segmented).disabled(selectionLocked || model.evaluationPeriods.isEmpty)
            if model.evaluationPeriodId == nil {
                Picker("기간 유형", selection: $model.periodType) {
                    ForEach([PeriodType.daily, .weekly, .monthly, .quarterly], id: \.self) { type in Text(periodTitle(type)).tag(type) }
                }.disabled(selectionLocked)
                WorkDatePicker(title: "기간에 포함할 날짜", value: $model.performanceDate, calendar: calendar).disabled(selectionLocked)
            } else {
                Picker("평가 기간", selection: $model.evaluationPeriodId) {
                    ForEach(model.evaluationPeriods) { period in
                        Text(KoreanDateLabel.range(period.range, calendar: calendar)).tag(Optional(period.id))
                    }
                }.disabled(selectionLocked)
            }
            if let report = model.report { ReportRangeLabel(title: "집계 기간", range: report.range) }
            DisclosureGroup("새 평가 기간 만들기") { evaluationForm.padding(.top, 8) }
        }
    }
    private var evaluationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("직전 확정 평가 기간 다음 날부터", isOn: $model.deriveEvaluationStart)
            if !model.deriveEvaluationStart { WorkDatePicker(title: "평가 시작일", value: $model.evaluationStart, calendar: calendar) }
            WorkDatePicker(title: "평가 종료일 (포함)", value: $model.evaluationEnd, calendar: calendar)
            Button("기간 제안 확인") { retryAction = .propose; model.proposeEvaluation() }
            if let proposal = model.proposal {
                ReportRangeLabel(title: "제안 기간", range: proposal.range)
                ForEach(proposal.warnings, id: \.self) { InlineNotice(message: $0) }
                Button("이 기간 저장") { retryAction = .createEvaluation; model.createEvaluation() }
            }
        }.disabled(selectionLocked)
    }

    private var familyTransitionNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            StateView(kind: transitionKind, title: model.isGenerating ? "기존 보고서 생성 중…" : "기존 보고서의 편집을 마쳐 주세요",
                      detail: "다른 목적의 보고서를 편집·생성 중이면 그 작업을 먼저 마칩니다. 본문은 그대로 보존됩니다.")
            if model.hasChanges {
                Button("기존 보고서의 편집 내용 저장") { model.saveEdits() }
                    .worklogHelp("편집 중인 보고서를 저장한 뒤 선택한 목적의 화면 열기")
            }
            if let error = model.errorMessage {
                RecoveryNotice(failed: error, preserved: "편집 중인 기존 보고서 본문은 그대로입니다.",
                               retryTitle: "다시 저장", retry: { model.saveEdits() })
            }
        }
    }
    private var transitionKind: StateView.Kind {
        if model.isGenerating { return .loading }
        return .empty
    }
    private func prepareScreen() async {
        guard !model.isGenerating, !model.hasChanges else { return }
        model.family = family
        if isWeekly {
            syncPlan()
            retryAction = .load
            await model.ensureDraftForCurrentPeriod()
        } else { model.loadSelection() }
    }
    private func syncPlan() { plan?.selectWeek(model.reportDate); model.checkStale() }
    private func loadSelection() {
        retryAction = .load
        model.loadSelection()
        model.checkStale()
        copyFailed = false
    }
    private func generate() { retryAction = .generate; Task { await model.generate() } }
    private func copyReport() {
        guard model.version != nil else { return }
        NSPasteboard.general.clearContents()
        copyFailed = !NSPasteboard.general.setString(model.content, forType: .string)
        if !copyFailed { model.markCopied() }
    }
    private var retryTitle: String {
        switch retryAction {
        case .load: return "다시 불러오기"
        case .generate: return "다시 생성"
        case .save: return "다시 저장"
        case .confirm: return "다시 확정"
        case .apply: return "다시 적용"
        case .propose: return "다시 제안"
        case .createEvaluation: return "기간 다시 저장"
        }
    }
    private func retry() {
        switch retryAction {
        case .load:
            if isWeekly { Task { await model.ensureDraftForCurrentPeriod() } } else { loadSelection() }
        case .generate: generate()
        case .save: model.saveEdits()
        case .confirm: model.confirm()
        case .apply: if !selectionLocked { model.applyPendingRegeneration() }
        case .propose: model.proposeEvaluation()
        case .createEvaluation: model.createEvaluation()
        }
    }
    private func stateSymbol(_ state: ReportVersionState) -> String {
        switch state { case .draft: return "doc.text"; case .edited: return "pencil.circle"; case .confirmed: return "checkmark.seal"; case .superseded: return "clock.arrow.circlepath" }
    }
    private func stateTone(_ state: ReportVersionState) -> StatusTone {
        switch state { case .draft: return .neutral; case .edited: return .info; case .confirmed: return .success; case .superseded: return .neutral }
    }
    private func stateTitle(_ state: ReportVersionState) -> String {
        switch state { case .draft: return "초안"; case .edited: return "수정본"; case .confirmed: return "확정본"; case .superseded: return "이전 버전" }
    }
    private func periodTitle(_ type: PeriodType) -> String {
        switch type { case .daily: return "일간"; case .weekly: return "주간"; case .monthly: return "월간"; case .quarterly: return "분기"; case .yearly: return "평가 기간" }
    }
}

struct ReportRangeLabel: View {
    let title: String
    let range: DateRange
    var body: some View {
        Text("\(title): \(range.start.iso)부터 \(range.endExclusive.iso) 전까지")
            .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
