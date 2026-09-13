import Foundation

/// A known OpenAI-compatible service, so the reader picks a name instead of typing a URL.
///
/// Every entry here speaks `/chat/completions` and, with one documented exception, lists its
/// models at `/models` — which is what lets the model field be a menu rather than a field the
/// reader has to get exactly right from memory.
///
/// `custom` is not a fallback for a missing entry, it is the supported way to use anything
/// self-hosted, proxied, or newer than this list.
struct AIProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    /// Shown in the menu. Deliberately the name the reader knows it by, not the company's.
    let displayName: String
    /// The base, without `/chat/completions` — the same thing every other client calls
    /// "Base URL", and what `/models` hangs off.
    let baseURL: String
    /// A sensible starting model, replaced as soon as the live list loads.
    let suggestedModel: String
    /// SF Symbol. Provider logos are trademarks and are not redistributable, so this uses
    /// neutral symbols rather than shipping someone else's mark.
    let symbol: String

    static let custom = AIProviderPreset(
        id: "custom",
        displayName: "自訂",
        baseURL: "",
        suggestedModel: "",
        symbol: "slider.horizontal.3"
    )

    /// The presets offered in the menu, in the order they appear.
    ///
    /// Ordered by who is likely to be reading a Chinese novel in this app rather than by
    /// company size: the domestic services first, the international ones after.
    static let all: [AIProviderPreset] = [
        AIProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            suggestedModel: "deepseek-chat",
            symbol: "water.waves"
        ),
        AIProviderPreset(
            id: "moonshot",
            displayName: "Kimi 月之暗面",
            baseURL: "https://api.moonshot.cn/v1",
            suggestedModel: "moonshot-v1-8k",
            symbol: "moon.stars"
        ),
        AIProviderPreset(
            id: "zhipu",
            displayName: "智譜 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            suggestedModel: "glm-4-flash",
            symbol: "cube.transparent"
        ),
        AIProviderPreset(
            id: "dashscope",
            displayName: "阿里雲百鍊",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            suggestedModel: "qwen-plus",
            symbol: "cloud"
        ),
        AIProviderPreset(
            id: "volcengine",
            displayName: "火山方舟 豆包",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            suggestedModel: "doubao-pro-32k",
            symbol: "flame"
        ),
        AIProviderPreset(
            id: "siliconflow",
            displayName: "矽基流動",
            baseURL: "https://api.siliconflow.cn/v1",
            suggestedModel: "Qwen/Qwen2.5-7B-Instruct",
            symbol: "square.stack.3d.up"
        ),
        AIProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            suggestedModel: "gpt-4o-mini",
            symbol: "circle.hexagongrid"
        ),
        AIProviderPreset(
            id: "anthropic",
            displayName: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            suggestedModel: "claude-sonnet-4-5",
            symbol: "asterisk"
        ),
        AIProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            suggestedModel: "gemini-2.0-flash",
            symbol: "sparkle"
        ),
        AIProviderPreset(
            id: "xai",
            displayName: "xAI Grok",
            baseURL: "https://api.x.ai/v1",
            suggestedModel: "grok-2-latest",
            symbol: "x.circle"
        ),
        AIProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModel: "openai/gpt-4o-mini",
            symbol: "arrow.triangle.branch"
        ),
        custom,
    ]

    /// The preset whose base URL the reader is currently pointed at, or `custom`.
    ///
    /// Matched on the normalised base rather than on a stored id, so a configuration typed by
    /// hand still shows the right name — and so removing a preset from this list never leaves
    /// a stored id dangling.
    static func matching(baseURL: String) -> AIProviderPreset {
        let normalized = AIEndpoint.normalizedBase(baseURL)
        guard !normalized.isEmpty else { return custom }
        return all.first { !$0.baseURL.isEmpty && AIEndpoint.normalizedBase($0.baseURL) == normalized }
            ?? custom
    }
}

/// Turns whatever the reader typed into the URLs the app actually calls.
///
/// The reader is asked for a *base*, because that is what every provider's own documentation
/// calls it, and because `/models` cannot be derived from a full `/chat/completions` URL
/// without this kind of guessing anyway. Pasting the full completions URL still works — that
/// is what most people have on their clipboard.
enum AIEndpoint {
    private static let chatSuffix = "/chat/completions"

    /// Strips a trailing slash, and a trailing `/chat/completions` if one was pasted.
    static func normalizedBase(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix(chatSuffix) {
            text.removeLast(chatSuffix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func chatCompletionsURL(base: String) -> URL? {
        let normalized = normalizedBase(base)
        guard !normalized.isEmpty else { return nil }
        guard let url = URL(string: normalized + chatSuffix), url.scheme != nil else { return nil }
        return url
    }

    static func modelsURL(base: String) -> URL? {
        let normalized = normalizedBase(base)
        guard !normalized.isEmpty else { return nil }
        guard let url = URL(string: normalized + "/models"), url.scheme != nil else { return nil }
        return url
    }
}
