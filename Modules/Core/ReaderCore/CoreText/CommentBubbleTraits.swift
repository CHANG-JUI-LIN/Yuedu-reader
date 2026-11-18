import Foundation

/// What a 段評 bubble says beside its count. Only a module's site says either (its `counts`
/// rules `hot` and `voice`); a 來源配置's bubble is an SVG or a `<comment count>` and says
/// neither.
/// Public as `RenderableNode.commentBadge` carries it.
public struct CommentBubbleTraits: Codable, Hashable, Sendable {
    /// The site marks the paragraph's comments as hot: the bubble wears the style's emphasis
    /// colour (maintainer 2026-11-17: 分色 follows what the site marks, not how many there are).
    public var isHot: Bool
    /// Among the paragraph's comments is a spoken one: the bubble is the style's voice version.
    public var hasVoice: Bool

    public init(isHot: Bool = false, hasVoice: Bool = false) {
        self.isHot = isHot
        self.hasVoice = hasVoice
    }

    public static let plain = CommentBubbleTraits()

    /// For an image cache key or a picture's name.
    var signature: String { "\(isHot ? "h" : "-")\(hasVoice ? "v" : "-")" }
}

/// The number a bubble shows: the count up to the reader's 數字上限, past it the limit and a
/// plus (`99+`, `999+`).
enum CommentBubbleCount {
    /// The limits 段評氣泡 › 數字上限 offers.
    static let maximumChoices = [99, 999]
    static let defaultMaximum = 99

    static func sanitizedMaximum(_ value: Int) -> Int {
        maximumChoices.contains(value) ? value : defaultMaximum
    }

    /// `raw` as a bubble shows it under `maximum`. Text that is not a plain number (a source's
    /// own `99+`) is shown as it is: the source chose it.
    static func displayText(_ raw: String, maximum: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), number >= 0 else { return raw }
        return number > maximum ? "\(maximum)+" : String(number)
    }
}
