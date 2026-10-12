#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor struct TrashScreen: View {
    @Bindable var model: SecretsModel
    @State private var focusRevision = 0
    @FocusState private var contentFocused: Bool

    private var needsContentFocus: Bool {
        model.isUnlocking || (!model.isLocked &&
            (!model.canEdit(from: .main) || model.hasRecoverableDraft || model.trashItems.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "휴지통", purpose: "Secret 복원·영구 삭제")
            InlineNotice(message: "일반 기록은 삭제 기능이 없어 휴지통 대상이 아닙니다.")
            SecretTrashList(model: model, focusRevision: focusRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusable(needsContentFocus).focused($contentFocused)
        }.padding(WorkLogTheme.contentInset)
        .worklogFocusContent {
            if needsContentFocus { contentFocused = true }
            else { contentFocused = false; focusRevision += 1 }
        }
    }
}
#endif
