import Foundation

enum ReaderOverlayComponentKind: String, CaseIterable, Codable, Equatable, Sendable {
    case bookTitle
    case chapterTitle
    case chapterPage
    case totalProgressText
    case progressBar
    case currentTime
    case currentDate
    case weekday
    case battery
    case readingDuration
    case remainingTime
    case customText
}

struct ReaderOverlayNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var clamped: ReaderOverlayNormalizedPoint {
        ReaderOverlayNormalizedPoint(
            x: Self.clamp(x, fallback: 0.5, to: 0...1),
            y: Self.clamp(y, fallback: 0.5, to: 0...1)
        )
    }

    private static func clamp(
        _ value: Double,
        fallback: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum ReaderOverlayFontSourceKind: String, Codable, Equatable, Sendable {
    case system
    case reader
    case imported
}

struct ReaderOverlayFontReference: Codable, Equatable, Sendable {
    var kind: ReaderOverlayFontSourceKind
    var postScriptName: String?

    init(kind: ReaderOverlayFontSourceKind, postScriptName: String? = nil) {
        self.kind = kind
        self.postScriptName = postScriptName
    }

    var normalized: ReaderOverlayFontReference {
        guard kind == .imported else {
            return ReaderOverlayFontReference(kind: kind, postScriptName: nil)
        }
        let trimmedName = postScriptName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReaderOverlayFontReference(
            kind: kind,
            postScriptName: trimmedName?.isEmpty == false ? trimmedName : nil
        )
    }
}

enum ReaderOverlayFontWeight: String, Codable, Equatable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

enum ReaderOverlayColorSource: String, Codable, Equatable, Sendable {
    case readerText
    case custom
}

struct ReaderOverlayColorReference: Codable, Equatable, Sendable {
    var source: ReaderOverlayColorSource
    var hexRGBA: UInt32?

    init(source: ReaderOverlayColorSource, hexRGBA: UInt32? = nil) {
        self.source = source
        self.hexRGBA = hexRGBA
    }

    var normalized: ReaderOverlayColorReference {
        guard source == .custom else {
            return ReaderOverlayColorReference(source: source, hexRGBA: nil)
        }
        return ReaderOverlayColorReference(
            source: source,
            hexRGBA: hexRGBA
        )
    }
}

struct ReaderOverlayComponentStyle: Codable, Equatable, Sendable {
    static let defaultFontSize = 12.0
    static let defaultOpacity = 0.72

    var font: ReaderOverlayFontReference
    var fontSize: Double
    var fontWeight: ReaderOverlayFontWeight
    var color: ReaderOverlayColorReference
    var opacity: Double

    init(
        font: ReaderOverlayFontReference = ReaderOverlayFontReference(kind: .system),
        fontSize: Double = ReaderOverlayComponentStyle.defaultFontSize,
        fontWeight: ReaderOverlayFontWeight = .regular,
        color: ReaderOverlayColorReference = ReaderOverlayColorReference(source: .readerText),
        opacity: Double = ReaderOverlayComponentStyle.defaultOpacity
    ) {
        self.font = font
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.opacity = opacity
    }

    var normalized: ReaderOverlayComponentStyle {
        ReaderOverlayComponentStyle(
            font: font.normalized,
            fontSize: Self.clamp(fontSize, fallback: Self.defaultFontSize, to: 8...72),
            fontWeight: fontWeight,
            color: color.normalized,
            opacity: Self.clamp(opacity, fallback: Self.defaultOpacity, to: 0.1...1)
        )
    }

    private static func clamp(
        _ value: Double,
        fallback: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case font
        case fontSize
        case fontWeight
        case color
        case opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        font = try container.decodeIfPresent(ReaderOverlayFontReference.self, forKey: .font)
            ?? ReaderOverlayFontReference(kind: .system)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
            ?? Self.defaultFontSize
        fontWeight = try container.decodeIfPresent(ReaderOverlayFontWeight.self, forKey: .fontWeight)
            ?? .regular
        color = try container.decodeIfPresent(ReaderOverlayColorReference.self, forKey: .color)
            ?? ReaderOverlayColorReference(source: .readerText)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
            ?? Self.defaultOpacity
    }
}

enum ReaderOverlayDisplayFormat: String, CaseIterable, Codable, Equatable, Sendable {
    case automatic
    case compact
    case detailed
    case fraction
    case percentage
    case hourMinute24
    case hourMinute12
}

enum ReaderBatteryVisualKind: String, Codable, Equatable, Sendable {
    case system
    case importedSVG
}

struct ReaderOverlayComponentConfiguration: Codable, Equatable, Sendable {
    var displayFormat: ReaderOverlayDisplayFormat
    var customText: String
    var batteryVisual: ReaderBatteryVisualKind
    var svgAssetID: UUID?
    var showsBatteryPercentage: Bool

    init(
        displayFormat: ReaderOverlayDisplayFormat = .automatic,
        customText: String = "",
        batteryVisual: ReaderBatteryVisualKind = .system,
        svgAssetID: UUID? = nil,
        showsBatteryPercentage: Bool = false
    ) {
        self.displayFormat = displayFormat
        self.customText = customText
        self.batteryVisual = batteryVisual
        self.svgAssetID = svgAssetID
        self.showsBatteryPercentage = showsBatteryPercentage
    }

    var normalized: ReaderOverlayComponentConfiguration {
        ReaderOverlayComponentConfiguration(
            displayFormat: displayFormat,
            customText: customText,
            batteryVisual: batteryVisual,
            svgAssetID: batteryVisual == .importedSVG ? svgAssetID : nil,
            showsBatteryPercentage: showsBatteryPercentage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case displayFormat
        case customText
        case batteryVisual
        case svgAssetID
        case showsBatteryPercentage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayFormat = try container.decodeIfPresent(ReaderOverlayDisplayFormat.self, forKey: .displayFormat)
            ?? .automatic
        customText = try container.decodeIfPresent(String.self, forKey: .customText) ?? ""
        batteryVisual = try container.decodeIfPresent(ReaderBatteryVisualKind.self, forKey: .batteryVisual)
            ?? .system
        svgAssetID = try container.decodeIfPresent(UUID.self, forKey: .svgAssetID)
        showsBatteryPercentage = try container.decodeIfPresent(Bool.self, forKey: .showsBatteryPercentage)
            ?? false
    }
}

struct ReaderOverlayComponent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: ReaderOverlayComponentKind
    var position: ReaderOverlayNormalizedPoint
    var style: ReaderOverlayComponentStyle
    var configuration: ReaderOverlayComponentConfiguration

    init(
        id: UUID,
        kind: ReaderOverlayComponentKind,
        position: ReaderOverlayNormalizedPoint,
        style: ReaderOverlayComponentStyle = ReaderOverlayComponentStyle(),
        configuration: ReaderOverlayComponentConfiguration = ReaderOverlayComponentConfiguration()
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.style = style
        self.configuration = configuration
    }

    static func make(
        kind: ReaderOverlayComponentKind,
        position: ReaderOverlayNormalizedPoint
    ) -> ReaderOverlayComponent {
        ReaderOverlayComponent(id: UUID(), kind: kind, position: position).normalized
    }

    var normalized: ReaderOverlayComponent {
        ReaderOverlayComponent(
            id: id,
            kind: kind,
            position: position.clamped,
            style: style.normalized,
            configuration: configuration.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case position
        case style
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ReaderOverlayComponentKind.self, forKey: .kind)
        position = try container.decodeIfPresent(ReaderOverlayNormalizedPoint.self, forKey: .position)
            ?? ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        style = try container.decodeIfPresent(ReaderOverlayComponentStyle.self, forKey: .style)
            ?? ReaderOverlayComponentStyle()
        configuration = try container.decodeIfPresent(
            ReaderOverlayComponentConfiguration.self,
            forKey: .configuration
        ) ?? ReaderOverlayComponentConfiguration()
    }
}

struct ReaderOverlayContentReservations: Codable, Equatable, Sendable {
    var top: Double
    var bottom: Double

    init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }

    var normalized: ReaderOverlayContentReservations {
        ReaderOverlayContentReservations(
            top: Self.clamp(top),
            bottom: Self.clamp(bottom)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 120)
    }

    private enum CodingKeys: String, CodingKey {
        case top
        case bottom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 0
        bottom = try container.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
    }
}

struct ReaderOverlayLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var components: [ReaderOverlayComponent]
    var contentReservations: ReaderOverlayContentReservations

    static var `default`: ReaderOverlayLayout {
        ReaderOverlayLayoutMigration.defaultLayout
    }

    init(
        version: Int = ReaderOverlayLayout.currentVersion,
        components: [ReaderOverlayComponent],
        contentReservations: ReaderOverlayContentReservations
    ) {
        self.version = version
        self.components = components
        self.contentReservations = contentReservations
    }

    func normalized(preservingVersion: Bool = true) -> ReaderOverlayLayout {
        ReaderOverlayLayout(
            version: preservingVersion ? version : Self.currentVersion,
            components: components.map(\.normalized),
            contentReservations: contentReservations.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case components
        case contentReservations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        components = try container.decodeIfPresent([ReaderOverlayComponent].self, forKey: .components) ?? []
        contentReservations = try container.decodeIfPresent(
            ReaderOverlayContentReservations.self,
            forKey: .contentReservations
        ) ?? ReaderOverlayContentReservations(top: 0, bottom: 0)
    }
}
