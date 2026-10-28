#if os(macOS)
import CoreML
import Foundation
import WorkLogCore

/// Reviewed classifications and messages only; associated model paths and NSError text stay private.
enum MeetingFailurePresentation {
    static func failure(for error: Error, phase: DiagnosticState) -> MeetingOperationFailure {
        if let failure = error as? MeetingOperationFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == MLModelErrorDomain {
            return MeetingOperationFailure(phase: phase, reason: .failed,
                                           errorDomain: .coreML, errorCode: nsError.code)
        }
        let reason: DiagnosticState
        if let error = error as? MeetingAudioCaptureError {
            switch error {
            case .busy: reason = .captureBusy
            case .missingUsageDescription: reason = .missingUsageDescription
            case .microphonePermission: reason = .microphonePermission
            case .screenPermission: reason = .screenPermission
            case .missingDevice: reason = .missingDevice
            case .missingApplication: reason = .missingApplication
            case .invalidFormat: reason = .invalidFormat
            }
        } else if let error = error as? MeetingLocalModelError {
            switch error {
            case .missing: reason = .modelMissing
            case .invalidFile: reason = .modelInvalid
            case .busy: reason = .conflict
            case .invalidAudio: reason = .invalidAudio
            case .downloadFailed: reason = .network
            case .invalidTokenizer: reason = .tokenizerInvalid
            }
        } else {
            return MeetingOperationFailure.sanitized(error, phase: phase)
        }
        return MeetingOperationFailure(phase: phase, reason: reason)
    }

    static func startupMessage(for error: Error) -> String {
        let failure = failure(for: error, phase: .recordingStart)
        switch failure.reason {
        case .captureBusy: return "이미 녹음을 시작했거나 종료하고 있습니다. 진행 중인 작업을 마친 뒤 다시 시작해 주세요."
        case .missingUsageDescription: return "마이크 권한 설명이 포함된 WorkLog 앱에서 녹음을 시작해 주세요."
        case .microphonePermission: return "마이크 접근이 허용되지 않았습니다. 시스템 설정의 마이크 권한을 확인해 주세요."
        case .screenPermission: return "선택한 앱의 소리를 녹음하려면 시스템 설정에서 화면 및 시스템 오디오 녹음 권한을 허용해 주세요."
        case .missingDevice: return "선택한 마이크를 찾을 수 없습니다. 마이크 연결을 확인하고 입력 장치를 다시 선택해 주세요."
        case .missingApplication: return "선택한 온라인 회의 앱을 찾을 수 없습니다. 회의 앱을 실행하고 녹음할 앱을 다시 선택해 주세요."
        case .invalidFormat: return "선택한 장치의 음성 형식을 확인하지 못했습니다. 마이크 연결과 입력 장치 설정을 확인해 주세요."
        case .modelMissing, .modelInvalid, .tokenizerInvalid:
            return "로컬 전사 모델을 확인하지 못했습니다. 설정에서 모델 준비를 다시 실행한 뒤 녹음을 시작해 주세요."
        case .cancelled: return "녹음 시작을 취소했습니다."
        default: return "녹음을 시작하지 못했습니다. 입력 장치·권한·저장 공간을 확인해 주세요."
        }
    }

    static func previewMessage(for failure: MeetingOperationFailure) -> String {
        if modelRemedy(for: failure) != nil {
            return "실시간 전사 모델을 확인하지 못했습니다. 원본 녹음은 계속됩니다. 녹음 종료 후 설정에서 모델 준비를 다시 실행한 뒤 전사를 재시도해 주세요."
        }
        return "실시간 전사에 실패했습니다. 원본 녹음은 계속됩니다. 다음 전사를 기다리거나 녹음 종료 후 정밀 전사를 실행해 주세요."
    }

    static func modelRemedy(for failure: MeetingOperationFailure) -> String? {
        if [.modelMissing, .modelInvalid, .tokenizerInvalid].contains(failure.reason)
            || [.modelValidation, .tokenizer, .modelLoading].contains(failure.phase) {
            return "설정에서 모델 준비를 다시 실행해 주세요."
        }
        return nil
    }
}
#endif
