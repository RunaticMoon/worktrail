#if os(macOS)
import SwiftUI
import WorkLogCore

struct ActivityIntegrationSettingsView: View {
    @Bindable var model: ActivityIntegrationsModel
    var onImported: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("앱 실행·복귀 시 하루 한 번 최근 기록을 가져와 실제 활동 날짜의 메모에 저장합니다. 다음 수집에서도 같은 기록을 중복 저장하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
            connectionFields($model.draft.github, token: $model.githubToken)
            connectionFields($model.draft.jira, token: $model.jiraToken)
            Text("GitHub: 본인 push·PR·리뷰 이벤트. Jira: JQL 범위 안에서 본인이 만든 이슈·변경 이력·작업 시간 기록. 업무 상태는 자동 변경하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("사내망/VPN에 연결된 Mac에서 수집합니다. GitHub 이벤트는 서버 보존 기간과 최대 300개 제한이 있으며, 처음에는 최근 7일을 가져옵니다. 수집한 메모는 일반 기록과 같은 검색·보고서·AI 설정을 따릅니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("활동 수집 설정 저장") { model.save() }
                    .disabled(!model.isLoaded || !model.isDirty || model.isRunning)
                Button("지금 가져오기") {
                    Task { await model.sync(manual: true); onImported() }
                }.disabled(!model.isLoaded || model.isDirty || model.isRunning)
                if model.isRunning { ProgressView().controlSize(.small) }
            }
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
        }.disabled(model.isRunning)
    }

    @ViewBuilder private func connectionFields(_ connection: Binding<ActivityConnection>, token: Binding<String>) -> some View {
        let source = connection.wrappedValue.source
        GroupBox(source.title) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("매일 수집", isOn: connection.enabled)
                TextField(source == .github ? "서버 주소 (https://github.company.com)" : "사이트 주소 (https://company.atlassian.net)", text: connection.baseURL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("activity-\(source.rawValue)-base-url")
                if source == .jira {
                    Text("Scoped API 토큰은 https://api.atlassian.com/ex/jira/<cloudId> 주소를 사용하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(source == .github ? "GitHub 사용자 이름" : "Atlassian 이메일", text: connection.account)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("activity-\(source.rawValue)-account")
                SecureField("API 토큰 (비워두면 기존 값 유지)", text: token)
                    .accessibilityIdentifier("activity-\(source.rawValue)-token")
                if source == .jira {
                    TextField("수집할 이슈 JQL", text: connection.jiraJQL, axis: .vertical)
                        .lineLimit(2...5).autocorrectionDisabled()
                        .accessibilityIdentifier("activity-jira-jql")
                }
                Button("이 연결의 저장된 토큰 삭제", role: .destructive) { model.removeToken(for: source) }
                    .disabled(connection.wrappedValue.baseURL.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
