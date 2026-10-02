import Foundation

/// 전역 단축키 동작. OS 등록 단위의 식별자다.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case capture
    case search

    /// 사용자에게 보여주는 한국어 이름.
    var title: String {
        switch self {
        case .capture: return "입력"
        case .search: return "검색"
        }
    }
}

/// OS 전역 단축키 등록을 담당하는 어댑터 계약. macOS 구현(Carbon)은 App 계층이 담당한다.
@MainActor public protocol HotkeyRegistrar: AnyObject {
    /// OS 등록 실패 시 throw한다. 실패한 호출은 등록을 남기지 않아야 한다.
    func register(_ binding: HotkeyBinding, for action: HotkeyAction) throws
    /// 미등록 action이면 no-op이다.
    func unregister(_ action: HotkeyAction)
}

/// 단축키 적용 실패. 형식·중복·등록·저장·복구 실패를 구분한다.
/// errorDescription은 한국어이며 설정 경로·시스템 응답 원문을 노출하지 않는다.
public enum HotkeyApplyError: Error, Equatable, LocalizedError {
    /// 파싱 오류. 두 번째 값은 파서의 한국어 설명이다.
    case invalid(HotkeyAction, String)
    /// 두 조합이 동일하다.
    case duplicate
    /// OS 등록 실패(다른 앱 점유 등). 기존 조합은 복구됐다.
    case registrationFailed(HotkeyAction)
    /// 설정 저장 실패. 기존 조합은 복구됐다.
    case persistFailed
    /// 복구까지 실패했다. 기존 조합이 유지됐다고 간주하면 안 된다.
    case restoreFailed

    public var errorDescription: String? {
        switch self {
        case .invalid(let action, let detail):
            return "\(action.title) 단축키 형식이 올바르지 않습니다. \(detail)"
        case .duplicate:
            return "두 단축키가 같은 조합입니다. 서로 다른 조합을 설정하세요."
        case .registrationFailed(let action):
            return "\(action.title) 단축키를 등록하지 못했습니다. 다른 조합으로 설정하세요."
        case .persistFailed:
            return "단축키 설정을 저장하지 못했습니다. 기존 단축키로 되돌렸습니다."
        case .restoreFailed:
            return "기존 단축키를 다시 등록하지 못했습니다. 앱을 다시 시작한 뒤 설정을 확인하세요."
        }
    }
}

/// 단축키 적용·복구·녹화 수명주기를 조정한다. OS 코드 없이 registrar를 통해 동작한다.
///
/// `active`는 현재 등록돼 있어야 할 바인딩(녹화 중에는 일시 해제된 상태 포함)을 뜻한다.
/// 등록에 실패한 action은 `active`에 넣지 않는다.
@MainActor public final class HotkeySettingsCoordinator {
    private let registrar: HotkeyRegistrar

    /// 현재 유효한 바인딩. 등록 성공분만 담긴다.
    public private(set) var active: [HotkeyAction: HotkeyBinding] = [:]
    /// 녹화 중이면 true. 모든 `active` 바인딩이 일시 해제돼 있다.
    public private(set) var isRecording = false

    public init(registrar: HotkeyRegistrar) {
        self.registrar = registrar
    }

    /// 앱 시작 시 최초 등록. 재호출하면 기존 등록을 모두 해제하고 다시 등록한다.
    /// 한 action이 실패해도 다른 action 등록은 계속하며, 실패한 action의 한국어 메시지 목록을 반환한다.
    public func start(capture: String, search: String) -> [String] {
        shutdown()
        var messages: [String] = []
        var taken: Set<HotkeyBinding> = []
        for action in HotkeyAction.allCases {
            let binding: HotkeyBinding
            do {
                binding = try HotkeyBinding(parsing: action == .capture ? capture : search)
            } catch {
                messages.append("\(action.title) 단축키 형식이 올바르지 않습니다. \(Self.describe(error))")
                continue
            }
            if taken.contains(binding) {
                messages.append("\(action.title) 단축키가 다른 단축키와 같은 조합입니다. 서로 다른 조합을 설정하세요.")
                continue
            }
            do {
                try registrar.register(binding, for: action)
                active[action] = binding
                taken.insert(binding)
            } catch {
                messages.append("\(action.title) 단축키를 등록하지 못했습니다. 다른 조합으로 설정하세요.")
            }
        }
        return messages
    }

    /// 검증 → 변경된 action만 기존 해제 → 신규 등록 → persist() 순으로 적용한다.
    /// 어느 단계든 실패하면 신규 등록을 해제하고 이전 `active`를 재등록한 뒤 적절한 오류를 던진다.
    /// 두 키가 서로 교환되는 경우도 성공해야 하므로 변경 대상을 모두 해제한 뒤 등록한다.
    /// 바인딩이 변하지 않으면 등록을 건드리지 않고 persist만 호출한다.
    ///
    /// 녹화 중에 호출되면 녹화를 먼저 종료한 것으로 처리한다(isRecording=false).
    /// 일시 해제된 바인딩은 이 호출 안에서 새 값(또는 검증 실패 시 기존 값)으로 다시 등록된다.
    public func apply(capture: String, search: String, persist: () throws -> Void) throws {
        let wasRecording = isRecording
        isRecording = false

        let parsed: [HotkeyAction: HotkeyBinding]
        do {
            parsed = try Self.parse(capture: capture, search: search)
        } catch let error as HotkeyApplyError {
            if wasRecording, !restore(active, over: HotkeyAction.allCases) {
                throw HotkeyApplyError.restoreFailed
            }
            throw error
        }

        // 녹화 직후에는 모든 등록이 해제돼 있으므로 변경 여부와 무관하게 전부 재등록한다.
        let targets = HotkeyAction.allCases.filter { wasRecording || active[$0] != parsed[$0] }
        if targets.isEmpty {
            do { try persist() } catch { throw HotkeyApplyError.persistFailed }
            return
        }

        let previous = active
        for action in targets { registrar.unregister(action) }

        var registered: [HotkeyAction] = []
        var failedAction: HotkeyAction?
        for action in targets {
            guard let binding = parsed[action] else { continue }
            do {
                try registrar.register(binding, for: action)
                registered.append(action)
            } catch {
                failedAction = action
                break
            }
        }
        if let failedAction {
            for action in registered { registrar.unregister(action) }
            if !restore(previous, over: targets) { throw HotkeyApplyError.restoreFailed }
            throw HotkeyApplyError.registrationFailed(failedAction)
        }
        active = parsed

        do {
            try persist()
        } catch {
            for action in registered { registrar.unregister(action) }
            let restored = restore(previous, over: targets)
            active = previous
            throw restored ? HotkeyApplyError.persistFailed : HotkeyApplyError.restoreFailed
        }
    }

    /// 녹화 시작: 모든 `active`를 일시 해제한다. 현재 등록된 조합도 녹화할 수 있고
    /// 패널이 녹화 중에 열리지 않는다. 이미 녹화 중이면 무시한다.
    public func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        for action in HotkeyAction.allCases { registrar.unregister(action) }
    }

    /// 녹화 종료: 일시 해제한 `active`를 다시 등록한다. begin 없이 호출하면 no-op이다.
    /// 재등록에 실패한 action은 `active`에서 제거해(더 이상 등록돼 있지 않으므로) 다음 `apply`가
    /// 값이 같더라도 재등록을 시도하게 한다. 실패한 action의 한국어 메시지를 반환한다.
    @discardableResult
    public func endRecording() -> [String] {
        guard isRecording else { return [] }
        isRecording = false
        var messages: [String] = []
        for action in HotkeyAction.allCases {
            guard let binding = active[action] else { continue }
            do {
                try registrar.register(binding, for: action)
            } catch {
                active[action] = nil
                messages.append("\(action.title) 단축키를 다시 등록하지 못했습니다. 다른 조합으로 설정하세요.")
            }
        }
        return messages
    }

    /// 모든 등록을 해제한다(앱 종료·백업 복원 전). 이후 `active`는 비어 있다.
    public func shutdown() {
        isRecording = false
        active = [:]
        for action in HotkeyAction.allCases { registrar.unregister(action) }
    }

    // MARK: - 내부

    private static func parse(capture: String, search: String) throws -> [HotkeyAction: HotkeyBinding] {
        let captureBinding: HotkeyBinding
        do {
            captureBinding = try HotkeyBinding(parsing: capture)
        } catch {
            throw HotkeyApplyError.invalid(.capture, describe(error))
        }
        let searchBinding: HotkeyBinding
        do {
            searchBinding = try HotkeyBinding(parsing: search)
        } catch {
            throw HotkeyApplyError.invalid(.search, describe(error))
        }
        guard captureBinding != searchBinding else { throw HotkeyApplyError.duplicate }
        return [.capture: captureBinding, .search: searchBinding]
    }

    /// targets에 속한 action을 이전 바인딩으로 다시 등록한다. 이전에 등록되지 않은 action은 건너뛴다.
    /// 실패한 action이 있어도 나머지 복구를 계속 시도하고, 모두 성공했을 때만 true를 반환한다.
    private func restore(_ previous: [HotkeyAction: HotkeyBinding], over targets: [HotkeyAction]) -> Bool {
        var restored = true
        for action in targets {
            registrar.unregister(action)
            guard let binding = previous[action] else { continue }
            do { try registrar.register(binding, for: action) }
            catch { restored = false }
        }
        return restored
    }

    private static func describe(_ error: Error) -> String {
        (error as? HotkeyBindingError)?.errorDescription ?? "형식이 올바르지 않습니다."
    }
}
