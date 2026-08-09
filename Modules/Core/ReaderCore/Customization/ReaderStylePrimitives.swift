import CoreGraphics
import Foundation

struct ReaderStyleNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = Self.unit(x, fallback: 0)
        self.y = Self.unit(y, fallback: 0)
        self.width = Self.unit(width, fallback: 0.1)
        self.height = Self.unit(height, fallback: 0.1)
    }

    init(rect: CGRect, in canvas: CGRect) {
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0 else {
            self.init(x: 0, y: 0, width: 0.1, height: 0.1)
            return
        }
        self.init(
            x: (rect.minX - canvas.minX) / canvas.width,
            y: (rect.minY - canvas.minY) / canvas.height,
            width: rect.width / canvas.width,
            height: rect.height / canvas.height
        )
    }

    func denormalized(in canvas: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX + canvas.width * x,
            y: canvas.minY + canvas.height * y,
            width: canvas.width * width,
            height: canvas.height * height
        )
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

struct ReaderStyleRotation: Codable, Equatable, Sendable {
    var degrees: Double

    init(degrees: Double) {
        guard degrees.isFinite else {
            self.degrees = 0
            return
        }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        self.degrees = wrapped > 180 ? wrapped - 360 : (wrapped < -180 ? wrapped + 360 : wrapped)
    }
}

enum ReaderStyleAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}

struct ReaderStyleAppearanceValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var light: Value
    var dark: Value

    func resolve(for appearance: ReaderStyleAppearance) -> Value {
        appearance == .light ? light : dark
    }
}

struct ReaderStyleEdges: Codable, Equatable, Sendable {
    var top: Double
    var leading: Double
    var bottom: Double
    var trailing: Double

    init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = Self.finite(top)
        self.leading = Self.finite(leading)
        self.bottom = Self.finite(bottom)
        self.trailing = Self.finite(trailing)
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

struct ReaderStyleBorder: Codable, Equatable, Sendable {
    var width: Double
    var colorHex: UInt32

    init(width: Double = 0, colorHex: UInt32 = 0) {
        self.width = width.isFinite ? max(0, width) : 0
        self.colorHex = colorHex & 0xFFFFFF
    }
}

struct ReaderStyleShadow: Codable, Equatable, Sendable {
    var colorHex: UInt32
    var radius: Double
    var x: Double
    var y: Double

    init(colorHex: UInt32, radius: Double, x: Double, y: Double) {
        self.colorHex = colorHex & 0xFFFFFF
        self.radius = radius.isFinite ? max(0, radius) : 0
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }
}

struct ReaderStyleGradientStop: Codable, Equatable, Sendable {
    var colorHex: UInt32
    var location: Double

    init(colorHex: UInt32, location: Double) {
        self.colorHex = colorHex & 0xFFFFFF
        self.location = location.isFinite ? min(max(location, 0), 1) : 0
    }
}

struct ReaderStyleGradient: Codable, Equatable, Sendable {
    var angleDegrees: Double
    var stops: [ReaderStyleGradientStop]

    init(angleDegrees: Double, stops: [ReaderStyleGradientStop]) {
        self.angleDegrees = angleDegrees.isFinite ? angleDegrees : 0
        self.stops = stops
    }
}

enum ReaderStyleImageContentMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case tile
    case stretch
}

struct ReaderStyleImagePresentation: Codable, Equatable, Sendable {
    var assetID: UUID
    var contentMode: ReaderStyleImageContentMode
    var focalX: Double
    var focalY: Double
    var opacity: Double

    init(
        assetID: UUID,
        contentMode: ReaderStyleImageContentMode = .fill,
        focalX: Double = 0.5,
        focalY: Double = 0.5,
        opacity: Double = 1
    ) {
        self.assetID = assetID
        self.contentMode = contentMode
        self.focalX = Self.unit(focalX, fallback: 0.5)
        self.focalY = Self.unit(focalY, fallback: 0.5)
        self.opacity = Self.unit(opacity, fallback: 1)
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

struct ReaderStyleTextStyle: Codable, Equatable, Sendable {
    var colorHex: UInt32?
    var fontPostScriptName: String?
    var fontSize: Double?
    var fontWeight: Int?
    var italic: Bool?
    var letterSpacing: Double?
    var lineHeight: Double?
    var underline: Bool?
    var strikethrough: Bool?

    init(
        colorHex: UInt32? = nil,
        fontPostScriptName: String? = nil,
        fontSize: Double? = nil,
        fontWeight: Int? = nil,
        italic: Bool? = nil,
        letterSpacing: Double? = nil,
        lineHeight: Double? = nil,
        underline: Bool? = nil,
        strikethrough: Bool? = nil
    ) {
        self.colorHex = colorHex.map { $0 & 0xFFFFFF }
        self.fontPostScriptName = fontPostScriptName
        self.fontSize = Self.nonnegative(fontSize)
        self.fontWeight = fontWeight.map { min(max($0, 1), 1_000) }
        self.italic = italic
        self.letterSpacing = Self.finite(letterSpacing)
        self.lineHeight = Self.nonnegative(lineHeight)
        self.underline = underline
        self.strikethrough = strikethrough
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        finite(value).map { max(0, $0) }
    }
}

struct ReaderStyleDecorationStyle: Codable, Equatable, Sendable {
    var backgroundColorHex: UInt32?
    var backgroundGradient: ReaderStyleGradient?
    var backgroundImage: ReaderStyleImagePresentation?
    var padding: ReaderStyleEdges?
    var margin: ReaderStyleEdges?
    var visualGap: Double?
    var borders: [ReaderStyleEdge: ReaderStyleBorder]?
    var cornerRadius: Double?
    var shadows: [ReaderStyleShadow]
    var opacity: Double?

    init(
        backgroundColorHex: UInt32? = nil,
        backgroundGradient: ReaderStyleGradient? = nil,
        backgroundImage: ReaderStyleImagePresentation? = nil,
        padding: ReaderStyleEdges? = nil,
        margin: ReaderStyleEdges? = nil,
        visualGap: Double? = nil,
        borders: [ReaderStyleEdge: ReaderStyleBorder]? = nil,
        cornerRadius: Double? = nil,
        shadows: [ReaderStyleShadow] = [],
        opacity: Double? = nil
    ) {
        self.backgroundColorHex = backgroundColorHex.map { $0 & 0xFFFFFF }
        self.backgroundGradient = backgroundGradient
        self.backgroundImage = backgroundImage
        self.padding = padding
        self.margin = margin
        self.visualGap = Self.nonnegative(visualGap)
        self.borders = borders
        self.cornerRadius = Self.nonnegative(cornerRadius)
        self.shadows = shadows
        self.opacity = Self.unit(opacity)
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    private static func unit(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

enum ReaderStyleEdge: String, Codable, CaseIterable, Sendable {
    case top, leading, bottom, trailing
}

struct ReaderStyleRuleStyle: Codable, Equatable, Sendable {
    var text: ReaderStyleTextStyle
    var decoration: ReaderStyleDecorationStyle

    init(
        text: ReaderStyleTextStyle = .init(),
        decoration: ReaderStyleDecorationStyle = .init()
    ) {
        self.text = text
        self.decoration = decoration
    }
}

struct ReaderStyleContrastWarning: Equatable, Sendable {
    var ratio: Double
    let isBlocking = false
}

enum ReaderStyleContrastEvaluator {
    static func warning(
        foregroundHex: UInt32,
        backgroundHex: UInt32
    ) -> ReaderStyleContrastWarning? {
        let lighter = max(luminance(foregroundHex), luminance(backgroundHex))
        let darker = min(luminance(foregroundHex), luminance(backgroundHex))
        let ratio = (lighter + 0.05) / (darker + 0.05)
        return ratio < 4.5 ? ReaderStyleContrastWarning(ratio: ratio) : nil
    }

    private static func luminance(_ hex: UInt32) -> Double {
        let channels = [hex >> 16, hex >> 8, hex].map { Double($0 & 0xFF) / 255 }
        let linear = channels.map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
