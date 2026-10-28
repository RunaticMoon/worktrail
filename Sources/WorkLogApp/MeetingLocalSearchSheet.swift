#if os(macOS)
import SwiftUI
import WorkLogCore

/// Its query, results and snippets never enter SearchModel or grounded-answer input.
struct MeetingLocalSearchSheet: View {
    let repo: WorkRepository
    let onOpen: (MeetingLocalSearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [MeetingLocalSearchHit] = []
    @State private var selectedID: String?
    @State private var hasMore = false
    @State private var error: String?
    @FocusState private var queryFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("회의 로컬 검색").font(.title2)
            Text("모든 전사 버전·구간과 회의 원문을 이 Mac에서만 검색합니다.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("회의·전사 검색", text: $query)
                .textFieldStyle(.roundedBorder).focused($queryFocused)
                .onSubmit { search() }
                .onChange(of: query) { _, _ in search() }
            if let error { Text(error).foregroundStyle(.red) }
            List(selection: $selectedID) {
                ForEach(rows) { hit in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hit.title).font(.headline)
                        if let start = hit.start { Text("전사 구간 · \(Int(start / 60)):\(String(format: "%02d", Int(start) % 60))").font(.caption) }
                        Text(hit.snippet).lineLimit(4)
                    }
                    .tag(hit.id)
                    .contextMenu { Button("회의 원문 열기") { open(hit) } }
                    .onTapGesture(count: 2) { open(hit) }
                }
            }
            .onKeyPress(.return) {
                guard let hit = rows.first(where: { $0.id == selectedID }) else { return .ignored }
                open(hit); return .handled
            }
            HStack {
                Text(hasMore ? "\(rows.count)건 표시 · 결과 더 있음" : "결과 \(rows.count)건").font(.caption)
                if hasMore { Button("더 보기") { search(more: true) } }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("선택한 원문 열기") {
                    if let hit = rows.first(where: { $0.id == selectedID }) { open(hit) }
                }.disabled(selectedID == nil)
            }
        }.padding(20).frame(minWidth: 520, idealWidth: 640, minHeight: 440, idealHeight: 560)
        .onAppear { queryFocused = true }
    }
    private func search(more: Bool = false) {
        do {
            let offset = more ? rows.count : 0
            let page = try MeetingLocalSearchService(repo: repo).search(query, limit: 101, offset: offset)
            rows = (more ? rows : []) + Array(page.prefix(100))
            hasMore = page.count > 100; error = nil
            if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        } catch { self.error = error.localizedDescription; if !more { rows = []; selectedID = nil }; hasMore = false }
    }
    private func open(_ hit: MeetingLocalSearchHit) { dismiss(); onOpen(hit) }
}
#endif
