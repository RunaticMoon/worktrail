import Foundation
import Observation

/// 빠른 입력 패널의 세 탭(메모/업무/시크릿) 상태를 관리하는 Core 모델.
///
/// - 탭 순서는 `memo → task → secret`이며 Tab/Shift+Tab 순환만 담당한다.
/// - 일반 초안(`memoDraft`/`taskDraft`)은 서로 독립이고 현재 탭과 무관하게 보존된다.
/// - Secret 값·`SecretsModel`·payload는 이 모델이 소유하거나 참조하지 않는다.
///   Secret 저장은 패널의 `SecretCaptureView`가 담당하며, 이 모델은 디스패치만 한다.
/// - 탭 전환은 `settings.defaultCaptureKind`를 바꾸지 않는다.
@Observable @MainActor public final class CaptureSessionModel {
    /// Tab 순환 순서. `RecordCaptureKind.activity`는 탭으로 노출하지 않는다.
    public static let tabOrder: [CaptureKind] = [.memo, .task, .secret]

    /// 현재 활성 탭.
    public private(set) var tab: CaptureKind

    /// 메모 탭 전용 일반 초안. `kind == .memo` 고정.
    public let memoDraft: CaptureModel
    /// 업무 탭 전용 일반 초안. `kind == .task` 고정.
    public let taskDraft: CaptureModel

    @ObservationIgnored private let environment: AppEnvironment
    /// `markSessionCompleted()` 이후 다음 `beginSession()`이 새 세션으로 시작해야 함을 표시한다.
    @ObservationIgnored private var pendingNewSession = true

    public init(environment: AppEnvironment) {
        self.environment = environment
        tab = environment.settings.defaultCaptureKind
        memoDraft = CaptureModel(environment: environment)
        taskDraft = CaptureModel(environment: environment)
        // 초안 종류는 설정 기본값과 무관하게 고정한다.
        memoDraft.kind = .memo
        taskDraft.kind = .task
    }

    // MARK: - 탭

    public func select(_ tab: CaptureKind) { self.tab = tab }

    /// `memo → task → secret → memo`. `backwards`면 역순.
    public func cycleTab(backwards: Bool) {
        let order = Self.tabOrder
        guard let index = order.firstIndex(of: tab) else { return }
        let count = order.count
        let offset = backwards ? (index - 1 + count) : (index + 1)
        tab = order[offset % count]
    }

    /// Secret 탭이면 nil. 일반 탭이면 해당 탭의 초안.
    public var activeDraft: CaptureModel? {
        switch tab {
        case .memo: return memoDraft
        case .task: return taskDraft
        case .secret: return nil
        }
    }

    public var isSecretTab: Bool { tab == .secret }

    // MARK: - 세션

    /// 패널을 열 때 호출한다.
    ///
    /// 진행 중 세션(이전 Esc 닫기로 초안이 남아 있음)이면 현재 탭·초안을 유지한다.
    /// 새 세션(두 일반 초안이 비어 있고 직전 저장 성공 후)이면
    /// `tab = settings.defaultCaptureKind`로 초기화하고 두 초안을 기본값으로 되돌린다.
    public func beginSession() {
        if pendingNewSession && draftsEmpty {
            startNewSession()
        }
        pendingNewSession = false
    }

    /// 일반 탭에서만 활성 초안을 저장한다.
    ///
    /// Secret 탭에서는 아무 것도 호출하지 않고 `false`를 반환한다.
    /// Secret 저장은 패널의 `SecretCaptureView`가 담당한다.
    @discardableResult
    public func submitOrdinary() -> Bool {
        guard !isSecretTab, let draft = activeDraft else { return false }
        let saved = draft.submit()
        // `CaptureModel.submit()` 성공 시 `resetDefaults()`가 kind를 설정값으로 되돌릴 수 있다.
        // 초안 종류는 고정 계약이므로 다시 보정한다.
        forceFixedKinds()
        return saved
    }

    /// 저장 성공 후 패널이 닫힐 때 호출한다. 다음 `beginSession()`이 새 세션으로 시작한다.
    public func markSessionCompleted() {
        pendingNewSession = true
    }

    /// 두 초안 정리용. 현재 `CaptureModel`에 해제할 관찰·연결 소유권이 없어 no-op이다.
    public func detach() {}

    // MARK: - 내부

    private func startNewSession() {
        tab = environment.settings.defaultCaptureKind
        memoDraft.resetDefaults()
        taskDraft.resetDefaults()
        forceFixedKinds()
        memoDraft.reloadCandidates()
        taskDraft.reloadCandidates()
    }

    private func forceFixedKinds() {
        memoDraft.kind = .memo
        taskDraft.kind = .task
    }

    /// "빈 초안": 내용이 공백뿐·관련 기록 없음·업무 초안은 새 업무 선택.
    private var draftsEmpty: Bool { isEmpty(memoDraft) && isEmpty(taskDraft) }

    private func isEmpty(_ draft: CaptureModel) -> Bool {
        let blankBody = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noLinks = draft.relatedRecords.isEmpty
        if draft === taskDraft {
            return blankBody && noLinks && draft.taskSelection == .newTask
        }
        return blankBody && noLinks
    }
}
