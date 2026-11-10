import Combine
import Foundation

/// Asks a provider what models it has.
///
/// OpenAI-compatible services commonly expose `GET /models`, which is how the open-source agents
/// do it too — hard-coding a model list would be stale the week it shipped, and a reader on a
/// provider that added a model yesterday would have to type its id from memory.
///
/// A provider that does not answer is not an error the reader has to solve: the model field
/// stays typable, and `lastFailure` explains why the menu is empty.
@MainActor
final class AIModelCatalog: ObservableObject {
    static let shared = AIModelCatalog()

    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastFailure: String?

    /// Scoped to endpoint and credential digest; accounts on one URL may see different models.
    private var cache: [String: [String]] = [:]
    private var task: Task<Void, Never>?

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]?
        /// Some gateways answer with a bare array rather than `{"data": …}`.
        let models: [Entry]?
    }

    /// Loads the list for `baseURL`, from cache when it is already known.
    func load(baseURL: String, apiKey: String, forceRefresh: Bool = false) {
        task?.cancel()
        isLoading = false
        models = []
        let base = AIEndpoint.normalizedBase(baseURL)
        let scope = AISourceManifest.digest(base + "|" + apiKey)
        guard !base.isEmpty else {
            models = []
            lastFailure = nil
            return
        }
        if !forceRefresh, let cached = cache[scope] {
            models = cached
            lastFailure = nil
            return
        }
        guard let url = AIEndpoint.modelsURL(base: base) else {
            models = []
            lastFailure = localized("API 位址無效")
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            models = []
            lastFailure = localized("填入 API Key 後才能取得模型清單")
            return
        }

        task?.cancel()
        isLoading = true
        lastFailure = nil
        task = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.trusting.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    self?.finish(base: scope, failure: localized("非 HTTP 回應"))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    // Reuse the provider's own sanitiser: this body is untrusted and may echo
                    // the key back.
                    let message = OpenAICompatibleProvider.extractErrorMessage(from: data)
                        ?? "HTTP \(http.statusCode)"
                    self?.finish(base: scope, failure: message)
                    return
                }
                let decoded = try JSONDecoder().decode(ModelList.self, from: data)
                let ids = (decoded.data ?? decoded.models ?? []).map(\.id)
                    .filter { !$0.isEmpty }
                guard !ids.isEmpty else {
                    self?.finish(base: scope, failure: localized("這個服務沒有回報任何模型"))
                    return
                }
                self?.finish(base: scope, models: Self.sorted(ids))
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(base: scope, failure: error.localizedDescription)
            }
        }
    }

    func clear() {
        task?.cancel()
        models = []
        lastFailure = nil
        isLoading = false
    }

    private func finish(base: String, models list: [String]) {
        cache[base] = list
        models = list
        lastFailure = nil
        isLoading = false
    }

    private func finish(base: String, failure: String) {
        models = []
        lastFailure = failure
        isLoading = false
    }

    /// Chat models first, then everything else.
    ///
    /// A raw `/models` list is mostly noise for this app — embeddings, rerankers, audio,
    /// moderation — and burying `deepseek-chat` under forty of them makes the menu useless.
    /// Nothing is hidden, only pushed down, because one provider's naming is another's
    /// exception.
    nonisolated static func sorted(_ ids: [String]) -> [String] {
        let nonChatMarkers = [
            "embed", "rerank", "whisper", "tts", "audio", "speech",
            "moderation", "image", "dall-e", "vision-ocr", "bge", "clip",
        ]
        func isLikelyChat(_ id: String) -> Bool {
            let lower = id.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        }
        let chat = ids.filter(isLikelyChat).sorted()
        let rest = ids.filter { !isLikelyChat($0) }.sorted()
        return chat + rest
    }
}
