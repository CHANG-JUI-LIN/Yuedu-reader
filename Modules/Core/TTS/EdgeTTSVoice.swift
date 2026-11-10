import Foundation

struct EdgeTTSVoice: Identifiable, Equatable, Sendable {
    let id: String
    let nameKey: String
    /// What 多角色朗讀's automatic casting matches a character against.
    var gender: TTSVoiceGender = .unknown
    var age: TTSVoiceAge = .unknown

    var displayName: String { localized(nameKey) }
    var sourceIdentifier: String { Self.sourcePrefix + id }

    /// Voices that can read the same text interchangeably. Mandarin voices from Taiwan and
    /// the mainland can share a cast; a Cantonese or English voice reading Mandarin cannot.
    var languageGroup: String { TTSLanguageGroup.of(locale: id) }

    // An internal identifier, never an HTTP template or an imported/deletable source.
    static let sourcePrefix = "yuedu-edge-tts:"
    static let voices: [EdgeTTSVoice] = [
        .init(id: "zh-TW-HsiaoChenNeural", nameKey: "曉臻・台灣華語・女聲", gender: .female, age: .adult),
        .init(id: "zh-TW-HsiaoYuNeural", nameKey: "曉雨・台灣華語・女聲", gender: .female, age: .young),
        .init(id: "zh-TW-YunJheNeural", nameKey: "雲哲・台灣華語・男聲", gender: .male, age: .adult),
        .init(id: "zh-CN-XiaoxiaoNeural", nameKey: "曉曉・普通話・女聲", gender: .female, age: .young),
        .init(id: "zh-CN-XiaoyiNeural", nameKey: "曉伊・普通話・女聲", gender: .female, age: .young),
        .init(id: "zh-CN-YunxiNeural", nameKey: "雲希・普通話・男聲", gender: .male, age: .young),
        .init(id: "zh-CN-YunjianNeural", nameKey: "雲健・普通話・男聲", gender: .male, age: .adult),
        .init(id: "zh-CN-YunyangNeural", nameKey: "雲揚・普通話・男聲", gender: .male, age: .adult),
        .init(id: "zh-CN-YunxiaNeural", nameKey: "雲夏・普通話・男童", gender: .male, age: .child),
        .init(id: "zh-HK-HiuGaaiNeural", nameKey: "曉佳・粵語・女聲", gender: .female, age: .adult),
        .init(id: "zh-HK-WanLungNeural", nameKey: "雲龍・粵語・男聲", gender: .male, age: .adult),
        .init(id: "en-US-AriaNeural", nameKey: "Aria・美式英語・女聲", gender: .female, age: .adult),
        .init(id: "en-US-GuyNeural", nameKey: "Guy・美式英語・男聲", gender: .male, age: .adult),
    ]
    static let defaultVoice = voices[0]

    static func voice(id: String) -> EdgeTTSVoice? {
        voices.first { $0.id == id }
    }

    static func isEdgeSource(_ identifier: String) -> Bool {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(sourcePrefix)
    }

    static func voice(sourceIdentifier: String) -> EdgeTTSVoice? {
        let identifier = sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEdgeSource(identifier) else { return nil }
        return voice(id: String(identifier.dropFirst(sourcePrefix.count)))
    }
}

/// Which voices can stand in for one another on the same text.
enum TTSLanguageGroup {
    /// `cmn` for Mandarin (mainland, Taiwan, Singapore), `yue` for Cantonese, else the base
    /// language. Accepts a BCP-47 tag or a voice id that starts with one (`zh-TW-HsiaoYuNeural`).
    static func of(locale: String) -> String {
        let lower = locale.lowercased()
        if lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") || lower.hasPrefix("yue") {
            return "yue"
        }
        if lower.hasPrefix("wuu") { return "wuu" }
        if lower.hasPrefix("zh") || lower.hasPrefix("cmn") { return "cmn" }
        return String(lower.split(separator: "-").first ?? "")
    }
}
