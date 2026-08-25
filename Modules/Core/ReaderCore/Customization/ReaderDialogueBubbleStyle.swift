import Foundation

/// 對話氣泡 — the block-level form of the existing 對話 decoration. A dialogue
/// paragraph is laid out as a chat bubble on alternating sides instead of being
/// tinted in place by 對話文字高亮 / 對話底色框.
///
/// Every size here is a *ratio*, never a point value: horizontal placement is a
/// fraction of the text column, and everything belonging to the skin (padding,
/// corner radius, border, tail) is a multiple of the body font size. That is
/// what keeps a bubble correct at any type size, column width and device — the
/// script-generated bubbles this can be imported from bake a 1080px canvas into
/// an image instead, which is why their text stops tracking the reader's font.
struct ReaderDialogueBubbleStyle: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var isEnabled: Bool
    /// Side of the first dialogue in a chapter. Sides alternate from there when
    /// ``alternatesSides`` is on, so the "speaker" stays visually consistent
    /// within a back-and-forth exchange.
    var startSide: ReaderDialogueBubbleSide
    var alternatesSides: Bool
    /// Widest a bubble may get, as a fraction of the text column.
    var maxWidthRatio: Double
    /// Gap between the bubble and its side of the column, as a fraction of the
    /// column.
    var sideInsetRatio: Double
    /// Text inset inside the bubble, in multiples of the body font size.
    var horizontalPaddingEm: Double
    var verticalPaddingEm: Double
    /// Gap above and below a bubble, in multiples of the body font size.
    var spacingEm: Double
    /// Strips the enclosing 「」『』"" from the bubble's text — the bubble itself
    /// already marks it as speech.
    var removesQuotes: Bool
    /// Reads the speaker's name out of the narration around the quote and shows
    /// it above the bubble.
    var showsSpeakerName: Bool
    /// Keeps one speaker on one side for the whole chapter, instead of flipping
    /// on every utterance. Falls back to alternating when nobody is named.
    var sidesFollowSpeaker: Bool
    /// Merges consecutive quotes in one paragraph into a single bubble when only
    /// punctuation separates them (`「甲」，「乙」`).
    var mergesAdjacent: Bool
    var left: ReaderDialogueBubbleSideStyle
    var right: ReaderDialogueBubbleSideStyle

    init(
        version: Int = ReaderDialogueBubbleStyle.currentVersion,
        isEnabled: Bool = false,
        startSide: ReaderDialogueBubbleSide = .right,
        alternatesSides: Bool = true,
        maxWidthRatio: Double = 0.7,
        sideInsetRatio: Double = 0.03,
        horizontalPaddingEm: Double = 0.5,
        verticalPaddingEm: Double = 0.36,
        spacingEm: Double = 0.3,
        removesQuotes: Bool = true,
        showsSpeakerName: Bool = true,
        sidesFollowSpeaker: Bool = true,
        mergesAdjacent: Bool = true,
        left: ReaderDialogueBubbleSideStyle = .defaultLeft,
        right: ReaderDialogueBubbleSideStyle = .defaultRight
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.startSide = startSide
        self.alternatesSides = alternatesSides
        self.maxWidthRatio = maxWidthRatio
        self.sideInsetRatio = sideInsetRatio
        self.horizontalPaddingEm = horizontalPaddingEm
        self.verticalPaddingEm = verticalPaddingEm
        self.spacingEm = spacingEm
        self.removesQuotes = removesQuotes
        self.showsSpeakerName = showsSpeakerName
        self.sidesFollowSpeaker = sidesFollowSpeaker
        self.mergesAdjacent = mergesAdjacent
        self.left = left
        self.right = right
    }

    static let `default` = ReaderDialogueBubbleStyle()

    func side(_ side: ReaderDialogueBubbleSide) -> ReaderDialogueBubbleSideStyle {
        side == .left ? left : right
    }

    func sanitized() -> ReaderDialogueBubbleStyle {
        ReaderDialogueBubbleStyle(
            version: ReaderDialogueBubbleStyle.currentVersion,
            isEnabled: isEnabled,
            startSide: startSide,
            alternatesSides: alternatesSides,
            maxWidthRatio: ReaderDialogueBubbleMetric.clamp(maxWidthRatio, 0.3...1, 0.7),
            sideInsetRatio: ReaderDialogueBubbleMetric.clamp(sideInsetRatio, 0...0.4, 0.03),
            horizontalPaddingEm: ReaderDialogueBubbleMetric.clamp(horizontalPaddingEm, 0...4, 0.5),
            verticalPaddingEm: ReaderDialogueBubbleMetric.clamp(verticalPaddingEm, 0...4, 0.36),
            spacingEm: ReaderDialogueBubbleMetric.clamp(spacingEm, 0...4, 0.3),
            removesQuotes: removesQuotes,
            showsSpeakerName: showsSpeakerName,
            sidesFollowSpeaker: sidesFollowSpeaker,
            mergesAdjacent: mergesAdjacent,
            left: left.sanitized(),
            right: right.sanitized()
        )
    }
}

enum ReaderDialogueBubbleSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }
    var opposite: ReaderDialogueBubbleSide { self == .left ? .right : .left }
}

struct ReaderDialogueBubbleSideStyle: Codable, Equatable, Sendable {
    var fillHex: UInt32
    /// `nil` keeps the reader's own text color, which is what a translucent or
    /// image-skinned bubble usually wants.
    var textHex: UInt32?
    var borderHex: UInt32?
    var borderWidthEm: Double
    var cornerRadiusEm: Double
    var tail: ReaderDialogueBubbleTail?
    var skin: ReaderDialogueBubbleSkin?
    /// Typography inside the bubble. Sizes stay relative to the reading font so
    /// a bubble keeps tracking 字級 — the whole point of drawing it natively.
    var fontPostScriptName: String?
    var fontSizeMultiplier: Double
    var fontWeight: Int?
    var letterSpacingEm: Double
    /// How lines sit inside the bubble. `nil` follows the bubble's own side,
    /// which is what the chat templates do — a right bubble ragged-left.
    var textAlignment: ChapterTitleAlignment?
    /// Label used when no speaker can be read out of the narration.
    var name: String?
    var decoration: ReaderDialogueBubbleDecoration?
    var variants: ReaderDialogueBubbleVariants?
    var avatar: ReaderDialogueBubbleAvatar?

    init(
        fillHex: UInt32,
        textHex: UInt32? = nil,
        borderHex: UInt32? = nil,
        borderWidthEm: Double = 0,
        cornerRadiusEm: Double = 0.42,
        tail: ReaderDialogueBubbleTail? = .default,
        skin: ReaderDialogueBubbleSkin? = nil,
        fontPostScriptName: String? = nil,
        fontSizeMultiplier: Double = 1,
        fontWeight: Int? = nil,
        letterSpacingEm: Double = 0,
        textAlignment: ChapterTitleAlignment? = nil,
        name: String? = nil,
        decoration: ReaderDialogueBubbleDecoration? = nil,
        variants: ReaderDialogueBubbleVariants? = nil,
        avatar: ReaderDialogueBubbleAvatar? = nil
    ) {
        self.fillHex = fillHex & 0xFFFFFF
        self.textHex = textHex.map { $0 & 0xFFFFFF }
        self.borderHex = borderHex.map { $0 & 0xFFFFFF }
        self.borderWidthEm = borderWidthEm
        self.cornerRadiusEm = cornerRadiusEm
        self.tail = tail
        self.skin = skin
        self.fontPostScriptName = fontPostScriptName
        self.fontSizeMultiplier = fontSizeMultiplier
        self.fontWeight = fontWeight
        self.letterSpacingEm = letterSpacingEm
        self.textAlignment = textAlignment
        self.name = name
        self.decoration = decoration
        self.variants = variants
        self.avatar = avatar
    }

    static let defaultLeft = ReaderDialogueBubbleSideStyle(
        fillHex: 0xF1F2F4,
        textHex: 0x182012,
        borderHex: 0xD6D7DA,
        borderWidthEm: 0.03
    )

    static let defaultRight = ReaderDialogueBubbleSideStyle(
        fillHex: 0x95EC69,
        textHex: 0x182012,
        borderHex: 0x78CF50,
        borderWidthEm: 0.03
    )

    func sanitized() -> ReaderDialogueBubbleSideStyle {
        ReaderDialogueBubbleSideStyle(
            fillHex: fillHex,
            textHex: textHex,
            borderHex: borderHex,
            borderWidthEm: ReaderDialogueBubbleMetric.clamp(borderWidthEm, 0...1, 0),
            cornerRadiusEm: ReaderDialogueBubbleMetric.clamp(cornerRadiusEm, 0...4, 0.42),
            tail: tail?.sanitized(),
            skin: skin?.sanitized(),
            fontPostScriptName: fontPostScriptName,
            fontSizeMultiplier: ReaderDialogueBubbleMetric.clamp(fontSizeMultiplier, 0.5...2, 1),
            fontWeight: fontWeight.map { min(max($0, 100), 900) },
            letterSpacingEm: ReaderDialogueBubbleMetric.clamp(letterSpacingEm, -0.5...1, 0),
            textAlignment: textAlignment,
            name: name?.isEmpty == true ? nil : name,
            decoration: decoration?.sanitized(),
            variants: variants?.sanitized(),
            avatar: avatar?.sanitized()
        )
    }
}

/// A fixed portrait beside the bubble — one image per side, the way the
/// script-based bubbles do it.
struct ReaderDialogueBubbleAvatar: Codable, Equatable, Sendable {
    var assetID: UUID
    var sizeEm: Double
    var gapEm: Double
    var offsetXEm: Double
    var offsetYEm: Double
    var backgroundHex: UInt32?
    var borderHex: UInt32?
    var borderWidthEm: Double
    /// Circular by default, which is what every chat skin these come from uses.
    var cornerRadiusRatio: Double

    init(
        assetID: UUID,
        sizeEm: Double = 2,
        gapEm: Double = 0.3,
        offsetXEm: Double = 0,
        offsetYEm: Double = 0,
        backgroundHex: UInt32? = nil,
        borderHex: UInt32? = nil,
        borderWidthEm: Double = 0,
        cornerRadiusRatio: Double = 0.5
    ) {
        self.assetID = assetID
        self.sizeEm = sizeEm
        self.gapEm = gapEm
        self.offsetXEm = offsetXEm
        self.offsetYEm = offsetYEm
        self.backgroundHex = backgroundHex.map { $0 & 0xFFFFFF }
        self.borderHex = borderHex.map { $0 & 0xFFFFFF }
        self.borderWidthEm = borderWidthEm
        self.cornerRadiusRatio = cornerRadiusRatio
    }

    func sanitized() -> ReaderDialogueBubbleAvatar {
        ReaderDialogueBubbleAvatar(
            assetID: assetID,
            sizeEm: ReaderDialogueBubbleMetric.clamp(sizeEm, 0.5...6, 2),
            gapEm: ReaderDialogueBubbleMetric.clamp(gapEm, 0...2, 0.3),
            offsetXEm: ReaderDialogueBubbleMetric.clamp(offsetXEm, -3...3, 0),
            offsetYEm: ReaderDialogueBubbleMetric.clamp(offsetYEm, -3...3, 0),
            backgroundHex: backgroundHex,
            borderHex: borderHex,
            borderWidthEm: ReaderDialogueBubbleMetric.clamp(borderWidthEm, 0...0.5, 0),
            cornerRadiusRatio: ReaderDialogueBubbleMetric.clamp(cornerRadiusRatio, 0...0.5, 0.5)
        )
    }
}

/// The little pointer at the bottom of a bubble. All four numbers are multiples
/// of the body font size, measured the way the WeChat-style templates do:
/// `outside` is how far the tip sticks out past the bubble edge, `bottomOffset`
/// how far its base sits above the bubble's bottom corner.
struct ReaderDialogueBubbleTail: Codable, Equatable, Sendable {
    var widthEm: Double
    var heightEm: Double
    var outsideEm: Double
    var bottomOffsetEm: Double

    static let `default` = ReaderDialogueBubbleTail(
        widthEm: 0.48,
        heightEm: 0.33,
        outsideEm: 0.12,
        bottomOffsetEm: 0.2
    )

    func sanitized() -> ReaderDialogueBubbleTail {
        ReaderDialogueBubbleTail(
            widthEm: ReaderDialogueBubbleMetric.clamp(widthEm, 0...2, 0.48),
            heightEm: ReaderDialogueBubbleMetric.clamp(heightEm, 0...2, 0.33),
            outsideEm: ReaderDialogueBubbleMetric.clamp(outsideEm, 0...2, 0.12),
            bottomOffsetEm: ReaderDialogueBubbleMetric.clamp(bottomOffsetEm, 0...4, 0.2)
        )
    }
}

/// A nine-slice bubble skin: the image's corners stay their own size while the
/// edges and centre stretch to the bubble. `slices` are in the *source image's*
/// pixels, which is how every editor that exports these writes them.
struct ReaderDialogueBubbleSkin: Codable, Equatable, Sendable {
    var assetID: UUID
    var sliceTop: Double
    var sliceRight: Double
    var sliceBottom: Double
    var sliceLeft: Double
    /// How tall the artwork is meant to be, as a multiple of one line of text.
    /// The skins these come from are drawn for a single-line bubble, so tying
    /// the scale to the line height is what makes the corners land where the
    /// artist put them at any type size.
    var targetHeightScale: Double
    /// Extra scale on the corner slices only.
    var cornerScale: Double
    var opacity: Double

    init(
        assetID: UUID,
        sliceTop: Double = 0,
        sliceRight: Double = 0,
        sliceBottom: Double = 0,
        sliceLeft: Double = 0,
        targetHeightScale: Double = 1,
        cornerScale: Double = 1,
        opacity: Double = 1
    ) {
        self.assetID = assetID
        self.sliceTop = sliceTop
        self.sliceRight = sliceRight
        self.sliceBottom = sliceBottom
        self.sliceLeft = sliceLeft
        self.targetHeightScale = targetHeightScale
        self.cornerScale = cornerScale
        self.opacity = opacity
    }

    func sanitized() -> ReaderDialogueBubbleSkin {
        ReaderDialogueBubbleSkin(
            assetID: assetID,
            sliceTop: ReaderDialogueBubbleMetric.clamp(sliceTop, 0...4_096, 0),
            sliceRight: ReaderDialogueBubbleMetric.clamp(sliceRight, 0...4_096, 0),
            sliceBottom: ReaderDialogueBubbleMetric.clamp(sliceBottom, 0...4_096, 0),
            sliceLeft: ReaderDialogueBubbleMetric.clamp(sliceLeft, 0...4_096, 0),
            targetHeightScale: ReaderDialogueBubbleMetric.clamp(targetHeightScale, 0.25...4, 1),
            cornerScale: ReaderDialogueBubbleMetric.clamp(cornerScale, 0.25...2.5, 1),
            opacity: ReaderDialogueBubbleMetric.clamp(opacity, 0...1, 1)
        )
    }
}

enum ReaderDialogueBubbleMetric {
    static func clamp(
        _ value: Double,
        _ range: ClosedRange<Double>,
        _ fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
