import Foundation

/// Diagnostics intentionally have no message, user identity, path, URL, or arbitrary string field.
/// Add reviewed enum cases when new operational telemetry is needed; never include user content.
public enum DiagnosticCategory: String, Codable, Sendable {
    case application, storage, keychain, recording, transcription, ai, backup, settings, integrations, update, diagnostics
}

public enum DiagnosticEvent: String, Codable, Sendable {
    case appStarted, appReady, appTerminating
    case operationStarted, operationSucceeded, operationFailed
    case permissionRequested, permissionResult, recordingStarted, recordingStopped
    case audioConfigurationObserved, audioConfigurationIgnored, audioConfigurationChanged, deviceUnavailable
    case maintenanceCompleted, logsExported, logsDeleted
    case updateChecked, updateAvailable, updateDownloaded, updateInstalled
}

public enum DiagnosticLevel: String, Codable, Sendable { case debug, info, warning, error }

public enum DiagnosticField: String, Codable, Sendable, CaseIterable {
    case errorCode, errorDomain, osStatus, attempt, durationMilliseconds, sampleRate, channelCount
    case inputSampleRate, inputChannelCount, engineSampleRate, engineChannelCount, engineRunning
    case inputDeviceMatches, configurationChanged, permissionGranted, bufferCount, byteCount, itemCount
    case phase, stage, reason, recovered, available
    case appVersionMajor, appVersionMinor, appVersionPatch, osMajor, osMinor, osPatch
}

public enum DiagnosticState: String, Codable, Sendable {
    case unknown, starting, running, stopping, stopped, succeeded, failed, cancelled
    case denied, authorized, notDetermined, restricted, unchanged, changed, missing, invalid, unavailable
    case cocoa, posix, osStatus, url, coreML, other
    case validation, conflict, storage, integrity, notFound, vaultLocked, vaultKeyMissing, policyBlocked
    case authentication, network, rateLimit, timeout, schemaInvalid, contextTooLarge, unsupported
    case preview, modelValidation, tokenizer, modelLoading, inference, refined, diarization, recordingStart
    case captureBusy, missingUsageDescription, microphonePermission, screenPermission, missingDevice, missingApplication, invalidFormat
    case modelMissing, modelInvalid, tokenizerInvalid, invalidAudio
}

public enum DiagnosticValue: Equatable, Sendable, Codable {
    case integer(Int)
    case decimal(Double)
    case flag(Bool)
    case state(DiagnosticState)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Int.self) { self = .integer(number) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .decimal(number) }
        else { self = .state(try value.decode(DiagnosticState.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .integer(let number): try value.encode(number)
        case .decimal(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        case .state(let state): try value.encode(state)
        }
    }
}

public struct DiagnosticEntry: Codable, Sendable {
    public let timestamp: Date
    public let category: DiagnosticCategory
    public let event: DiagnosticEvent
    public let level: DiagnosticLevel
    public let fields: [String: DiagnosticValue]

    init(timestamp: Date, category: DiagnosticCategory, event: DiagnosticEvent,
         level: DiagnosticLevel, fields: [DiagnosticField: DiagnosticValue]) {
        self.timestamp = timestamp; self.category = category; self.event = event; self.level = level
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
    }

    private enum CodingKeys: String, CodingKey { case timestamp, category, event, level, fields }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        category = try values.decode(DiagnosticCategory.self, forKey: .category)
        event = try values.decode(DiagnosticEvent.self, forKey: .event)
        level = try values.decode(DiagnosticLevel.self, forKey: .level)
        let decoded = try values.decode([String: DiagnosticValue].self, forKey: .fields)
        guard decoded.keys.allSatisfy({ DiagnosticField(rawValue: $0) != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .fields, in: values, debugDescription: "Unrecognized diagnostic field")
        }
        fields = decoded
    }
}

public struct DiagnosticRetentionPolicy: Sendable {
    public static let `default` = DiagnosticRetentionPolicy()
    public let retentionDays: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int

    public init(retentionDays: Int = 7, maximumFileBytes: Int = 1_048_576,
                maximumTotalBytes: Int = 10_485_760) {
        self.retentionDays = min(max(retentionDays, 1), 30)
        self.maximumFileBytes = min(max(maximumFileBytes, 256), 1_048_576)
        self.maximumTotalBytes = min(max(maximumTotalBytes, self.maximumFileBytes), 10_485_760)
    }
}

public struct DiagnosticLogStatus: Sendable {
    public let fileCount: Int
    public let byteCount: Int
    public let eventCount: Int
    public let retentionDays: Int
    public let droppedEventCount: Int
    public let storageAvailable: Bool
}

public struct DiagnosticReportMetadata: Codable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let operatingSystemMajor: Int
    public let operatingSystemMinor: Int
    public let operatingSystemPatch: Int

    public init(appVersion: String, appBuild: String, operatingSystemVersion: OperatingSystemVersion) {
        // Bundle metadata is also an allowlist boundary: do not copy arbitrary text into a report.
        self.appVersion = Self.version(appVersion)
        self.appBuild = Self.version(appBuild)
        operatingSystemMajor = operatingSystemVersion.majorVersion
        operatingSystemMinor = operatingSystemVersion.minorVersion
        operatingSystemPatch = operatingSystemVersion.patchVersion
    }

    private static func version(_ raw: String) -> String {
        guard !raw.isEmpty, raw.utf8.count <= 32,
              raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              raw.first != ".", raw.last != ".", !raw.contains("..") else { return "unknown" }
        return raw
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let metadata: DiagnosticReportMetadata
    public let retentionDays: Int
    public let droppedEventCount: Int
    public let events: [DiagnosticEntry]
}

public enum DiagnosticLogError: Error { case unsafeDirectory, unsafeFile, unavailable }
