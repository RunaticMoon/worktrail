#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct ProjectCreationSheet: View {
    let model: ProjectsModel
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("프로젝트 추가").font(.title2.weight(.semibold))
            Text("프로젝트를 만들고 메모와 업무를 연결해 보세요.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text("프로젝트 이름").font(.headline)
                TextField("예: 서비스 개편", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("프로젝트 이름")
                    .focused($nameFocused)
                    .onSubmit(create)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(StatusTone.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("추가", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 380)
        .buttonStyle(.bordered)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty, !isCreating, !worklogHasMarkedText else { return }
        isCreating = true
        do {
            try model.createProject(name: name)
            onCreated()
        } catch WorkLogError.conflict {
            isCreating = false
            errorMessage = "같은 이름의 프로젝트가 있습니다. 다른 이름을 입력하세요."
            nameFocused = true
        } catch {
            isCreating = false
            errorMessage = "프로젝트를 만들지 못했습니다. 이름을 확인하고 다시 시도하세요."
            nameFocused = true
        }
    }
}
#endif
