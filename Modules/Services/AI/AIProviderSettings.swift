//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// App/AI/LLM/AIProviderConfig.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation
import Combine

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
        defaultModel: "deepseek-flash"
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
final class AIProviderStore: ObservableObject {
    @Published private(set) var revision = 0
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
    static func account(for providerID: UUID?) -> String {
        providerID.map { "aiApiKey.\($0.uuidString)" } ?? AIAPIKeyAccount.name
    }
    static func save(_ key: String, providerID: UUID? = nil) -> Bool {
        KeychainHelper.save(
            account: account(for: providerID),
            data: key,
            service: KeychainHelper.aiService,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
    }

    static func load(providerID: UUID? = nil) -> String? {
        KeychainHelper.load(
            account: account(for: providerID),
            service: KeychainHelper.aiService,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
    }

    @discardableResult
    static func clear(providerID: UUID? = nil) -> Bool {
        KeychainHelper.delete(
            account: account(for: providerID),
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
        do {
            let profiles = try AIProviderStore.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == AIProviderStore.shared.activeID }) ?? profiles.first else { return .failure(.notConfigured) }
            return makeProvider(profile: profile)
        } catch { return .failure(.corruptedConfiguration) }
    }

    /// The active service, with the name and model a run shows the reader before it starts.
    struct ActiveService {
        let provider: any LLMProviding
        let name: String
        var model: String { provider.defaultModel }
    }

    /// Background jobs — 全書摘要, 整章翻譯, 書架整理 — run on the default service and model;
    /// only the assistant's composer picks per conversation.
    static func activeService() -> Result<ActiveService, Unavailable> {
        #if DEBUG
        // `-debug-ai-endpoint <url>`: an OpenAI-compatible fixture stands in for the reader's
        // service (AI 推薦 8f, `scripts/ai_recommendation_fixture.py`), as `-debug-force-pro`
        // stands in for Pro. Nothing the reader configured is read or changed. Debug builds only.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-debug-ai-endpoint"), arguments.indices.contains(index + 1) {
            guard let url = AIEndpoint.chatCompletionsURL(base: arguments[index + 1]) else { return .failure(.invalidEndpoint) }
            return .success(ActiveService(provider: OpenAICompatibleProvider(endpoint: url, apiKey: "fixture",
                                                                             defaultModel: "fixture-model"),
                                          name: "Fixture"))
        }
        #endif
        do {
            let profiles = try AIProviderStore.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == AIProviderStore.shared.activeID }) ?? profiles.first else { return .failure(.notConfigured) }
            return makeProvider(profile: profile).map { ActiveService(provider: $0, name: profile.name) }
        } catch { return .failure(.corruptedConfiguration) }
    }

    static func makeProvider(profile: AIServiceProfile, model: String? = nil) -> Result<any LLMProviding, Unavailable> {
        guard let key = AIAPIKeyStore.load(providerID: profile.id), !key.isEmpty else { return .failure(.noAPIKey) }
        guard let url = profile.configuration.endpointURL else { return .failure(.invalidEndpoint) }
        return .success(OpenAICompatibleProvider(endpoint: url, apiKey: key, defaultModel: model ?? profile.configuration.defaultModel))
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


struct AIServiceProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var configuration: AIProviderConfiguration
    var models: [String]

    init(id: UUID = UUID(), name: String, configuration: AIProviderConfiguration, models: [String] = []) {
        self.id = id; self.name = name; self.configuration = configuration; self.models = models
    }
}

extension AIProviderStore {
    enum PersistenceFailure: LocalizedError {
        case keychain
        var errorDescription: String? { localized("無法儲存 API Key，原設定未變更。") }
    }

    var hasConfiguredProfile: Bool {
        guard let data = defaults.data(forKey: key + ".profiles") else { return AIAPIKeyStore.hasKey }
        guard let profiles = try? JSONDecoder().decode([AIServiceProfile].self, from: data) else { return false }
        return profiles.contains { AIAPIKeyStore.load(providerID: $0.id)?.isEmpty == false }
    }

    var activeID: UUID? {
        defaults.string(forKey: key + ".active").flatMap(UUID.init(uuidString:))
    }

    /// Old configuration and key remain available until the new record and key both verify.
    /// This migration can be removed after legacy single-provider installs are unsupported.
    func profiles(readKey: (UUID?) -> String? = { AIAPIKeyStore.load(providerID: $0) },
                  writeKey: (String, UUID) -> Bool = { AIAPIKeyStore.save($0, providerID: $1) }) throws -> [AIServiceProfile] {
        if let data = defaults.data(forKey: key + ".profiles") {
            return try JSONDecoder().decode([AIServiceProfile].self, from: data)
        }
        let legacyKey = readKey(nil)
        // The old provider also worked with its default configuration and only a saved key.
        guard let legacy = try load() ?? (legacyKey?.isEmpty == false ? .default : nil) else { return [] }
        let id = UUID(uuidString: "BF250A8F-6C43-4C5E-9A80-60A5DB483384")!
        let profile = AIServiceProfile(id: id, name: legacy.preset.displayName, configuration: legacy)
        if let secret = legacyKey, !secret.isEmpty {
            guard writeKey(secret, id), readKey(id) == secret else { throw PersistenceFailure.keychain }
        }
        try writeProfiles([profile])
        defaults.set(id.uuidString, forKey: key + ".active")
        return [profile]
    }

    func select(_ id: UUID) throws {
        guard try profiles().contains(where: { $0.id == id }) else { throw LoadError.corruptedConfiguration }
        defaults.set(id.uuidString, forKey: key + ".active")
        revision += 1
    }

    func upsert(_ profile: AIServiceProfile, apiKey: String? = nil) throws {
        var values = try profiles()
        if let apiKey, !apiKey.isEmpty {
            guard AIAPIKeyStore.save(apiKey, providerID: profile.id), AIAPIKeyStore.load(providerID: profile.id) == apiKey else {
                throw PersistenceFailure.keychain
            }
        }
        if let index = values.firstIndex(where: { $0.id == profile.id }) { values[index] = profile }
        else { values.append(profile) }
        try writeProfiles(values)
        if activeID == nil { defaults.set(profile.id.uuidString, forKey: key + ".active") }
    }

    func remove(_ id: UUID) throws {
        let values = try profiles().filter { $0.id != id }
        // Persist the removal first: a failed settings write must not destroy a usable key.
        try writeProfiles(values)
        _ = AIAPIKeyStore.clear(providerID: id)
        if activeID == id { defaults.set(values.first?.id.uuidString, forKey: key + ".active") }
    }

    private func writeProfiles(_ values: [AIServiceProfile]) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: key + ".profiles")
        revision += 1
    }
}
