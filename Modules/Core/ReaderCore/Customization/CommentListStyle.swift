import Foundation

/// How the App's own comment list (評論列表) draws a comment — the list a module's comments,
/// and a 來源配置's taken-over comment page, open in. Part of the 段評氣泡 row of 排版生效範圍,
/// so a theme pack carries it and it syncs with the reading setup
/// (`AppearanceThemeReadingSettings.CommentBubble.list`).
///
/// Two layers: the sliders and switches of 評論列表, then a stylesheet in the dialect
/// `CommentListCSS` reads. A value set on a slider wins over the stylesheet's; a value
/// neither sets is the App's own. Everything is optional, so a style that sets nothing
/// draws the list exactly as the App does.
struct CommentListStyle: Codable, Hashable, Sendable {
    /// The card's fill: the text colour at this opacity.
    var cardOpacity: Double?
    var cornerRadius: Double?
    var avatarSize: Double?
    var nameFontSize: Double?
    var contentFontSize: Double?
    var metaFontSize: Double?
    /// Points between the lines of a comment's words.
    var lineSpacing: Double?
    /// How many replies a comment shows under it before 查看全部.
    var inlineReplies: Int?
    /// The parts not drawn.
    var hiddenParts: Set<CommentListPart>?
    /// The stylesheet, as written: what this build does not read stays in it, so a pack
    /// made by a later build keeps its look when it comes back.
    var css: String?

    static let cardOpacityRange: ClosedRange<Double> = 0...0.3
    static let cornerRadiusRange: ClosedRange<Double> = 0...28
    static let avatarSizeRange: ClosedRange<Double> = 20...60
    static let nameFontSizeRange: ClosedRange<Double> = 10...20
    static let contentFontSizeRange: ClosedRange<Double> = 12...22
    static let metaFontSizeRange: ClosedRange<Double> = 9...16
    static let lineSpacingRange: ClosedRange<Double> = 0...14
    static let inlineRepliesRange: ClosedRange<Int> = 0...10
    /// A theme pack is someone else's file: its stylesheet is bounded before it is read.
    static let cssLimit = 8_000

    init(cardOpacity: Double? = nil, cornerRadius: Double? = nil, avatarSize: Double? = nil,
         nameFontSize: Double? = nil, contentFontSize: Double? = nil, metaFontSize: Double? = nil,
         lineSpacing: Double? = nil, inlineReplies: Int? = nil, hiddenParts: Set<CommentListPart>? = nil,
         css: String? = nil) {
        self.cardOpacity = cardOpacity
        self.cornerRadius = cornerRadius
        self.avatarSize = avatarSize
        self.nameFontSize = nameFontSize
        self.contentFontSize = contentFontSize
        self.metaFontSize = metaFontSize
        self.lineSpacing = lineSpacing
        self.inlineReplies = inlineReplies
        self.hiddenParts = hiddenParts
        self.css = css
    }

    /// Every value inside its range, the stylesheet inside its bound, nothing empty kept.
    var sanitized: CommentListStyle {
        func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        let sheet = css.map { String($0.prefix(Self.cssLimit)) }
        return CommentListStyle(
            cardOpacity: clamp(cardOpacity, Self.cardOpacityRange),
            cornerRadius: clamp(cornerRadius, Self.cornerRadiusRange),
            avatarSize: clamp(avatarSize, Self.avatarSizeRange),
            nameFontSize: clamp(nameFontSize, Self.nameFontSizeRange),
            contentFontSize: clamp(contentFontSize, Self.contentFontSizeRange),
            metaFontSize: clamp(metaFontSize, Self.metaFontSizeRange),
            lineSpacing: clamp(lineSpacing, Self.lineSpacingRange),
            inlineReplies: inlineReplies.map { min(max($0, Self.inlineRepliesRange.lowerBound), Self.inlineRepliesRange.upperBound) },
            hiddenParts: hiddenParts.flatMap { $0.isEmpty ? nil : $0 },
            css: sheet.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    /// Whether `part` is drawn, as the switches have it.
    func shows(_ part: CommentListPart) -> Bool {
        !(hiddenParts?.contains(part) ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case cardOpacity, cornerRadius, avatarSize, nameFontSize, contentFontSize, metaFontSize, lineSpacing,
             inlineReplies, hiddenParts, css
    }

    /// Value by value: one a later build writes differently costs that value alone, never the
    /// whole 段評氣泡 setup it travels in. A part this build does not know is skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: key) }
        cardOpacity = number(.cardOpacity)
        cornerRadius = number(.cornerRadius)
        avatarSize = number(.avatarSize)
        nameFontSize = number(.nameFontSize)
        contentFontSize = number(.contentFontSize)
        metaFontSize = number(.metaFontSize)
        lineSpacing = number(.lineSpacing)
        inlineReplies = try? c.decodeIfPresent(Int.self, forKey: .inlineReplies)
        let parts = (try? c.decodeIfPresent([String].self, forKey: .hiddenParts)) ?? nil
        hiddenParts = parts.map { Set($0.compactMap(CommentListPart.init(rawValue:))) }
        css = try? c.decodeIfPresent(String.self, forKey: .css)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cardOpacity, forKey: .cardOpacity)
        try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try c.encodeIfPresent(avatarSize, forKey: .avatarSize)
        try c.encodeIfPresent(nameFontSize, forKey: .nameFontSize)
        try c.encodeIfPresent(contentFontSize, forKey: .contentFontSize)
        try c.encodeIfPresent(metaFontSize, forKey: .metaFontSize)
        try c.encodeIfPresent(lineSpacing, forKey: .lineSpacing)
        try c.encodeIfPresent(inlineReplies, forKey: .inlineReplies)
        try c.encodeIfPresent(hiddenParts.map { $0.map(\.rawValue).sorted() }, forKey: .hiddenParts)
        try c.encodeIfPresent(css, forKey: .css)
    }
}

/// A part of a comment card that 評論列表 can hide.
enum CommentListPart: String, Codable, CaseIterable, Identifiable, Sendable {
    case avatar, badge, author, floor, quote, images, voice, meta, likes

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .avatar: return "頭像"
        case .badge: return "粉絲稱號"
        case .author: return "作者標記"
        case .floor: return "樓層"
        case .quote: return "段落原文引用"
        case .images: return "配圖"
        case .voice: return "語音"
        case .meta: return "時間與 IP 屬地"
        case .likes: return "讚數"
        }
    }

    var systemImage: String {
        switch self {
        case .avatar: return "person.crop.circle"
        case .badge: return "rosette"
        case .author: return "pencil.line"
        case .floor: return "number"
        case .quote: return "text.quote"
        case .images: return "photo"
        case .voice: return "waveform"
        case .meta: return "clock"
        case .likes: return "hand.thumbsup"
        }
    }
}
