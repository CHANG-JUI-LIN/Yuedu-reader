import Foundation

struct EdgeTTSVoice: Identifiable, Equatable, Sendable {
    let id: String
    let nameKey: String

    var displayName: String { localized(nameKey) }
    var sourceIdentifier: String { Self.sourcePrefix + id }

    // An internal identifier, never an HTTP template or an imported/deletable source.
    static let sourcePrefix = "yuedu-edge-tts:"
    static let voices: [EdgeTTSVoice] = [
        .init(id: "zh-TW-HsiaoChenNeural", nameKey: "曉臻・台灣華語・女聲"),
        .init(id: "zh-TW-HsiaoYuNeural", nameKey: "曉雨・台灣華語・女聲"),
        .init(id: "zh-TW-YunJheNeural", nameKey: "雲哲・台灣華語・男聲"),
        .init(id: "zh-CN-XiaoxiaoNeural", nameKey: "曉曉・普通話・女聲"),
        .init(id: "zh-CN-YunxiNeural", nameKey: "雲希・普通話・男聲"),
        .init(id: "zh-CN-YunjianNeural", nameKey: "雲健・普通話・男聲"),
        .init(id: "zh-HK-HiuGaaiNeural", nameKey: "曉佳・粵語・女聲"),
        .init(id: "zh-HK-WanLungNeural", nameKey: "雲龍・粵語・男聲"),
        .init(id: "en-US-AriaNeural", nameKey: "Aria・美式英語・女聲"),
        .init(id: "en-US-GuyNeural", nameKey: "Guy・美式英語・男聲"),
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
