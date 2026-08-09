import Foundation

struct ChapterTitleDesign: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultCanvasAspectRatio = 2.4
    static let defaultCanvasHeight = 112.0

    var version: Int
    var canvasAspectRatio: Double
    var canvasHeight: Double
    var layers: [ChapterTitleLayer]
    var legacySource: ChapterTitleLegacySource?

    init(
        version: Int = currentVersion,
        canvasAspectRatio: Double = defaultCanvasAspectRatio,
        canvasHeight: Double = defaultCanvasHeight,
        layers: [ChapterTitleLayer],
        legacySource: ChapterTitleLegacySource? = nil
    ) {
        self.version = version
        self.canvasAspectRatio = canvasAspectRatio
        self.canvasHeight = canvasHeight
        self.layers = layers
        self.legacySource = legacySource
    }

    static let `default` = ChapterTitleDesign(layers: [
        ChapterTitleLayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Chapter number",
            kind: .chapterNumber,
            frame: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.25),
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.number),
            lightStyle: .init(),
            darkStyle: .init()
        ),
        ChapterTitleLayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Chapter name",
            kind: .chapterName,
            frame: .init(x: 0.1, y: 0.4, width: 0.8, height: 0.4),
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.name),
            lightStyle: .init(),
            darkStyle: .init()
        ),
    ])

    func sanitized() -> ChapterTitleDesign {
        ChapterTitleDesign(
            version: max(0, version),
            canvasAspectRatio: ChapterTitleDesignSanitizer.clamp(
                canvasAspectRatio,
                to: 0.1...10,
                fallback: Self.defaultCanvasAspectRatio
            ),
            canvasHeight: ChapterTitleDesignSanitizer.clamp(
                canvasHeight,
                to: 1...2_048,
                fallback: Self.defaultCanvasHeight
            ),
            layers: layers.map { $0.sanitized() },
            legacySource: legacySource
        )
    }

    /// Maps the horizontal design onto the vertical-rl canvas with a clockwise
    /// axis rotation. Layer order and each layer's own rotation remain stable;
    /// only normalized canvas geometry and text flow change.
    func resolved(for writingMode: ReaderWritingMode) -> ChapterTitleDesign {
        var resolved = sanitized()
        let direction: ChapterTitleWritingDirection = writingMode.isVertical ? .vertical : .horizontal

        if writingMode.isVertical {
            resolved.canvasAspectRatio = 1 / resolved.canvasAspectRatio
            resolved.layers = resolved.layers.map { layer in
                var transformed = layer
                transformed.frame = ReaderStyleNormalizedRect(
                    x: 1 - layer.frame.y - layer.frame.height,
                    y: layer.frame.x,
                    width: layer.frame.height,
                    height: layer.frame.width
                )
                transformed.lightStyle.writingDirection = direction
                transformed.darkStyle.writingDirection = direction
                return transformed
            }
        } else {
            resolved.layers = resolved.layers.map { layer in
                var transformed = layer
                transformed.lightStyle.writingDirection = direction
                transformed.darkStyle.writingDirection = direction
                return transformed
            }
        }

        return resolved
    }
}

extension ChapterTitleDesign {
    private enum CodingKeys: String, CodingKey {
        case version
        case canvasAspectRatio
        case canvasHeight
        case layers
        case legacySource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = ChapterTitleDesign(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
            canvasAspectRatio: try container.decodeIfPresent(Double.self, forKey: .canvasAspectRatio)
                ?? Self.defaultCanvasAspectRatio,
            canvasHeight: try container.decodeIfPresent(Double.self, forKey: .canvasHeight)
                ?? Self.defaultCanvasHeight,
            layers: try container.decodeIfPresent([ChapterTitleLayer].self, forKey: .layers) ?? [],
            legacySource: try container.decodeIfPresent(ChapterTitleLegacySource.self, forKey: .legacySource)
        ).sanitized()
    }
}

struct ChapterTitleLegacySource: Codable, Equatable, Sendable {
    var light: String
    var dark: String
}

struct ChapterTitleLayer: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: ChapterTitleLayerKind
    var frame: ReaderStyleNormalizedRect
    var rotation: ReaderStyleRotation
    var isVisible: Bool
    var isLocked: Bool
    var content: ChapterTitleLayerContent
    var lightStyle: ChapterTitleLayerStyle
    var darkStyle: ChapterTitleLayerStyle

    fileprivate func sanitized() -> ChapterTitleLayer {
        ChapterTitleLayer(
            id: id,
            name: name,
            kind: kind,
            frame: ChapterTitleDesignSanitizer.rect(frame),
            rotation: ReaderStyleRotation(degrees: rotation.degrees),
            isVisible: isVisible,
            isLocked: isLocked,
            content: content.sanitized(),
            lightStyle: lightStyle.sanitized(),
            darkStyle: darkStyle.sanitized()
        )
    }
}

enum ChapterTitleLayerKind: String, Codable, Sendable {
    case chapterNumber
    case chapterName
    case originalTitle
    case customText
    case ornament
    case line
    case colorBlock
    case image
}

enum ChapterTitleLayerContent: Codable, Equatable, Sendable {
    case dynamic(ChapterTitleDynamicField)
    case text(String)
    case line(ChapterTitleLineStyle)
    case image(UUID)
    case none

    fileprivate func sanitized() -> ChapterTitleLayerContent {
        switch self {
        case .dynamic, .text, .image, .none:
            return self
        case let .line(style):
            return .line(style.sanitized())
        }
    }
}

enum ChapterTitleDynamicField: String, Codable, Sendable {
    case number
    case name
    case title
}

enum ChapterTitleWritingDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct ChapterTitleLayerStyle: Codable, Equatable, Sendable {
    var ruleStyle: ReaderStyleRuleStyle
    var textAlignment: ChapterTitleAlignment
    var writingDirection: ChapterTitleWritingDirection
    var imagePresentation: ReaderStyleImagePresentation?

    init(
        ruleStyle: ReaderStyleRuleStyle = .init(),
        textAlignment: ChapterTitleAlignment = .center,
        writingDirection: ChapterTitleWritingDirection = .horizontal,
        imagePresentation: ReaderStyleImagePresentation? = nil
    ) {
        self.ruleStyle = ruleStyle
        self.textAlignment = textAlignment
        self.writingDirection = writingDirection
        self.imagePresentation = imagePresentation
    }

    fileprivate func sanitized() -> ChapterTitleLayerStyle {
        ChapterTitleLayerStyle(
            ruleStyle: ChapterTitleDesignSanitizer.ruleStyle(ruleStyle),
            textAlignment: textAlignment,
            writingDirection: writingDirection,
            imagePresentation: imagePresentation.map(ChapterTitleDesignSanitizer.image)
        )
    }
}

extension ChapterTitleLayerStyle {
    private enum CodingKeys: String, CodingKey {
        case ruleStyle
        case textAlignment
        case writingDirection
        case imagePresentation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ruleStyle: try container.decodeIfPresent(ReaderStyleRuleStyle.self, forKey: .ruleStyle) ?? .init(),
            textAlignment: try container.decodeIfPresent(ChapterTitleAlignment.self, forKey: .textAlignment) ?? .center,
            writingDirection: try container.decodeIfPresent(ChapterTitleWritingDirection.self, forKey: .writingDirection)
                ?? .horizontal,
            imagePresentation: try container.decodeIfPresent(
                ReaderStyleImagePresentation.self,
                forKey: .imagePresentation
            )
        )
    }
}

struct ChapterTitleLineStyle: Codable, Equatable, Sendable {
    var width: Double
    var colorHex: UInt32
    var isDashed: Bool

    init(width: Double, colorHex: UInt32, isDashed: Bool) {
        self.width = width
        self.colorHex = colorHex
        self.isDashed = isDashed
    }

    fileprivate func sanitized() -> ChapterTitleLineStyle {
        ChapterTitleLineStyle(
            width: ChapterTitleDesignSanitizer.clamp(width, to: 0...256, fallback: 0),
            colorHex: colorHex & 0xFFFFFF,
            isDashed: isDashed
        )
    }
}

private enum ChapterTitleDesignSanitizer {
    static let metricRange = -2_048.0...2_048.0

    static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func optionalClamp(
        _ value: Double?,
        to range: ClosedRange<Double>
    ) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func rect(_ value: ReaderStyleNormalizedRect) -> ReaderStyleNormalizedRect {
        // HTML source stores normalized geometry as percentages with six decimal
        // places. Canonicalize to that same precision so edit -> source -> edit
        // is stable instead of reintroducing binary floating-point tails.
        let x = normalizedSourcePrecision(clamp(value.x, to: 0...1, fallback: 0))
        let y = normalizedSourcePrecision(clamp(value.y, to: 0...1, fallback: 0))
        let width = normalizedSourcePrecision(
            min(clamp(value.width, to: 0...1, fallback: 0.1), 1 - x)
        )
        let height = normalizedSourcePrecision(
            min(clamp(value.height, to: 0...1, fallback: 0.1), 1 - y)
        )
        return ReaderStyleNormalizedRect(x: x, y: y, width: width, height: height)
    }

    private static func normalizedSourcePrecision(_ value: Double) -> Double {
        (value * 100_000_000).rounded() / 100_000_000
    }

    static func ruleStyle(_ value: ReaderStyleRuleStyle) -> ReaderStyleRuleStyle {
        ReaderStyleRuleStyle(
            text: text(value.text),
            decoration: decoration(value.decoration)
        )
    }

    static func text(_ value: ReaderStyleTextStyle) -> ReaderStyleTextStyle {
        ReaderStyleTextStyle(
            colorHex: value.colorHex.map { $0 & 0xFFFFFF },
            fontPostScriptName: value.fontPostScriptName,
            fontSize: optionalClamp(value.fontSize, to: 0...2_048),
            fontWeight: value.fontWeight.map { min(max($0, 1), 1_000) },
            italic: value.italic,
            letterSpacing: optionalClamp(value.letterSpacing, to: -512...512),
            lineHeight: optionalClamp(value.lineHeight, to: 0...2_048),
            underline: value.underline,
            strikethrough: value.strikethrough
        )
    }

    static func decoration(_ value: ReaderStyleDecorationStyle) -> ReaderStyleDecorationStyle {
        ReaderStyleDecorationStyle(
            backgroundColorHex: value.backgroundColorHex.map { $0 & 0xFFFFFF },
            backgroundGradient: value.backgroundGradient.map(gradient),
            backgroundImage: value.backgroundImage.map(image),
            padding: value.padding.map(edges),
            margin: value.margin.map(edges),
            visualGap: optionalClamp(value.visualGap, to: 0...2_048),
            borders: value.borders.map { borders in
                Dictionary(uniqueKeysWithValues: borders.map { edge, border in
                    (edge, self.border(border))
                })
            },
            cornerRadius: optionalClamp(value.cornerRadius, to: 0...2_048),
            shadows: value.shadows.map(shadow),
            opacity: optionalClamp(value.opacity, to: 0...1)
        )
    }

    static func edges(_ value: ReaderStyleEdges) -> ReaderStyleEdges {
        ReaderStyleEdges(
            top: clamp(value.top, to: metricRange, fallback: 0),
            leading: clamp(value.leading, to: metricRange, fallback: 0),
            bottom: clamp(value.bottom, to: metricRange, fallback: 0),
            trailing: clamp(value.trailing, to: metricRange, fallback: 0)
        )
    }

    static func border(_ value: ReaderStyleBorder) -> ReaderStyleBorder {
        ReaderStyleBorder(
            width: clamp(value.width, to: 0...256, fallback: 0),
            colorHex: value.colorHex & 0xFFFFFF
        )
    }

    static func shadow(_ value: ReaderStyleShadow) -> ReaderStyleShadow {
        ReaderStyleShadow(
            colorHex: value.colorHex & 0xFFFFFF,
            radius: clamp(value.radius, to: 0...256, fallback: 0),
            x: clamp(value.x, to: metricRange, fallback: 0),
            y: clamp(value.y, to: metricRange, fallback: 0)
        )
    }

    static func gradient(_ value: ReaderStyleGradient) -> ReaderStyleGradient {
        ReaderStyleGradient(
            angleDegrees: ReaderStyleRotation(degrees: value.angleDegrees).degrees,
            stops: value.stops.map { stop in
                ReaderStyleGradientStop(
                    colorHex: stop.colorHex & 0xFFFFFF,
                    location: clamp(stop.location, to: 0...1, fallback: 0)
                )
            }
        )
    }

    static func image(_ value: ReaderStyleImagePresentation) -> ReaderStyleImagePresentation {
        ReaderStyleImagePresentation(
            assetID: value.assetID,
            contentMode: value.contentMode,
            focalX: clamp(value.focalX, to: 0...1, fallback: 0.5),
            focalY: clamp(value.focalY, to: 0...1, fallback: 0.5),
            opacity: clamp(value.opacity, to: 0...1, fallback: 1)
        )
    }
}
