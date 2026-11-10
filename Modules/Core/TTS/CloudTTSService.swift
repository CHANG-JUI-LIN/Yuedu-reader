import Foundation
import Security

/// The voices that can act an emotion, each reached with the reader's own key.
///
/// Selected the same way 微軟線上語音 is: an internal identifier in `httpTtsUrlTemplate`
/// (`yuedu-azure-tts:zh-CN-XiaoxiaoNeural`), so the engine, routing and 多角色朗讀 need no
/// second notion of "the voice source in use".
enum CloudTTSService: String, CaseIterable, Sendable {
    case azure
    case openAI
    case mimo

    var sourcePrefix: String {
        switch self {
        case .azure: return "yuedu-azure-tts:"
        case .openAI: return "yuedu-openai-tts:"
        case .mimo: return "yuedu-mimo-tts:"
        }
    }

    var displayNameKey: String {
        switch self {
        case .azure: return "Azure 語音"
        case .openAI: return "OpenAI 語音"
        case .mimo: return "小米 MiMo 語音"
        }
    }

    func sourceIdentifier(voice: String) -> String { sourcePrefix + voice }

    static func service(forSourceIdentifier identifier: String) -> CloudTTSService? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { trimmed.hasPrefix($0.sourcePrefix) }
    }

    static func voiceID(inSourceIdentifier identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = service(forSourceIdentifier: trimmed) else { return "" }
        return String(trimmed.dropFirst(service.sourcePrefix.count))
    }
}

/// The reader's keys for the cloud voices.
///
/// `AfterFirstUnlockThisDeviceOnly`, not the AI key's `WhenUnlocked`: narration moves to the
/// next chapter with the screen locked, and that is exactly when the key is read again. A
/// key that only opens while unlocked would stop a locked listener at every chapter end.
/// Never synchronised: the key is billed to the reader personally.
enum CloudTTSCredentials {
    private static let service = KeychainHelper.aiService

    private static func account(_ cloud: CloudTTSService) -> String {
        "ttsApiKey.\(cloud.rawValue)"
    }

    static func key(for cloud: CloudTTSService) -> String? {
        KeychainHelper.load(
            account: account(cloud),
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        ).flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func save(_ key: String, for cloud: CloudTTSService) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear(cloud) }
        return KeychainHelper.save(
            account: account(cloud),
            data: trimmed,
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        )
    }

    @discardableResult
    static func clear(_ cloud: CloudTTSService) -> Bool {
        KeychainHelper.delete(account: account(cloud), service: service, synchronizable: false)
    }

    static func hasKey(_ cloud: CloudTTSService) -> Bool { key(for: cloud) != nil }
}

enum CloudTTSError: LocalizedError, Equatable {
    case missingKey(CloudTTSService)
    case invalidEndpoint
    case unauthorized
    case rateLimited
    case serviceStatus(Int, String)
    case emptyAudio
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .missingKey(service):
            return String(format: localized("尚未填入%@的金鑰"), localized(service.displayNameKey))
        case .invalidEndpoint:
            return localized("語音服務位址無效")
        case .unauthorized:
            return localized("語音服務金鑰無效或已過期")
        case .rateLimited:
            return localized("語音服務請求過於頻繁，請稍後再試")
        case let .serviceStatus(status, detail):
            return String(format: localized("語音服務無法使用（HTTP %d）：%@"), status, detail)
        case .emptyAudio:
            return localized("語音服務沒有傳回音訊")
        case .invalidResponse:
            return localized("語音服務回應格式異常")
        }
    }

    /// Classifies a non-2xx response. The body excerpt is bounded: it is shown to the reader
    /// and logged, and a provider's error page can be long.
    static func from(status: Int, body: Data) -> CloudTTSError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default:
            let text = String(data: body.prefix(2048), encoding: .utf8)?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .serviceStatus(status, String(text.prefix(160)))
        }
    }
}

/// One shared session for the cloud voices: bounded like the Edge transport, so a stalled
/// request ends instead of holding a segment forever.
enum CloudTTSSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        return URLSession.trusting(configuration)
    }()
}
