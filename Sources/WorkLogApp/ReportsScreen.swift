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
    @State private var isPreparingScreen = false
    @State private var planExpanded = false
    @State private var quizExpanded = false
    @State private var writingOptionsExpanded = false

    private enum RetryAction { case load, generate, save, confirm, apply, propose, createEvaluation }
    private var isWeekly: Bool { family == .submission }
    private var title: String { isWeekly ? "주간보고" : "성과자료" }
    private var selectionLocked: Bool { model.isGenerating || model.hasChanges }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(isWeekly ? "팀 제출용" : "성과평가용 상세 기록")
                            .font(.callout).foregroundStyle(WorkLogTheme.muted)
                    }
                    if model.family == family {
                        if isWeekly { submissionControls } else { performanceControls }
                        if let version = model.version {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    versionControls(version)
                                    Spacer(minLength: 8)
                                    reportActions
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) { versionControls(version) }
                                    HStack(spacing: 8) { reportActions }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, WorkLogTheme.contentInset)
                .padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.family != family {
                            familyTransitionNotice
                        } else {
                            if let pending = model.pendingRegeneration { regenerationNotice(pending) }
                            if let error = model.errorMessage {
                                RecoveryNotice(failed: error, preserved: "기록과 저장한 보고서 버전은 그대로 보존됩니다.",
                                               retryTitle: retryTitle, retry: { retry() })
                                    .disabled(model.isGenerating)
                            }
                            if model.isGenerating {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("보고서 초안 생성 중…").font(.callout)
                                }
                            }
                            reportBody(editorHeight: min(600, max(240, geometry.size.height - 252)))
                            weeklySupport
                            if let version = model.version {
                                reviewDetails(version)
                                evidenceDetails
                            }
                            Divider()
                            generationControls
                            templateControls
                        }
                    }
                    .frame(maxWidth: 1120, alignment: .leading)
                    .padding(WorkLogTheme.contentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(title)
        .task { await prepareScreen() }
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
        .onChange(of: model.reportDate) { _, _ in if isWeekly { quiz?.reset() } }
        .onChange(of: model.version?.id) { _, _ in copyFailed = false }
        .onChange(of: model.pendingRegeneration?.id) { _, _ in comparisonExpanded = false }
        .onChange(of: plan?.items) { _, _ in model.checkStale() }
        .onChange(of: quiz?.recorded) { _, _ in model.checkStale() }
    }

    @ViewBuilder private var weeklySupport: some View {
        if isWeekly, let plan, let quiz {
            Divider()
            DisclosureGroup(isExpanded: $planExpanded) {
                PlanScreen(model: plan, calendar: calendar, embedded: true)
                    .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Text("이번 주 계획 검토").font(.body.weight(.medium))
                    Text("확정 \(plan.confirmed.count) · 후보 \(plan.candidates.count)")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }
            DisclosureGroup(isExpanded: $quizExpanded) {
                QuizCard(model: quiz, reportDate: model.reportDate)
                    .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Text("성과 보충 질문").font(.body.weight(.medium))
                    Text(quiz.remainingCount > 0 ? "선택 사항 · \(quiz.remainingCount)개 남음" : "선택 사항")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
            }
        }
    }

    private var submissionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { submissionSelection }
                VStack(alignment: .leading, spacing: 8) { submissionSelection }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { submissionRanges }
                VStack(alignment: .leading, spacing: 4) { submissionRanges }
            }
        }
    }
    @ViewBuilder private var submissionSelection: some View {
        WorkDatePicker(title: "보고 주", value: Binding(
            get: { model.reportDate }, set: { date in
                let week = Periods(calendar: calendar).weekStart(containing: date)
                guard week != model.submissionPeriods.plan.start else { return }
                model.reportDate = week
                Task { await prepareScreen() }
            }), calendar: calendar)
            .disabled(selectionLocked || isPreparingScreen)
        reportHistory
    }
    @ViewBuilder private var submissionRanges: some View {
        Text("실적 \(KoreanDateLabel.range(model.submissionPeriods.previous, calendar: calendar, includeYear: true))")
            .font(.caption).foregroundStyle(WorkLogTheme.muted)
            .help("지난주 실제 활동과 일요일 종료 상태")
        Text("계획 \(KoreanDateLabel.range(model.submissionPeriods.plan, calendar: calendar, includeYear: true))")
            .font(.caption).foregroundStyle(WorkLogTheme.muted)
            .help("사용자가 확정한 이번 주 계획 · 착수나 완료와 별개")
    }

    private var templateControls: some View {
        DisclosureGroup(isExpanded: $writingOptionsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { templateActions }
                    VStack(alignment: .leading, spacing: 8) { templateActions }
                }
                Toggle("AI로 다시 쓰기", isOn: $model.useAI)
                    .disabled(!model.isAIAvailable || model.isGenerating)
                    .worklogHelp("다음 초안을 AI로 다시 작성")
                if !model.isAIAvailable {
                    Text("AI 연결 없음 · 기록 기반 초안을 사용할 수 있습니다.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                if let version = model.version {
                    Text("작성: \(version.generator == "deterministic" ? "기록 기반" : "AI 초안")" + (version.aiModel.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(WorkLogTheme.muted)
                }
                if let status = model.aiJobStatus { Text("AI 상태: \(status.rawValue)").font(.caption) }
            }.padding(.top, 8)
        } label: {
            Text("양식·작성 옵션").font(.callout)
        }
    }

    @ViewBuilder private var templateActions: some View {
        Text("양식: \(model.templateLabel ?? "활성 양식 없음")").font(.callout)
        if let onManageTemplates {
            Button("양식 관리", action: onManageTemplates).worklogHelp("보고서 양식과 프롬프트 관리")
        } else {
            Text("양식 관리: 설정 → 작업별 스킬·프롬프트").font(.callout).foregroundStyle(WorkLogTheme.muted)
        }
    }

    private func reportBody(editorHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.version != nil {
                if model.hasChanges {
                    Label("저장하지 않은 변경 · 저장 후 확정할 수 있습니다", systemImage: "pencil.circle")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }
                if model.canEdit {
                    TextEditor(text: $model.content)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: editorHeight)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorkLogTheme.border).allowsHitTesting(false))
                        .accessibilityLabel("\(title) 본문 편집")
                        .accessibilityHint("문장을 수정한 뒤 Command S로 저장하세요.")
                } else {
                    Text(model.content.isEmpty ? "본문이 비어 있습니다." : model.content)
                        .font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.vertical, 8)
                }
                if let reason = model.readOnlyReason {
                    Label(reason, systemImage: "lock").font(.callout).foregroundStyle(WorkLogTheme.muted)
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
                    Label("원본 변경됨 · 새 초안에서 최신 기록·계획을 반영할 수 있습니다.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !model.isGenerating && model.errorMessage == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("이 기간에 저장한 보고서가 없습니다.").font(.body.weight(.medium))
                    Text(isWeekly ? "지난주 기록과 이번 주 확정 계획으로 초안을 준비합니다." : "기간을 선택하고 아래에서 초안을 만드세요.")
                        .font(.callout).foregroundStyle(WorkLogTheme.muted)
                }.padding(.vertical, 24)
            }
        }
    }

    @ViewBuilder private func versionControls(_ version: ReportVersion) -> some View {
        Picker("버전", selection: Binding(get: { version.id }, set: { model.selectVersion($0) })) {
            ForEach(model.versions) { row in Text("v\(row.version) · \(stateTitle(row.state))").tag(row.id) }
        }.frame(width: 150).disabled(selectionLocked)
    }

    @ViewBuilder private var reportActions: some View {
        Button("본문 복사") { copyReport() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent).worklogHelp("현재 본문 복사 · 제출 상태는 바뀌지 않습니다", keys: "⇧⌘C")
        Button("저장") { retryAction = .save; model.saveEdits() }
            .keyboardShortcut("s", modifiers: .command).disabled(!model.canEdit || !model.hasChanges)
            .worklogHelp("본문 변경 저장", keys: "⌘S")
        Button("되돌리기") { model.discardEdits() }.disabled(!model.hasChanges)
            .worklogHelp("마지막 저장 본문으로 되돌리기")
        Button("보고서 확정") { retryAction = .confirm; model.confirm() }
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
        }.padding(.vertical, 8)
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
            Picker("저장한 보고서", selection: Binding(get: { model.report?.id ?? "" }, set: { id in
                model.selectReport(id)
                if isWeekly { syncPlan() }
            })) {
                Text("보고서 선택").tag("")
                ForEach(model.visibleReports) { report in
                    Text("\(periodTitle(report.periodType)) · \(KoreanDateLabel.range(report.range, calendar: calendar))").tag(report.id)
                }
            }.frame(maxWidth: 360).disabled(selectionLocked).worklogHelp("이전 기간의 보고서 선택")
        }
    }

    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { performanceSelection }
                VStack(alignment: .leading, spacing: 8) { performanceSelection }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    reportHistory
                    evaluationDisclosure
                }
                VStack(alignment: .leading, spacing: 8) {
                    reportHistory
                    evaluationDisclosure
                }
            }
            if let report = model.report { ReportRangeLabel(title: "집계 기간", range: report.range) }
        }
    }
    @ViewBuilder private var performanceSelection: some View {
        Picker("기간 유형", selection: Binding(get: {
            model.evaluationPeriodId == nil ? model.periodType : .yearly
        }, set: { type in
            if type == .yearly { model.evaluationPeriodId = model.evaluationPeriods.first?.id }
            else { model.evaluationPeriodId = nil; model.periodType = type }
        })) {
            ForEach([PeriodType.daily, .weekly, .monthly, .quarterly], id: \.self) { type in
                Text(periodTitle(type)).tag(type)
            }
            Text("평가 기간").tag(PeriodType.yearly).disabled(model.evaluationPeriods.isEmpty)
        }.frame(width: 160).disabled(selectionLocked)
        if model.evaluationPeriodId == nil {
            WorkDatePicker(title: "기준일", value: $model.performanceDate, calendar: calendar).disabled(selectionLocked)
        } else {
            Picker("평가 기간", selection: $model.evaluationPeriodId) {
                ForEach(model.evaluationPeriods) { period in
                    Text(KoreanDateLabel.range(period.range, calendar: calendar)).tag(Optional(period.id))
                }
            }.frame(maxWidth: 360).disabled(selectionLocked)
        }
    }
    private var evaluationDisclosure: some View {
        Button("평가 기간 만들기") { evaluationPresented.toggle() }
            .disabled(selectionLocked)
            .popover(isPresented: $evaluationPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("새 평가 기간").font(.headline)
                        Spacer()
                        Button("닫기") { evaluationPresented = false }
                    }
                    evaluationForm
                }.padding(16).frame(width: 420)
            }
    }
    @State private var evaluationPresented = false
    private var evaluationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("직전 확정 평가 기간 다음 날부터", isOn: $model.deriveEvaluationStart)
            if !model.deriveEvaluationStart { WorkDatePicker(title: "평가 시작일", value: $model.evaluationStart, calendar: calendar) }
            WorkDatePicker(title: "평가 종료일 (포함)", value: $model.evaluationEnd, calendar: calendar)
            Button("기간 제안 확인") { retryAction = .propose; model.proposeEvaluation() }
            if let proposal = model.proposal {
                ReportRangeLabel(title: "제안 기간", range: proposal.range)
                ForEach(proposal.warnings, id: \.self) { InlineNotice(message: $0) }
                Button("이 기간 저장") {
                    retryAction = .createEvaluation
                    model.createEvaluation()
                    if model.errorMessage == nil { evaluationPresented = false }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard !isPreparingScreen, !model.isGenerating, !model.hasChanges else { return }
        isPreparingScreen = true
        defer { isPreparingScreen = false }
        model.family = family
        if isWeekly {
            syncPlan()
            retryAction = .load
            await model.ensureDraftForCurrentPeriod()
            // An exact-version request can select another week while preparing the screen.
            if let plan, plan.weekStart != model.reportDate { syncPlan() }
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
