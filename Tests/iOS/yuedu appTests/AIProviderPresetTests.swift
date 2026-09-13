import Foundation
import Testing
@testable import yuedu_app

@Suite("AI provider presets and model list")
struct AIProviderPresetTests {

    // MARK: - Endpoint normalisation

    /// What people actually have on the clipboard is the full completions URL, because that
    /// is what the old field asked for and what most docs show in a curl example.
    @Test("a pasted /chat/completions URL becomes a base URL")
    func normalizesPastedCompletionsURL() {
        #expect(
            AIEndpoint.normalizedBase("https://api.deepseek.com/v1/chat/completions")
                == "https://api.deepseek.com/v1"
        )
        #expect(AIEndpoint.normalizedBase("https://api.deepseek.com/v1/") == "https://api.deepseek.com/v1")
        #expect(AIEndpoint.normalizedBase("  https://api.deepseek.com/v1  ") == "https://api.deepseek.com/v1")
        #expect(AIEndpoint.normalizedBase("") == "")
    }

    @Test("the chat and models URLs both hang off the base")
    func derivesBothURLs() {
        let base = "https://api.deepseek.com/v1"
        #expect(
            AIEndpoint.chatCompletionsURL(base: base)?.absoluteString
                == "https://api.deepseek.com/v1/chat/completions"
        )
        #expect(AIEndpoint.modelsURL(base: base)?.absoluteString == "https://api.deepseek.com/v1/models")
    }

    @Test("a base that is not a URL yields nothing rather than a broken request")
    func refusesNonURLs() {
        #expect(AIEndpoint.chatCompletionsURL(base: "api.deepseek.com") == nil)
        #expect(AIEndpoint.chatCompletionsURL(base: "   ") == nil)
        #expect(AIEndpoint.modelsURL(base: "nonsense") == nil)
    }

    /// Normalising twice must not eat another path segment.
    @Test("normalisation is idempotent")
    func normalizationIsIdempotent() {
        let once = AIEndpoint.normalizedBase("https://api.deepseek.com/v1/chat/completions")
        #expect(AIEndpoint.normalizedBase(once) == once)
    }

    // MARK: - Presets

    @Test("a configured base URL resolves back to its provider name")
    func matchesPresetByBaseURL() {
        #expect(AIProviderPreset.matching(baseURL: "https://api.deepseek.com/v1").id == "deepseek")
        // Including when the completions URL was pasted.
        #expect(
            AIProviderPreset.matching(baseURL: "https://api.deepseek.com/v1/chat/completions").id
                == "deepseek"
        )
        #expect(AIProviderPreset.matching(baseURL: "https://my-proxy.example/v1").id == "custom")
        #expect(AIProviderPreset.matching(baseURL: "").id == "custom")
    }

    @Test("every preset has a usable base URL and a starting model")
    func presetsAreWellFormed() {
        for preset in AIProviderPreset.all where preset != .custom {
            #expect(!preset.displayName.isEmpty)
            #expect(AIEndpoint.chatCompletionsURL(base: preset.baseURL) != nil, "\(preset.id)")
            #expect(AIEndpoint.modelsURL(base: preset.baseURL) != nil, "\(preset.id)")
            #expect(!preset.suggestedModel.isEmpty, "\(preset.id)")
            // Already a base: normalising must not change it.
            #expect(AIEndpoint.normalizedBase(preset.baseURL) == preset.baseURL, "\(preset.id)")
        }
        #expect(AIProviderPreset.all.last == .custom)
        #expect(Set(AIProviderPreset.all.map(\.id)).count == AIProviderPreset.all.count)
    }

    @Test("the default configuration matches a preset")
    func defaultConfigurationIsAPreset() {
        #expect(AIProviderConfiguration.default.preset.id != "custom")
        #expect(AIProviderConfiguration.default.endpointURL != nil)
    }

    // MARK: - Model list ordering

    /// A raw `/models` list is mostly things this app cannot use. Burying the chat models
    /// under forty embedding models makes the menu worse than a text field.
    @Test("chat models come first, and nothing is dropped")
    func sortsChatModelsFirst() {
        let ids = [
            "text-embedding-3-small",
            "deepseek-chat",
            "whisper-1",
            "deepseek-reasoner",
            "bge-reranker-v2-m3",
        ]
        let sorted = AIModelCatalog.sorted(ids)
        #expect(sorted.prefix(2) == ["deepseek-chat", "deepseek-reasoner"])
        #expect(Set(sorted) == Set(ids))
        #expect(sorted.count == ids.count)
    }

    @Test("ordering is stable for an all-chat list")
    func sortsAlphabeticallyWithinGroups() {
        #expect(AIModelCatalog.sorted(["gpt-4o", "gpt-4o-mini"]) == ["gpt-4o", "gpt-4o-mini"])
        #expect(AIModelCatalog.sorted([]).isEmpty)
    }
}
