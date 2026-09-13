//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// App/AI/LLM/AISettingsView.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Probes an endpoint before its settings are written to disk.
///
/// The probe sends a **system message and a user message**, not just a user message: plenty of
/// endpoints accept a bare user turn and then reject a system role, and every real request
/// this app makes carries one. Testing with a shape the app never uses would hand the user a
/// green tick and a feature that fails on the first question.
enum AIConnectionTest {

    enum Outcome: Equatable {
        case success(reply: String)
        case failure(message: String)
    }

    /// Deliberately tiny: this costs the user money on their own key.
    private static let request = LLMGenerationRequest(
        messages: [
            LLMMessage(role: .system, content: "You are a connectivity probe. Reply with OK."),
            LLMMessage(role: .user, content: "OK?"),
        ],
        maxTokens: 16,
        temperature: 0
    )

    static func run(
        endpoint: String,
        apiKey: String,
        model: String,
        providerFactory: (URL, String, String) -> any LLMProviding = { url, key, model in
            OpenAICompatibleProvider(endpoint: url, apiKey: key, defaultModel: model)
        }
    ) async -> Outcome {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .failure(message: AIProviderAssembly.Unavailable.noAPIKey.message)
        }
        let configuration = AIProviderConfiguration(endpoint: endpoint, defaultModel: model)
        guard let url = configuration.endpointURL else {
            return .failure(message: AIProviderAssembly.Unavailable.invalidEndpoint.message)
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return .failure(message: localized("尚未填入模型名稱"))
        }

        let provider = providerFactory(url, trimmedKey, trimmedModel)
        do {
            let response = try await provider.generate(request, model: trimmedModel)
            let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(reply: String(reply.prefix(80)))
        } catch let error as LLMError {
            return .failure(message: error.localizedDescription)
        } catch is CancellationError {
            return .failure(message: localized("已取消"))
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }
}
