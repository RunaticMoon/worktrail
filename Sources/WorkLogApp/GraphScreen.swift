#if os(macOS)
import SwiftUI
import WorkLogCore

/// AA: rendering and navigation only; graph queries and layout belong to GraphModel.
@available(macOS 14.0, *)
@MainActor
struct GraphScreen: View {
    @Bindable var model: GraphModel
    let onOpen: (GraphNode) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var showsLegend = false
    @FocusState private var graphFocused: Bool

    private let primaryKinds: [GraphNodeKind] = [
        .memo, .task, .activity, .reportVersion, .project, .tag,
    ]
    private var effectiveZoom: CGFloat { min(4, max(0.35, zoom * magnification)) }
    private var nodeRadius: CGFloat { min(22, max(13, 15 * effectiveZoom.squareRoot())) }
    private var neighborIDs: Set<GraphNodeID> {
        guard let id = model.selectedNodeID else { return [] }
        return Set(model.neighbors(of: id).map { $0.node.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters.padding(12)
            if model.isTruncated {
                Label("노드가 많아 일부만 표시합니다(최대 250). 기간을 줄이거나 주변 보기를 사용하세요.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider()
            content
            Divider()
            legend.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("그래프")
        .onAppear { if model.phase == .idle { model.reload() } }
        .onChange(of: model.rangePreset) { _, _ in reloadAndFit() }
        .onChange(of: model.visibleKinds) { _, _ in reloadAndFit() }
        .onChange(of: model.focus) { _, _ in fit() }
    }

    // MARK: - Filters and states

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { periodPicker; kindMenu; searchField; refreshButton }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { periodPicker; kindMenu }
                    HStack { searchField; refreshButton }
                }
            }
            if let focus = model.focus {
                HStack {
                    Label("주변 보기", systemImage: "scope")
                    Text(model.snapshot.nodes.first(where: { $0.id == focus })?.title ?? "선택한 기록")
                        .lineLimit(1).help(model.snapshot.nodes.first(where: { $0.id == focus })?.title ?? "선택한 기록")
                    Spacer(minLength: 8)
                    Button("전체 보기") { model.clearFocus() }
                }.font(.callout)
            }
        }
    }

    private var periodPicker: some View {
        Picker("기간", selection: $model.rangePreset) {
            ForEach(GraphModel.RangePreset.allCases, id: \.self) { preset in
                Text(preset.label).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
        .accessibilityLabel("그래프 조회 기간")
    }

    private var kindMenu: some View {
        Menu {
            ForEach(primaryKinds, id: \.self) { kind in kindToggle(kind) }
            Divider()
            kindToggle(.supplement)
            kindToggle(.historicalSource)
        } label: { Label("종류", systemImage: "line.3.horizontal.decrease.circle") }
        .fixedSize()
        .help("표시할 종류를 선택하세요. 최소 한 종류는 선택해야 합니다.")
        .accessibilityLabel("노드 종류 필터")
        .accessibilityValue("\(model.visibleKinds.count)종류 선택")
    }

    private func kindToggle(_ kind: GraphNodeKind) -> some View {
        Toggle(GraphModel.nodeLabel(for: kind), isOn: Binding(
            get: { model.visibleKinds.contains(kind) },
            set: { enabled in
                if enabled { model.visibleKinds.insert(kind) }
                else if model.visibleKinds.count > 1 { model.visibleKinds.remove(kind) }
            }
        ))
        // Core interprets an empty kind set as ALL, so never silently clear the last kind.
        .disabled(model.visibleKinds.count == 1 && model.visibleKinds.contains(kind))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Text("목록 검색").font(.callout).fixedSize()
            TextField("노드 제목", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("노드 목록 제목 검색")
                .help("오른쪽 노드 목록만 검색합니다. 그래프는 유지됩니다.")
        }.frame(minWidth: 150)
    }

    private var refreshButton: some View {
        Button { reloadAndFit() } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("그래프 새로고침").help("그래프 새로고침")
            .disabled(model.phase == .loading)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("그래프 불러오는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            stateMessage("표시할 기록이 없습니다. 기간을 넓혀 보세요.", symbol: "point.3.connected.trianglepath.dotted")
        case let .failed(message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
                Button("다시 시도") { reloadAndFit() }
            }.padding(WorkLogTheme.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            GeometryReader { geometry in
                if geometry.size.width >= 660 {
                    HSplitView {
                        graphPanel.frame(minWidth: 320, maxWidth: .infinity)
                        sidebar.frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
                    }
                } else {
                    VSplitView {
                        graphPanel.frame(minHeight: 150, maxHeight: .infinity)
                        sidebar.frame(minHeight: 140, idealHeight: 220, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func stateMessage(_ message: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center)
        }.padding(WorkLogTheme.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Graph interaction

    private var graphPanel: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                graphCanvas(size: geometry.size)
                    .onChange(of: model.selectedNodeID) { _, id in
                        // List / keyboard selection remains visible even after panning off screen.
                        if let id { reveal(id, in: geometry.size) }
                    }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { graphCounts; Spacer(minLength: 4); viewportControls }
                VStack(alignment: .leading, spacing: 6) {
                    graphCounts
                    HStack { Spacer(minLength: 0); viewportControls }
                }
            }.controlSize(.small).padding(8)
        }
    }

    private var graphCounts: some View {
        Text("노드 \(model.snapshot.nodes.count)개 · 연결 \(model.snapshot.edges.count)개")
            .font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    private var viewportControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("왼쪽으로 이동", systemImage: "arrow.left") { pan.width -= 80 }
                Button("오른쪽으로 이동", systemImage: "arrow.right") { pan.width += 80 }
                Button("위로 이동", systemImage: "arrow.up") { pan.height -= 80 }
                Button("아래로 이동", systemImage: "arrow.down") { pan.height += 80 }
            } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                .accessibilityLabel("그래프 이동").help("드래그 대신 메뉴로 그래프 이동")
            Button { changeZoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 0.35).accessibilityLabel("그래프 축소").help("축소")
            Text("\(Int(effectiveZoom * 100))%")
                .font(.caption).monospacedDigit().frame(minWidth: 34)
                .accessibilityLabel("확대율 \(Int(effectiveZoom * 100))퍼센트")
            Button { changeZoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 4).accessibilityLabel("그래프 확대").help("확대")
            Button("맞춤") { fit() }.help("이동과 확대를 초기화해 전체 그래프를 표시합니다.")
        }.fixedSize()
    }

    private func graphCanvas(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            drawGraph(in: &context, size: canvasSize)
        } symbols: {
            ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                Image(systemName: GraphModel.symbol(for: kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.nodeColor(kind))
                    .tag(kind)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .clipped()
        .gesture(
            SpatialTapGesture(count: 2)
                .exclusively(before: SpatialTapGesture(count: 1))
                .onEnded { value in
                    graphFocused = true
                    switch value {
                    case let .first(tap):
                        if let node = hitTest(tap.location, in: size) {
                            model.select(node.id)
                            open(node)
                        }
                    case let .second(tap):
                        model.select(hitTest(tap.location, in: size)?.id)
                    }
                }
        )
        .simultaneousGesture(DragGesture(minimumDistance: 5)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan = CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height)
                graphFocused = true
            })
        .simultaneousGesture(MagnificationGesture()
            .updating($magnification) { value, state, _ in state = value }
            .onEnded { value in zoom = min(4, max(0.35, zoom * value)) })
        .focusable()
        .focused($graphFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space],
                    phases: [.down, .repeat]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .upArrow, .leftArrow: moveSelection(by: -1)
            case .downArrow, .rightArrow: moveSelection(by: 1)
            case .space: if press.phase == .down { selectCurrentOrFirst() }
            case .return: if press.phase == .down, let node = model.selectedNode { open(node) }
            default: return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("노드 \(model.snapshot.nodes.count)개, 연결 \(model.snapshot.edges.count)개")
        .accessibilityValue(model.selectedNode.map { "선택: \($0.title)" } ?? "선택한 노드 없음")
        .accessibilityHint("방향키로 노드 목록 순서대로 이동, Space로 선택, Return으로 원문 열기. 노드 목록에서도 탐색할 수 있습니다.")
        .accessibilityAction(named: Text("다음 노드")) { moveSelection(by: 1) }
        .accessibilityAction(named: Text("이전 노드")) { moveSelection(by: -1) }
        .accessibilityAction(named: Text("선택한 원문 열기")) { if let node = model.selectedNode { open(node) } }
    }

    private func fit() { zoom = 1; pan = .zero }
    private func reloadAndFit() { fit(); model.reload() }
    private func changeZoom(by factor: CGFloat) { zoom = min(4, max(0.35, zoom * factor)) }

    private func moveSelection(by step: Int) {
        let nodes = model.listedNodes
        guard !nodes.isEmpty else { return }
        let index = nodes.firstIndex { $0.id == model.selectedNodeID }
        let next = index.map { min(nodes.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : nodes.count - 1)
        model.select(nodes[next].id)
    }

    private func selectCurrentOrFirst() {
        let nodes = model.listedNodes
        model.select(nodes.first(where: { $0.id == model.selectedNodeID })?.id ?? nodes.first?.id)
    }

    private func open(_ node: GraphNode) {
        guard node.record != nil, node.id.kind != .historicalSource else { return }
        onOpen(node)
    }

    /// Aspect-preserving viewport transform; no graph layout is performed in the view.
    private func point(_ id: GraphNodeID, in size: CGSize) -> CGPoint? {
        guard let position = model.positions[id] else { return nil }
        let width = max(1, CGFloat(model.layoutConfiguration.width))
        let height = max(1, CGFloat(model.layoutConfiguration.height))
        let scale = max(0.01, min(max(1, size.width - 88) / width, max(1, size.height - 88) / height))
        return CGPoint(
            x: size.width / 2 + (CGFloat(position.x) - width / 2) * scale * effectiveZoom + pan.width + drag.width,
            y: size.height / 2 + (CGFloat(position.y) - height / 2) * scale * effectiveZoom + pan.height + drag.height
        )
    }

    private func reveal(_ id: GraphNodeID, in size: CGSize) {
        guard let p = point(id, in: size), size.width > 0, size.height > 0 else { return }
        let margin = nodeRadius + 24
        if p.x < margin || p.y < margin || p.x > size.width - margin || p.y > size.height - margin {
            pan = CGSize(width: pan.width + size.width / 2 - p.x, height: pan.height + size.height / 2 - p.y)
        }
    }

    private func hitTest(_ location: CGPoint, in size: CGSize) -> GraphNode? {
        let radius = max(22, nodeRadius + 7)
        return model.snapshot.nodes.compactMap { node -> (GraphNode, CGFloat)? in
            guard let p = point(node.id, in: size) else { return nil }
            let distance = hypot(p.x - location.x, p.y - location.y)
            return distance <= radius ? (node, distance) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.key < $1.0.id.key
        }.first?.0
    }

    // MARK: - Inspector and accessible list

    private var sidebar: some View {
        GeometryReader { geometry in
            sidebarContents(inspectorHeight: min(320, max(48, geometry.size.height * 0.4)))
        }
    }

    private func sidebarContents(inspectorHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = model.selectedNode {
                ScrollView {
                    inspector(node).padding(12)
                }.frame(maxHeight: inspectorHeight)
                Divider()
            }
            HStack {
                Text("노드 목록").font(.headline)
                Spacer()
                Text("\(model.listedNodes.count)개").font(.caption).foregroundStyle(.secondary)
                if model.selectedNodeID != nil {
                    Button { model.select(nil) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("노드 선택 해제").help("선택 해제")
                }
            }.padding(12)
            if model.listedNodes.isEmpty {
                Text("검색 결과가 없습니다. 검색어를 바꿔 보세요.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding<GraphNodeID?>(
                        get: { model.selectedNodeID }, set: { model.select($0) }
                    )) {
                        ForEach(model.listedNodes, id: \.id) { node in
                            nodeRow(node).tag(node.id).id(node.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .accessibilityLabel("그래프 노드 목록")
                    .onChange(of: model.selectedNodeID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Text(graphFocused ? "그래프: ↑↓←→ 이동 · Space 선택 · Return 열기" : "목록: ↑↓ 이동 · 원문은 ‘열기’ 버튼 사용")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func nodeRow(_ node: GraphNode) -> some View {
        let row = HStack(alignment: .top, spacing: 8) {
            Image(systemName: GraphModel.symbol(for: node.id.kind))
                .foregroundStyle(Self.nodeColor(node.id.kind)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).lineLimit(2)
                Text(GraphModel.nodeLabel(for: node.id.kind)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(node.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(GraphModel.nodeLabel(for: node.id.kind)), \(node.title)")
        .accessibilityAction { model.select(node.id) }
        if node.record != nil && node.id.kind != .historicalSource {
            row.accessibilityAction(named: Text("원문 열기")) { open(node) }
        } else {
            row
        }
    }

    private func inspector(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(GraphModel.nodeLabel(for: node.id.kind))
            } icon: {
                Image(systemName: GraphModel.symbol(for: node.id.kind)).foregroundStyle(Self.nodeColor(node.id.kind))
            }.font(.callout)
            Text(node.title).font(.headline).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = node.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.callout).textSelection(.enabled)
            }
            if let date = node.date { LabeledContent("날짜", value: date.iso).font(.callout) }
            if node.id.kind == .reportVersion {
                if let family = node.reportFamily { LabeledContent("리포트 종류", value: familyLabel(family)).font(.callout) }
                if let version = node.reportVersionNumber { LabeledContent("버전", value: "v\(version)").font(.callout) }
            }
            if node.id.kind == .historicalSource {
                Label("당시 근거 스냅샷", systemImage: "clock.badge.questionmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("열기", systemImage: "arrow.up.forward.square") { open(node) }
                    .disabled(node.record == nil || node.id.kind == .historicalSource)
                Button("주변 보기", systemImage: "scope") { model.focusOnSelection() }
            }
            let neighbors = model.neighbors(of: node.id)
            Divider()
            Text("연결 \(neighbors.count)개").font(.headline)
            if neighbors.isEmpty { Text("연결된 기록이 없습니다.").font(.callout).foregroundStyle(.secondary) }
            if neighbors.contains(where: { $0.edge.kind == .reportEvidence }) {
                Text("리포트 근거는 생성 당시 스냅샷 기준입니다. 현재 원문과 다를 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(neighbors, id: \.edge.key) { item in
                Button { model.select(item.node.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            edgeSwatch(item.edge.kind).frame(width: 24, height: 10).accessibilityHidden(true)
                            Text(GraphModel.label(for: item.edge.kind)).font(.caption).foregroundStyle(.secondary)
                            if item.edge.isDirected {
                                Image(systemName: item.edge.from == node.id ? "arrow.right" : "arrow.left")
                                    .font(.caption).accessibilityLabel(item.edge.from == node.id ? "나가는 연결" : "들어오는 연결")
                            }
                        }
                        Label(item.node.title, systemImage: GraphModel.symbol(for: item.node.id.kind))
                            .font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        if let revision = item.edge.evidence?.sourceRevision {
                            Text("당시 원문 개정 \(revision)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityHint("연결된 노드 선택")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func familyLabel(_ family: String) -> String {
        switch family {
        case ReportFamily.submission.rawValue: return "제출용 주간보고"
        case ReportFamily.performance.rawValue: return "성과 리포트"
        default: return family
        }
    }

    // MARK: - Legend and semantic colors

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("범례", isExpanded: $showsLegend) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                            Label {
                                Text(GraphModel.nodeLabel(for: kind))
                            } icon: {
                                Image(systemName: GraphModel.symbol(for: kind)).foregroundStyle(Self.nodeColor(kind))
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(GraphEdgeKind.allCases, id: \.self) { kind in
                            HStack(spacing: 6) {
                                edgeSwatch(kind).frame(width: 28, height: 12).accessibilityHidden(true)
                                Text(GraphModel.label(for: kind))
                            }
                        }
                    }
                    Text("화살표는 연결 방향, 이중 테두리는 선택한 노드, 굵은 테두리는 이웃 노드입니다.")
                        .foregroundStyle(.secondary)
                }.font(.caption).padding(.top, 8)
            }
            Text("직접 연결은 리포트 근거나 업무 완료에 영향을 주지 않습니다")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func nodeColor(_ kind: GraphNodeKind) -> Color {
        switch kind {
        case .memo: return .blue
        case .task: return .indigo
        case .activity: return .teal
        case .reportVersion: return .purple
        case .project: return .orange
        case .tag: return .brown
        case .supplement: return .pink
        case .historicalSource: return Color(nsColor: .secondaryLabelColor)
        }
    }

    private static func edgeColor(_ kind: GraphEdgeKind) -> Color {
        switch kind {
        case .manualRelated: return .accentColor
        case .reportEvidence: return .purple
        case .acceptedMemoTask: return .teal
        case .projectMembership, .tagMembership: return Color(nsColor: .secondaryLabelColor)
        default: return Color(nsColor: .labelColor)
        }
    }

    private static func edgeStroke(_ kind: GraphEdgeKind, highlighted: Bool = false) -> StrokeStyle {
        let width: CGFloat = highlighted ? 2.5 : (kind == .manualRelated || kind == .reportEvidence ? 1.8 : 1)
        let dash: [CGFloat]
        switch kind {
        case .manualRelated: dash = [5, 4]
        case .reportEvidence: dash = [7, 3, 1, 3]
        default: dash = []
        }
        return StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
    }

    private func edgeSwatch(_ kind: GraphEdgeKind) -> some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Self.edgeColor(kind)), style: Self.edgeStroke(kind))
        }
    }

    // MARK: - Canvas rendering

    private func drawGraph(in context: inout GraphicsContext, size: CGSize) {
        let neighbors = neighborIDs
        let selected = model.selectedNodeID
        // Separate curves preserve multiple kinds/sources between the same two nodes.
        let groups = Dictionary(grouping: model.snapshot.edges) { edge in
            [edge.from.key, edge.to.key].sorted()
        }
        for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let edges = groups[key]?.sorted(by: { $0.key < $1.key }) else { continue }
            for (index, edge) in edges.enumerated() {
                guard let from = point(edge.from, in: size), let to = point(edge.to, in: size) else { continue }
                let offset = (CGFloat(index) - CGFloat(edges.count - 1) / 2) * 20
                drawEdge(edge, from: from, to: to, offset: offset, in: &context)
            }
        }
        let nodes = model.snapshot.nodes.sorted { a, b in
            func rank(_ node: GraphNode) -> Int {
                node.id == selected ? 0 : (neighbors.contains(node.id) ? 1 : 2)
            }
            let ar = rank(a), br = rank(b)
            return ar == br ? a.id.key < b.id.key : ar < br
        }
        // Draw all circles first so labels can be kept away from other circles.
        var occupied = nodes.compactMap { node -> CGRect? in
            guard let p = point(node.id, in: size) else { return nil }
            return CGRect(x: p.x - nodeRadius - 3, y: p.y - nodeRadius - 3,
                          width: nodeRadius * 2 + 6, height: nodeRadius * 2 + 6)
        }
        for node in nodes.reversed() {
            guard let p = point(node.id, in: size) else { continue }
            drawNode(node, at: p, selected: node.id == selected, neighbor: neighbors.contains(node.id), in: &context)
        }
        for node in nodes {
            guard let p = point(node.id, in: size),
                  effectiveZoom >= 1.35 || node.id == selected || neighbors.contains(node.id) else { continue }
            let singleLine = node.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let title = singleLine.count > 28 ? String(singleLine.prefix(28)) + "…" : singleLine
            let text = context.resolve(Text(title).font(.caption).foregroundColor(Color(nsColor: .labelColor)))
            let measured = text.measure(in: CGSize(width: 220, height: 24))
            let rect = CGRect(x: p.x - measured.width / 2 - 4, y: p.y + nodeRadius + 5,
                              width: measured.width + 8, height: measured.height + 4)
            let viewport = CGRect(origin: .zero, size: size)
            guard node.id == selected || (viewport.contains(rect) && !occupied.contains(where: { $0.intersects(rect) })) else { continue }
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.95)))
            context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            occupied.append(rect)
        }
    }

    private func drawNode(_ node: GraphNode, at point: CGPoint, selected: Bool, neighbor: Bool,
                          in context: inout GraphicsContext) {
        let radius = nodeRadius
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        let color = Self.nodeColor(node.id.kind)
        context.fill(circle, with: .color(Color(nsColor: .textBackgroundColor)))
        context.fill(circle, with: .color(color.opacity(selected || neighbor ? 0.2 : 0.1)))
        context.stroke(circle, with: .color(color), lineWidth: selected || neighbor ? 2.5 : 1.2)
        if selected {
            let outer = Path(ellipseIn: CGRect(x: point.x - radius - 4, y: point.y - radius - 4,
                                              width: (radius + 4) * 2, height: (radius + 4) * 2))
            context.stroke(outer, with: .color(.accentColor), lineWidth: 2)
        }
        if let symbol = context.resolveSymbol(id: node.id.kind) { context.draw(symbol, at: point) }
    }

    private func drawEdge(_ edge: GraphEdge, from: CGPoint, to: CGPoint, offset: CGFloat,
                          in context: inout GraphicsContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = hypot(dx, dy)
        guard distance > nodeRadius * 2 + 4 else { return }
        // Canonical normal gives reverse-direction parallel edges distinct curves too.
        let sign: CGFloat = edge.from.key < edge.to.key ? 1 : -1
        let control = CGPoint(x: (from.x + to.x) / 2 - dy / distance * offset * sign,
                              y: (from.y + to.y) / 2 + dx / distance * offset * sign)
        let startLength = max(1, hypot(control.x - from.x, control.y - from.y))
        let endLength = max(1, hypot(to.x - control.x, to.y - control.y))
        let inset = nodeRadius + 3
        let start = CGPoint(x: from.x + (control.x - from.x) / startLength * inset,
                            y: from.y + (control.y - from.y) / startLength * inset)
        let end = CGPoint(x: to.x - (to.x - control.x) / endLength * inset,
                          y: to.y - (to.y - control.y) / endLength * inset)
        let highlighted = edge.from == model.selectedNodeID || edge.to == model.selectedNodeID
        let membership = edge.kind == .projectMembership || edge.kind == .tagMembership
        let opacity = highlighted ? 1.0 : (membership ? 0.25 : (model.selectedNodeID == nil ? 0.7 : 0.35))
        let color = Self.edgeColor(edge.kind).opacity(opacity)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        context.stroke(path, with: .color(color), style: Self.edgeStroke(edge.kind, highlighted: highlighted))
        if edge.isDirected {
            let angle = atan2(end.y - control.y, end.x - control.x)
            var arrow = Path()
            arrow.move(to: CGPoint(x: end.x - 7 * cos(angle - .pi / 6), y: end.y - 7 * sin(angle - .pi / 6)))
            arrow.addLine(to: end)
            arrow.addLine(to: CGPoint(x: end.x - 7 * cos(angle + .pi / 6), y: end.y - 7 * sin(angle + .pi / 6)))
            context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5, lineCap: .round))
        }
    }
}
#endif
