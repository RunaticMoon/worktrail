#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct TrashScreen: View {
    @Bindable var model: SecretsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "휴지통", purpose: "Secret 복원·영구 삭제")
            InlineNotice(message: "일반 기록은 삭제 기능이 없어 휴지통 대상이 아닙니다.")
            SecretTrashList(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(WorkLogTheme.contentInset)
    }
}
#endif
