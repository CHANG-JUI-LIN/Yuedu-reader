import CoreGraphics
import Foundation

/// The sticker a bubble can wear, and the palette rotation that picks its
/// colours — the `decorations` / `variants` half of the script-based bubble
/// styles, expressed natively.
///
/// Both are *per utterance*: which palette a bubble gets, and where its sticker
/// sits, are derived from the bubble's own text and its index in the chapter.
/// The derivation is reproduced exactly (same FNV-1a hash, same modulo, same
/// jitter) so an imported style keeps looking like the file it came from
/// instead of merely resembling it.
enum ReaderDialogueBubbleDecorationKind: String, Codable, CaseIterable, Sendable {
    case star
    case heart
    case flower
    case dot
    case bow

    var localizedNameKey: String {
        switch self {
        case .star: return "裝飾・星星"
        case .heart: return "裝飾・愛心"
        case .flower: return "裝飾・小花"
        case .dot: return "裝飾・圓點"
        case .bow: return "裝飾・蝴蝶結"
        }
    }
}

/// Where the sticker sits on the bubble's box.
enum ReaderDialogueBubbleAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft = "top-left"
    case top
    case topRight = "top-right"
    case right
    case bottomRight = "bottom-right"
    case bottom
    case bottomLeft = "bottom-left"
    case left

    /// Fractions of the bubble box, measured from its top-left. `outside`
    /// stickers hang on the corner itself; inset ones move 28% in.
    func place(outside: Bool) -> CGPoint {
        let edge: CGFloat = outside ? 0 : 0.28
        switch self {
        case .topLeft: return CGPoint(x: edge, y: edge)
        case .top: return CGPoint(x: 0.5, y: edge)
        case .topRight: return CGPoint(x: 1 - edge, y: edge)
        case .right: return CGPoint(x: 1 - edge, y: 0.5)
        case .bottomRight: return CGPoint(x: 1 - edge, y: 1 - edge)
        case .bottom: return CGPoint(x: 0.5, y: 1 - edge)
        case .bottomLeft: return CGPoint(x: edge, y: 1 - edge)
        case .left: return CGPoint(x: edge, y: 0.5)
        }
    }

    /// Jitter runs along the edge the anchor sits on.
    var jittersHorizontally: Bool { self == .top || self == .bottom }

    /// The anchors `text-index` may drift to — always neighbours on the same
    /// edge, so a sticker never jumps to the far side of the bubble.
    var neighbours: [ReaderDialogueBubbleAnchor] {
        switch self {
        case .top: return [.topLeft, .top, .topRight]
        case .topLeft: return [.topLeft, .top]
        case .topRight: return [.top, .topRight]
        case .bottom: return [.bottomLeft, .bottom, .bottomRight]
        case .bottomLeft: return [.bottomLeft, .bottom]
        case .bottomRight: return [.bottom, .bottomRight]
        case .left: return [.topLeft, .left, .bottomLeft]
        case .right: return [.topRight, .right, .bottomRight]
        }
    }
}

/// How a per-bubble choice is derived.
enum ReaderDialogueBubbleVariation: String, Codable, CaseIterable, Sendable {
    /// Always the same.
    case fixed
    /// Hashed from the text, so the same line always looks the same.
    case text
    /// Hashed from the text *and* its position, so repeated lines still differ.
    case textIndex = "text-index"
    /// Straight rotation through the options.
    case cycle
}

struct ReaderDialogueBubbleDecoration: Codable, Equatable, Sendable {
    var kind: ReaderDialogueBubbleDecorationKind
    var anchor: ReaderDialogueBubbleAnchor
    var sizeEm: Double
    var offsetXEm: Double
    var offsetYEm: Double
    var rotationDegrees: Double
    var colorHex: UInt32
    var opacity: Double
    /// Outside stickers overhang the bubble and get a cut-out rim in the bubble
    /// colour, so they read as stuck on rather than drawn in.
    var isOutside: Bool
    var variation: ReaderDialogueBubbleVariation

    init(
        kind: ReaderDialogueBubbleDecorationKind = .star,
        anchor: ReaderDialogueBubbleAnchor = .topRight,
        sizeEm: Double = 0.8,
        offsetXEm: Double = 0,
        offsetYEm: Double = 0,
        rotationDegrees: Double = 0,
        colorHex: UInt32 = 0xFFC857,
        opacity: Double = 1,
        isOutside: Bool = true,
        variation: ReaderDialogueBubbleVariation = .text
    ) {
        self.kind = kind
        self.anchor = anchor
        self.sizeEm = sizeEm
        self.offsetXEm = offsetXEm
        self.offsetYEm = offsetYEm
        self.rotationDegrees = rotationDegrees
        self.colorHex = colorHex & 0xFFFFFF
        self.opacity = opacity
        self.isOutside = isOutside
        self.variation = variation
    }

    func sanitized() -> ReaderDialogueBubbleDecoration {
        ReaderDialogueBubbleDecoration(
            kind: kind,
            anchor: anchor,
            sizeEm: ReaderDialogueBubbleMetric.clamp(sizeEm, 0.1...4, 0.8),
            offsetXEm: ReaderDialogueBubbleMetric.clamp(offsetXEm, -3...3, 0),
            offsetYEm: ReaderDialogueBubbleMetric.clamp(offsetYEm, -3...3, 0),
            rotationDegrees: ReaderDialogueBubbleMetric.clamp(rotationDegrees, -180...180, 0),
            colorHex: colorHex,
            opacity: ReaderDialogueBubbleMetric.clamp(opacity, 0...1, 1),
            isOutside: isOutside,
            variation: variation
        )
    }
}

struct ReaderDialogueBubbleVariantItem: Codable, Equatable, Sendable {
    var fillHex: UInt32
    var borderHex: UInt32?
    var textHex: UInt32?
    var decorationKind: ReaderDialogueBubbleDecorationKind?

    init(
        fillHex: UInt32,
        borderHex: UInt32? = nil,
        textHex: UInt32? = nil,
        decorationKind: ReaderDialogueBubbleDecorationKind? = nil
    ) {
        self.fillHex = fillHex & 0xFFFFFF
        self.borderHex = borderHex.map { $0 & 0xFFFFFF }
        self.textHex = textHex.map { $0 & 0xFFFFFF }
        self.decorationKind = decorationKind
    }
}

struct ReaderDialogueBubbleVariants: Codable, Equatable, Sendable {
    enum Selection: String, Codable, CaseIterable, Sendable {
        case text
        case textIndex = "text-index"
        case cycle
        case length
        case punctuation
    }

    var selection: Selection
    var items: [ReaderDialogueBubbleVariantItem]

    init(selection: Selection = .text, items: [ReaderDialogueBubbleVariantItem]) {
        self.selection = selection
        self.items = items
    }

    func sanitized() -> ReaderDialogueBubbleVariants? {
        guard !items.isEmpty else { return nil }
        return ReaderDialogueBubbleVariants(
            selection: selection,
            items: Array(items.prefix(16))
        )
    }
}

/// Resolves the per-utterance choices. Kept separate from the styles so the
/// derivation can be tested against the script's own numbers.
enum ReaderDialogueBubbleVariantResolver {
    /// FNV-1a over `"<text>|<index>"`, UTF-16 code unit by code unit — the same
    /// hash the script uses, so an imported style picks the same palette for the
    /// same line.
    static func hash(text: String, index: Int) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in "\(text)|\(index)".utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return hash
    }

    static func variant(
        _ variants: ReaderDialogueBubbleVariants?,
        text: String,
        index: Int
    ) -> ReaderDialogueBubbleVariantItem? {
        guard let variants, !variants.items.isEmpty else { return nil }
        let hashed = hash(text: text, index: variants.selection == .text ? 0 : index)
        let pick: Int
        switch variants.selection {
        case .cycle: pick = index
        case .length: pick = text.count
        case .punctuation:
            if text.hasSuffix("？") || text.hasSuffix("?") {
                pick = 1
            } else if text.hasSuffix("！") || text.hasSuffix("!") {
                pick = 2
            } else {
                pick = 0
            }
        case .text, .textIndex: pick = Int(hashed % UInt32(variants.items.count))
        }
        return variants.items[abs(pick) % variants.items.count]
    }

    /// Applies the sticker's own variation: the wobble in position and angle
    /// that keeps a repeated shape from looking stamped.
    static func decoration(
        _ decoration: ReaderDialogueBubbleDecoration?,
        kindOverride: ReaderDialogueBubbleDecorationKind?,
        text: String,
        index: Int
    ) -> ResolvedDecoration? {
        guard let decoration else { return nil }
        var anchor = decoration.anchor
        var rotation = decoration.rotationDegrees
        var jitterEm = 0.0

        switch decoration.variation {
        case .fixed:
            break
        case .text, .textIndex:
            let hashed = hash(
                text: text,
                index: decoration.variation == .text ? 0 : index
            )
            jitterEm = (Double(hashed % 9) - 4) * decoration.sizeEm * 0.035
            rotation += Double((hashed >> 4) % 19) - 9
            if decoration.variation == .textIndex {
                let options = anchor.neighbours
                anchor = options[Int((hashed >> 8) % UInt32(options.count))]
            }
        case .cycle:
            let cycle: [ReaderDialogueBubbleAnchor] = [
                .topLeft, .topRight, .bottomRight, .bottomLeft,
            ]
            anchor = cycle[abs(index) % cycle.count]
            rotation += index % 2 == 0 ? -10 : 10
        }

        return ResolvedDecoration(
            kind: kindOverride ?? decoration.kind,
            anchor: anchor,
            sizeEm: decoration.sizeEm,
            offsetXEm: decoration.offsetXEm,
            offsetYEm: decoration.offsetYEm,
            jitterEm: jitterEm,
            rotationDegrees: rotation,
            colorHex: decoration.colorHex,
            opacity: decoration.opacity,
            isOutside: decoration.isOutside
        )
    }

    struct ResolvedDecoration: Equatable, Sendable {
        var kind: ReaderDialogueBubbleDecorationKind
        var anchor: ReaderDialogueBubbleAnchor
        var sizeEm: Double
        var offsetXEm: Double
        var offsetYEm: Double
        var jitterEm: Double
        var rotationDegrees: Double
        var colorHex: UInt32
        var opacity: Double
        var isOutside: Bool
    }
}
