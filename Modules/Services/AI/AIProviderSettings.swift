//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// App/AI/LLM/AIProviderConfig.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Everything about the AI backend that is *not* a secret: where to send requests and which
/// model to ask for. The API key lives only in the Keychain.
///
/// `endpoint` holds the **base** — what every provider's documentation calls the Base URL —
/// and the paths are derived from it. Storing the full `/chat/completions` URL instead would
/// make the model list unreachable, because `/models` cannot be derived from it without
/// guessing. A pasted completions URL is accepted and normalised, since that is what most
/// people have on their clipboard.
struct AIProviderConfiguration: Codable, Sendable, Equatable {
    var endpoint: String
    var defaultModel: String

    static let `default` = AIProviderConfiguration(
        endpoint: "https://api.deepseek.com/v1",
        defaultModel: "deepseek-chat"
    )

    /// Where chat requests are POSTed.
    var endpointURL: URL? {
        AIEndpoint.chatCompletionsURL(base: endpoint)
    }

    var baseURL: String {
        AIEndpoint.normalizedBase(endpoint)
    }

    var preset: AIProviderPreset {
        AIProviderPreset.matching(baseURL: endpoint)
    }
}

/// Keychain account name for the BYOK key.
enum AIAPIKeyAccount {
    static let name = "aiApiKey"
}

/// Reads and writes the non-secret half of the AI configuration.
///
/// Main-actor bound: every read and write happens from the settings screen or from assembling
/// a provider for a user action, and a shared mutable singleton has to be isolated to
/// something under Swift 6 strict concurrency.
@MainActor
final class AIProviderStore {
    enum LoadError: Error, Equatable {
        case corruptedConfiguration
    }

    static let shared = AIProviderStore()

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "yd_ai_provider_configuration") {
        self.defaults = defaults
        self.key = key
    }

    /// `nil` means nothing was ever saved.
    ///
    /// Corrupt data **throws** rather than falling back to the default endpoint: silently
    /// pointing a user's requests at `api.openai.com` because their stored config failed to
    /// decode would send their book text somewhere they never chose.
    func load() throws -> AIProviderConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(AIProviderConfiguration.self, from: data)
        } catch {
            throw LoadError.corruptedConfiguration
        }
    }

    func save(_ configuration: AIProviderConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Where the API key is kept.
///
/// `WhenUnlockedThisDeviceOnly` + `synchronizable: false` — a BYOK key is billed to the user
/// personally, so it must not ride iCloud Keychain to devices they did not put it on.
enum AIAPIKeyStore {
    static func save(_ key: String) -> Bool {
        KeychainHelper.save(
            account: AIAPIKeyAccount.name,
            data: key,
            service: KeychainHelper.aiService,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
    }

    static func load() -> String? {
        KeychainHelper.load(
            account: AIAPIKeyAccount.name,
            service: KeychainHelper.aiService,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
    }

    @discardableResult
    static func clear() -> Bool {
        KeychainHelper.delete(
            account: AIAPIKeyAccount.name,
            service: KeychainHelper.aiService,
            synchronizable: false
        )
    }

    static var hasKey: Bool {
        !(load()?.isEmpty ?? true)
    }
}

/// Assembles a provider from the stored configuration, or reports why it cannot.
@MainActor
enum AIProviderAssembly {
    enum Unavailable: Error, Equatable {
        case noAPIKey
        case notConfigured
        case corruptedConfiguration
        case invalidEndpoint

        var message: String {
            switch self {
            case .noAPIKey: return localized("尚未填入 API Key")
            case .notConfigured: return localized("尚未設定 AI 服務")
            case .corruptedConfiguration: return localized("AI 設定已損毀，請重新填寫")
            case .invalidEndpoint: return localized("API 位址無效")
            }
        }
    }

    /// The provider for the app's stored settings.
    static func makeProvider() -> Result<any LLMProviding, Unavailable> {
        // Spelled out rather than given as default arguments: a default argument is
        // evaluated in a nonisolated context, where a main-actor `shared` is off limits.
        makeProvider(store: .shared, apiKey: AIAPIKeyStore.load())
    }

    static func makeProvider(
        store: AIProviderStore,
        apiKey: String?
    ) -> Result<any LLMProviding, Unavailable> {
        guard let apiKey, !apiKey.isEmpty else { return .failure(.noAPIKey) }
        let configuration: AIProviderConfiguration
        do {
            guard let stored = try store.load() else { return .failure(.notConfigured) }
            configuration = stored
        } catch {
            return .failure(.corruptedConfiguration)
        }
        guard let url = configuration.endpointURL else { return .failure(.invalidEndpoint) }
        return .success(
            OpenAICompatibleProvider(
                endpoint: url,
                apiKey: apiKey,
                defaultModel: configuration.defaultModel
            )
        )
    }
}
