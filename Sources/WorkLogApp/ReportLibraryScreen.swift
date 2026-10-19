#if os(macOS)
import SwiftUI
import AppKit
import WorkLogCore

/// Read-only browsing; report creation and editing remain in the existing editors.
@MainActor struct ReportLibraryScreen: View {
    @Bindable var model: ReportLibraryModel
    let onOpen: (String) -> Void
    let onCreate: (ReportFamily) -> Void
    @Environment(\.worklogContentAutofocus) private var contentAutofocus
    @FocusState private var listFocused: Bool
    @FocusState private var periodFocused: Bool
    @State private var isLoading = true
    @State private var copyMessage: String?

    private var selection: Binding<String?> {
        Binding(get: { model.selectedId }, set: { model.select($0) })
    }

    private var periodSelection: Binding<PeriodType> {
        Binding(get: { model.periodType }, set: { type in
            // A weekly-only submission filter must never hide the other periods.
            model.familyFilter = nil
            model.periodType = type
        })
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(title: "리포트", purpose: "기간별 보관함") {
                    Button("새로고침", systemImage: "arrow.clockwise") { reload() }
                        .disabled(isLoading)
                        .worklogHelp("저장된 리포트를 다시 불러오기")
                }
                reportFilters
                if let error = model.errorMessage {
                    RecoveryNotice(failed: error, preserved: "저장된 리포트와 마지막으로 불러온 본문은 보존됩니다.",
                        retry: { reload() })
                }
                if isLoading {
                    StateView(kind: .loading, title: "리포트 불러오는 중…", detail: "저장된 리포트를 확인하고 있습니다.")
                } else if model.items.isEmpty {
                    if model.errorMessage == nil { emptyLibrary }
                    Spacer(minLength: 0)
                } else if geometry.size.width >= 820 {
                    HSplitView {
                        reportList.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                        reportDetail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        reportList.frame(height: min(200, max(120, geometry.size.height * 0.32)))
                        Divider()
                        reportDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(WorkLogTheme.contentInset)
        }
        .worklogFocusContent { focusContent() }
        .onAppear {
            reload()
            DispatchQueue.main.async { if contentAutofocus { focusContent() } }
        }
        .onChange(of: model.items.map(\.id)) { _, ids in
            if model.selectedItem == nil && listFocused { model.select(ids.first) }
        }
        .onChange(of: model.selectedItem?.latestVersion) { _, _ in copyMessage = nil }
    }

    private var reportFilters: some View {
        // Shared label columns keep both tab rows aligned, including when tabs scroll.
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                filterLabel("리포트 기간")
                SegmentedFilterBar(selection: periodSelection, items: periodFilterItems)
                    .focusable(interactions: .edit)
                    .focused($periodFocused)
                    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                        guard periodFocused, press.modifiers.isEmpty, !worklogHasMarkedText,
                              let index = PeriodType.allCases.firstIndex(of: model.periodType) else { return .ignored }
                        let next = index + (press.key == .rightArrow ? 1 : -1)
                        if PeriodType.allCases.indices.contains(next) {
                            periodSelection.wrappedValue = PeriodType.allCases[next]
                        }
                        return .handled
                    }
                    .accessibilityLabel("리포트 기간")
                    .accessibilityHint("좌우 화살표로 기간을 선택합니다")
                    .accessibilityIdentifier("report-library-period-filter")
            }
            if model.periodType == .weekly {
                GridRow {
                    filterLabel("리포트 계열")
                    SegmentedFilterBar<ReportFamily?>(selection: $model.familyFilter, items: [
                        SegmentedFilterItem(value: nil, label: "전체",
                            accessibilityIdentifier: "report-library-family-all"),
                        SegmentedFilterItem(value: .submission, label: "주간보고",
                            accessibilityIdentifier: "report-library-family-submission"),
                        SegmentedFilterItem(value: .performance, label: "성과자료",
                            accessibilityIdentifier: "report-library-family-performance")
                    ])
                    .accessibilityLabel("리포트 계열")
                    .accessibilityIdentifier("report-library-family-filter")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(WorkLogTheme.muted)
            .fixedSize()
    }

    private var periodFilterItems: [SegmentedFilterItem<PeriodType>] {
        PeriodType.allCases.map { type in
            SegmentedFilterItem(value: type, label: periodTitle(type), count: periodCount(type),
                accessibilityIdentifier: "report-library-period-\(type.rawValue)")
        }
    }

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("저장된 리포트 \(model.items.count)개")
                .font(.headline).accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.periodLabel).font(.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { rowMetadata(item) }
                                VStack(alignment: .leading, spacing: 4) { rowMetadata(item) }
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.periodLabel), \(item.familyLabel), \(item.stateLabel), \(item.versionCount)개 버전")
                        .accessibilityHint(item.latestVersion == nil ? "저장된 본문이 없습니다" : "선택하면 본문 표시, Return으로 편집 화면에서 열기")
                        .accessibilityAction(named: Text("편집 화면에서 열기")) {
                            if item.latestVersion != nil { onOpen(item.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .accessibilityLabel("저장된 리포트 목록")
                .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
                    guard listFocused, press.modifiers.isEmpty, !worklogHasMarkedText,
                          let item = model.selectedItem, item.latestVersion != nil else { return .ignored }
                    if press.phase == .down { onOpen(item.id) }
                    return .handled
                }
                .onChange(of: listFocused) { _, focused in
                    if focused && model.selectedItem == nil { model.select(model.items.first?.id) }
                }
                .onChange(of: model.selectedId) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Text("↑↓ 선택 · Return 편집 화면에서 열기")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func rowMetadata(_ item: ReportLibraryItem) -> some View {
        Text(item.familyLabel).font(.callout).foregroundStyle(.secondary)
        StatusBadge(label: item.stateLabel,
            systemImage: item.latestVersion?.state == .confirmed ? "checkmark.seal" : "doc.text",
            tone: item.latestVersion?.state == .confirmed ? .success : .neutral)
    }

    @ViewBuilder private var reportDetail: some View {
        if let item = model.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.periodLabel).font(.headline).accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { rowMetadata(item); versionLabel(item) }
                        VStack(alignment: .leading, spacing: 4) { rowMetadata(item); versionLabel(item) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { detailActions(item) }
                        VStack(alignment: .leading, spacing: 8) { detailActions(item) }
                    }
                    if let copyMessage {
                        Text(copyMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    if let content = model.selectedContent, !content.isEmpty {
                        reportBody(item, content: content)
                    } else {
                        StateView(kind: .empty, title: "저장된 본문이 없습니다",
                            detail: "\(item.familyLabel) 화면에서 리포트를 만들 수 있습니다.",
                            actionTitle: "\(item.familyLabel)에서 만들기", action: { onCreate(item.report.family) })
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            StateView(kind: .empty, title: "리포트를 선택하세요",
                detail: "목록에서 기간을 선택하면 최신 버전의 본문을 볼 수 있습니다.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func reportBody(_ item: ReportLibraryItem, content: String) -> some View {
        if item.report.family == .submission {
            LibrarySubmissionPreview(text: content)
                .id(item.latestVersion?.id)
        } else {
            MarkdownDocumentView(markdown: content, accessibilityIdentifier: "report-library-body")
                .id(item.latestVersion?.id)
        }
    }

    @ViewBuilder private func versionLabel(_ item: ReportLibraryItem) -> some View {
        if let version = item.latestVersion {
            Text("최신 v\(version.version) · \(item.versionCount)개 버전")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func detailActions(_ item: ReportLibraryItem) -> some View {
        Button("본문 복사", systemImage: "doc.on.doc") { copyContent() }
            .disabled(model.selectedContent?.isEmpty != false)
        Button("편집 화면에서 열기", systemImage: "square.and.pencil") { onOpen(item.id) }
            .disabled(item.latestVersion == nil)
            .worklogHelp("최신 버전을 \(item.familyLabel) 화면에서 열기 · 확정본은 새 버전으로 수정")
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            StateView(kind: .empty, title: "\(periodTitle(model.periodType)) 리포트가 없습니다",
                detail: "성과자료에서 기간별 리포트를 만들 수 있습니다. 팀 제출용 주간보고는 주간보고 화면에서 만드세요.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { creationActions }
                VStack(alignment: .leading, spacing: 8) { creationActions }
            }
        }
    }

    @ViewBuilder private var creationActions: some View {
        if model.familyFilter != .submission {
            Button("성과자료에서 만들기") { onCreate(.performance) }
        }
        if model.periodType == .weekly && model.familyFilter != .performance {
            Button("주간보고에서 만들기") { onCreate(.submission) }
        }
    }

    private func reload() {
        model.load() // The Core API is synchronous; no artificial loading delay.
        isLoading = false
    }

    private func focusContent() {
        if model.items.isEmpty { periodFocused = true }
        else {
            if model.selectedItem == nil { model.select(model.items.first?.id) }
            listFocused = true
        }
    }

    private func copyContent() {
        guard let content = model.selectedContent, !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        copyMessage = NSPasteboard.general.setString(content, forType: .string)
            ? "본문을 복사했습니다. 리포트 상태는 바뀌지 않습니다."
            : "본문을 복사하지 못했습니다. 다시 시도하세요."
    }

    private func periodCount(_ type: PeriodType) -> Int {
        // Weekly family filtering affects its count only; other tabs still show their totals.
        if type == .weekly || model.familyFilter == nil { return model.count(for: type) }
        return model.allItems.filter { $0.report.periodType == type }.count
    }

    private func periodTitle(_ type: PeriodType) -> String {
        switch type {
        case .daily: return "일간"
        case .weekly: return "주간"
        case .monthly: return "월간"
        case .quarterly: return "분기"
        case .yearly: return "연간(평가 기간)"
        }
    }
}

/// Submission reports use a plain-text template rather than Markdown syntax.
private struct LibrarySubmissionPreview: View {
    let text: String
    @State private var mode: DisplayMode = .preview

    private enum DisplayMode: Hashable { case preview, text }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .preview {
                SubmissionReportRichView(text: text)
            } else {
                Text(text)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("리포트 본문, 읽기 전용")
                    .accessibilityValue(text)
                    .accessibilityIdentifier("report-library-submission-source")
            }
            Divider()
            Picker("본문 표시", selection: $mode) {
                Text("미리보기").tag(DisplayMode.preview)
                Text("텍스트").tag(DisplayMode.text)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .accessibilityIdentifier("report-library-submission-mode")
            .help("미리보기는 주간보고 서식을 표시하고, 텍스트는 저장된 원문을 표시합니다.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("report-library-submission-body")
    }
}
#endif
