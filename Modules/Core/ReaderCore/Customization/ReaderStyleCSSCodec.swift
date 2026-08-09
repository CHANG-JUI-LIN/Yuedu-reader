import Foundation

enum ReaderStyleCSSContext: Equatable, Sendable {
    case chapterLayer
    case regexHighlight
}

enum ReaderStyleCSSCodecError: Error, Equatable, Sendable {
    case malformedDeclaration(line: Int, column: Int)
    case unsupportedProperty(name: String, line: Int, column: Int)
    case invalidValue(property: String, value: String, line: Int, column: Int)
}

struct ReaderStyleCSSDeclaration: Equatable, Sendable {
    let name: String
    let value: String
    let line: Int
    let column: Int
}

/// The declarations that belong to a free-position chapter-title layer rather
/// than to its reusable text/decoration style. Keeping these values separate
/// prevents the general regex-highlight CSS codec from accidentally acquiring
/// layout semantics while still making chapter HTML a lossless source format.
struct ReaderStyleChapterLayerDeclarations: Equatable, Sendable {
    var ruleStyle: ReaderStyleRuleStyle
    var frame: ReaderStyleNormalizedRect
    var rotation: ReaderStyleRotation
    var textAlignment: ChapterTitleAlignment
    var writingDirection: ChapterTitleWritingDirection
    var imagePresentation: ReaderStyleImagePresentation?
}

enum ReaderStyleDeclarationScanner {
    static func scan(_ source: String) throws -> [ReaderStyleCSSDeclaration] {
        var declarations: [ReaderStyleCSSDeclaration] = []
        var segment = ""
        var segmentLine = 1
        var segmentColumn = 1
        var line = 1
        var column = 1
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0

        func advanced(_ character: Character, line: inout Int, column: inout Int) {
            if character == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }

        func declaration(from raw: String, line: Int, column: Int) throws -> ReaderStyleCSSDeclaration? {
            guard let first = raw.firstIndex(where: { !$0.isWhitespace }) else { return nil }
            var declarationLine = line
            var declarationColumn = column
            for character in raw[..<first] {
                advanced(character, line: &declarationLine, column: &declarationColumn)
            }

            var localQuote: Character?
            var localEscaped = false
            var localDepth = 0
            var colon: String.Index?
            var index = first
            while index < raw.endIndex {
                let character = raw[index]
                if localEscaped {
                    localEscaped = false
                } else if character == "\\", localQuote != nil {
                    localEscaped = true
                } else if character == "\"" || character == "'" {
                    if localQuote == character {
                        localQuote = nil
                    } else if localQuote == nil {
                        localQuote = character
                    }
                } else if localQuote == nil {
                    if character == "(" {
                        localDepth += 1
                    } else if character == ")" {
                        localDepth -= 1
                        if localDepth < 0 {
                            throw ReaderStyleCSSCodecError.malformedDeclaration(
                                line: declarationLine,
                                column: declarationColumn
                            )
                        }
                    } else if character == ":", localDepth == 0 {
                        colon = index
                        break
                    }
                }
                index = raw.index(after: index)
            }

            guard let colon else {
                throw ReaderStyleCSSCodecError.malformedDeclaration(
                    line: declarationLine,
                    column: declarationColumn
                )
            }
            let name = raw[first..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = raw.index(after: colon)
            let value = raw[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else {
                throw ReaderStyleCSSCodecError.malformedDeclaration(
                    line: declarationLine,
                    column: declarationColumn
                )
            }
            return ReaderStyleCSSDeclaration(
                name: name,
                value: value,
                line: declarationLine,
                column: declarationColumn
            )
        }

        for character in source {
            if escaped {
                escaped = false
            } else if character == "\\", quote != nil {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if quote == nil {
                if character == "(" {
                    parenthesisDepth += 1
                } else if character == ")" {
                    parenthesisDepth -= 1
                    if parenthesisDepth < 0 {
                        throw ReaderStyleCSSCodecError.malformedDeclaration(
                            line: segmentLine,
                            column: segmentColumn
                        )
                    }
                } else if character == ";", parenthesisDepth == 0 {
                    if let value = try declaration(from: segment, line: segmentLine, column: segmentColumn) {
                        declarations.append(value)
                    }
                    advanced(character, line: &line, column: &column)
                    segment = ""
                    segmentLine = line
                    segmentColumn = column
                    continue
                }
            }

            segment.append(character)
            advanced(character, line: &line, column: &column)
        }

        guard quote == nil, parenthesisDepth == 0 else {
            throw ReaderStyleCSSCodecError.malformedDeclaration(line: segmentLine, column: segmentColumn)
        }
        if let value = try declaration(from: segment, line: segmentLine, column: segmentColumn) {
            declarations.append(value)
        }
        return declarations
    }
}

enum ReaderStyleCSSCodec {
    static let sharedProperties: Set<String> = [
        "color", "font-family", "font-size", "font-weight", "font-style",
        "letter-spacing", "line-height", "text-decoration", "background-color",
        "background-image", "background-size", "background-position", "background-repeat",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border", "border-top", "border-right", "border-bottom", "border-left",
        "border-radius", "box-shadow", "opacity"
    ]

    static let chapterOnlyProperties: Set<String> = [
        "position", "left", "top", "width", "height", "box-sizing",
        "text-align", "transform", "writing-mode", "object-fit", "object-position",
        "-yuedu-image-source", "-yuedu-image-opacity"
    ]

    static func decodeDeclarations(
        _ source: String,
        context: ReaderStyleCSSContext
    ) throws -> ReaderStyleRuleStyle {
        let declarations = try ReaderStyleDeclarationScanner.scan(source)
        let allowed = sharedProperties.union(context == .chapterLayer ? chapterOnlyProperties : [])
        var style = ReaderStyleRuleStyle(text: .init(), decoration: .init(shadows: []))
        var deferredImageDeclarations: [ReaderStyleCSSDeclaration] = []
        for declaration in declarations {
            guard allowed.contains(declaration.name) else {
                throw ReaderStyleCSSCodecError.unsupportedProperty(
                    name: declaration.name,
                    line: declaration.line,
                    column: declaration.column
                )
            }
            if ["background-size", "background-position", "background-repeat"].contains(declaration.name) {
                deferredImageDeclarations.append(declaration)
                continue
            }
            try apply(declaration, to: &style, context: context)
        }
        for declaration in deferredImageDeclarations {
            try apply(declaration, to: &style, context: context)
        }
        return style
    }

    static func encodeDeclarations(
        _ style: ReaderStyleRuleStyle,
        context: ReaderStyleCSSContext
    ) -> String {
        canonicalDeclarations(for: style, context: context).joined(separator: " ")
    }

    static func decodeChapterLayerDeclarations(
        _ source: String
    ) throws -> ReaderStyleChapterLayerDeclarations {
        let declarations = try ReaderStyleDeclarationScanner.scan(source)
        var style = ReaderStyleRuleStyle(text: .init(), decoration: .init(shadows: []))
        var deferredImageDeclarations: [ReaderStyleCSSDeclaration] = []
        var percentages: [String: Double] = [:]
        var rotation = ReaderStyleRotation(degrees: 0)
        var alignment = ChapterTitleAlignment.center
        var direction = ChapterTitleWritingDirection.horizontal
        var imagePresentation: ReaderStyleImagePresentation?

        for declaration in declarations {
            guard sharedProperties.contains(declaration.name) || chapterOnlyProperties.contains(declaration.name) else {
                throw ReaderStyleCSSCodecError.unsupportedProperty(
                    name: declaration.name,
                    line: declaration.line,
                    column: declaration.column
                )
            }

            switch declaration.name {
            case "left", "top", "width", "height":
                guard let value = parsePercentage(declaration.value), (0...1).contains(value) else {
                    throw invalidValue(for: declaration)
                }
                percentages[declaration.name] = value
            case "position":
                guard normalizedWhitespace(declaration.value).lowercased() == "absolute" else {
                    throw invalidValue(for: declaration)
                }
            case "box-sizing":
                guard normalizedWhitespace(declaration.value).lowercased() == "border-box" else {
                    throw invalidValue(for: declaration)
                }
            case "text-align":
                switch normalizedWhitespace(declaration.value).lowercased() {
                case "left", "start": alignment = .left
                case "center": alignment = .center
                case "right", "end": alignment = .right
                default: throw invalidValue(for: declaration)
                }
            case "transform":
                guard let degrees = parseRotation(declaration.value) else {
                    throw invalidValue(for: declaration)
                }
                rotation = ReaderStyleRotation(degrees: degrees)
            case "writing-mode":
                switch normalizedWhitespace(declaration.value).lowercased() {
                case "horizontal-tb": direction = .horizontal
                case "vertical-rl": direction = .vertical
                default: throw invalidValue(for: declaration)
                }
            case "-yuedu-image-source":
                guard let assetID = parseManagedAssetURL(declaration.value) else {
                    throw invalidValue(for: declaration)
                }
                var presentation = imagePresentation ?? ReaderStyleImagePresentation(assetID: assetID)
                presentation.assetID = assetID
                imagePresentation = presentation
            case "object-fit", "object-position", "-yuedu-image-opacity":
                deferredImageDeclarations.append(declaration)
            default:
                if ["background-size", "background-position", "background-repeat"].contains(declaration.name) {
                    deferredImageDeclarations.append(declaration)
                } else {
                    try apply(declaration, to: &style, context: .chapterLayer)
                }
            }
        }

        for declaration in deferredImageDeclarations {
            switch declaration.name {
            case "object-fit":
                guard var presentation = imagePresentation else { throw invalidValue(for: declaration) }
                switch normalizedWhitespace(declaration.value).lowercased() {
                case "cover": presentation.contentMode = .fill
                case "contain": presentation.contentMode = .fit
                case "none": presentation.contentMode = .tile
                case "fill": presentation.contentMode = .stretch
                default: throw invalidValue(for: declaration)
                }
                imagePresentation = presentation
            case "object-position":
                guard var presentation = imagePresentation,
                      let point = parseBackgroundPosition(declaration.value) else {
                    throw invalidValue(for: declaration)
                }
                presentation.focalX = point.x
                presentation.focalY = point.y
                imagePresentation = presentation
            case "-yuedu-image-opacity":
                guard var presentation = imagePresentation,
                      let opacity = Double(declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      opacity.isFinite,
                      (0...1).contains(opacity) else {
                    throw invalidValue(for: declaration)
                }
                presentation.opacity = opacity
                imagePresentation = presentation
            default:
                try apply(declaration, to: &style, context: .chapterLayer)
            }
        }

        guard let left = percentages["left"],
              let top = percentages["top"],
              let width = percentages["width"],
              let height = percentages["height"] else {
            let missing = ["left", "top", "width", "height"].first { percentages[$0] == nil }!
            throw ReaderStyleCSSCodecError.invalidValue(property: missing, value: "", line: 1, column: 1)
        }

        return ReaderStyleChapterLayerDeclarations(
            ruleStyle: style,
            frame: ReaderStyleNormalizedRect(x: left, y: top, width: width, height: height),
            rotation: rotation,
            textAlignment: alignment,
            writingDirection: direction,
            imagePresentation: imagePresentation
        )
    }

    static func encodeChapterLayerDeclarations(
        _ declarations: ReaderStyleChapterLayerDeclarations
    ) -> String {
        let frame = declarations.frame
        var result = [
            "position: absolute;",
            "left: \(formatNumber(frame.x * 100))%;",
            "top: \(formatNumber(frame.y * 100))%;",
            "width: \(formatNumber(frame.width * 100))%;",
            "height: \(formatNumber(frame.height * 100))%;",
            "box-sizing: border-box;",
            "text-align: \(declarations.textAlignment.rawValue);",
            "transform: rotate(\(formatNumber(declarations.rotation.degrees))deg);",
            "writing-mode: \(declarations.writingDirection == .vertical ? "vertical-rl" : "horizontal-tb");",
        ]
        result.append(contentsOf: canonicalDeclarations(for: declarations.ruleStyle, context: .chapterLayer))
        if let image = declarations.imagePresentation {
            result.append("-yuedu-image-source: url(yuedu-asset://\(image.assetID.uuidString.lowercased()));")
            switch image.contentMode {
            case .fill: result.append("object-fit: cover;")
            case .fit: result.append("object-fit: contain;")
            case .tile: result.append("object-fit: none;")
            case .stretch: result.append("object-fit: fill;")
            }
            result.append(
                "object-position: \(formatNumber(image.focalX * 100))% \(formatNumber(image.focalY * 100))%;"
            )
            result.append("-yuedu-image-opacity: \(formatNumber(image.opacity));")
        }
        return result.joined(separator: " ")
    }

    private static func apply(
        _ declaration: ReaderStyleCSSDeclaration,
        to style: inout ReaderStyleRuleStyle,
        context: ReaderStyleCSSContext
    ) throws {
        let property = declaration.name
        let value = declaration.value

        func invalid() -> ReaderStyleCSSCodecError {
            .invalidValue(
                property: property,
                value: value,
                line: declaration.line,
                column: declaration.column
            )
        }

        switch property {
        case "color":
            guard let color = parseColor(value) else { throw invalid() }
            style.text.colorHex = color
        case "font-family":
            guard let family = parseFontFamily(value) else { throw invalid() }
            style.text.fontPostScriptName = family
        case "font-size":
            guard let length = parseLength(value), length >= 0 else { throw invalid() }
            style.text.fontSize = length
        case "font-weight":
            guard let weight = parseFontWeight(value) else { throw invalid() }
            style.text.fontWeight = weight
        case "font-style":
            switch value.lowercased() {
            case "normal": style.text.italic = false
            case "italic", "oblique": style.text.italic = true
            default: throw invalid()
            }
        case "letter-spacing":
            guard let length = parseLength(value) else { throw invalid() }
            style.text.letterSpacing = length
        case "line-height":
            guard let length = parseLength(value, allowsUnitless: true), length >= 0 else { throw invalid() }
            style.text.lineHeight = length
        case "text-decoration":
            guard applyTextDecoration(value, to: &style.text) else { throw invalid() }
        case "background-color":
            guard let color = parseColor(value) else { throw invalid() }
            style.decoration.backgroundColorHex = color
        case "background-image":
            if value.lowercased() == "none" {
                style.decoration.backgroundGradient = nil
                style.decoration.backgroundImage = nil
            } else if let gradient = parseGradient(value) {
                style.decoration.backgroundGradient = gradient
                style.decoration.backgroundImage = nil
            } else if let assetID = parseManagedAssetURL(value) {
                style.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: assetID)
                style.decoration.backgroundGradient = nil
            } else {
                throw invalid()
            }
        case "background-size":
            guard var image = style.decoration.backgroundImage else { throw invalid() }
            switch normalizedWhitespace(value).lowercased() {
            case "cover": image.contentMode = .fill
            case "contain": image.contentMode = .fit
            case "auto": image.contentMode = .tile
            case "100% 100%": image.contentMode = .stretch
            default: throw invalid()
            }
            style.decoration.backgroundImage = image
        case "background-position":
            guard var image = style.decoration.backgroundImage,
                  let focalPoint = parseBackgroundPosition(value) else { throw invalid() }
            image.focalX = focalPoint.x
            image.focalY = focalPoint.y
            style.decoration.backgroundImage = image
        case "background-repeat":
            guard var image = style.decoration.backgroundImage else { throw invalid() }
            switch value.lowercased() {
            case "repeat": image.contentMode = .tile
            case "no-repeat":
                if image.contentMode == .tile { image.contentMode = .fill }
            default: throw invalid()
            }
            style.decoration.backgroundImage = image
        case "margin":
            guard let edges = parseEdges(value, permitsNegative: true) else { throw invalid() }
            style.decoration.margin = edges
        case "padding":
            guard let edges = parseEdges(value, permitsNegative: false) else { throw invalid() }
            style.decoration.padding = edges
        case "margin-top", "margin-right", "margin-bottom", "margin-left":
            guard let length = parseLength(value) else { throw invalid() }
            var edges = style.decoration.margin ?? ReaderStyleEdges()
            set(length, for: property, in: &edges)
            style.decoration.margin = edges
        case "padding-top", "padding-right", "padding-bottom", "padding-left":
            guard let length = parseLength(value), length >= 0 else { throw invalid() }
            var edges = style.decoration.padding ?? ReaderStyleEdges()
            set(length, for: property, in: &edges)
            style.decoration.padding = edges
        case "border":
            guard let border = parseBorder(value) else { throw invalid() }
            style.decoration.borders = Dictionary(
                uniqueKeysWithValues: ReaderStyleEdge.allCases.map { ($0, border) }
            )
        case "border-top", "border-right", "border-bottom", "border-left":
            guard let border = parseBorder(value), let edge = edge(for: property) else { throw invalid() }
            var borders = style.decoration.borders ?? [:]
            borders[edge] = border
            style.decoration.borders = borders
        case "border-radius":
            guard let radius = parseLength(value), radius >= 0 else { throw invalid() }
            style.decoration.cornerRadius = radius
        case "box-shadow":
            guard let shadows = parseShadows(value) else { throw invalid() }
            style.decoration.shadows = shadows
        case "opacity":
            guard let opacity = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  opacity.isFinite, (0...1).contains(opacity) else { throw invalid() }
            style.decoration.opacity = opacity
        default:
            guard context == .chapterLayer, validateChapterOnly(property: property, value: value) else {
                throw invalid()
            }
        }
    }

    private static func invalidValue(for declaration: ReaderStyleCSSDeclaration) -> ReaderStyleCSSCodecError {
        .invalidValue(
            property: declaration.name,
            value: declaration.value,
            line: declaration.line,
            column: declaration.column
        )
    }

    private static func canonicalDeclarations(
        for style: ReaderStyleRuleStyle,
        context: ReaderStyleCSSContext
    ) -> [String] {
        _ = context
        var result: [String] = []
        if let color = style.text.colorHex {
            result.append("color: \(formatColor(color));")
        }
        if let family = style.text.fontPostScriptName {
            result.append("font-family: \(formatFontFamily(family));")
        }
        if let size = style.text.fontSize {
            result.append("font-size: \(formatLength(size));")
        }
        if let weight = style.text.fontWeight {
            result.append("font-weight: \(weight);")
        }
        if let italic = style.text.italic {
            result.append("font-style: \(italic ? "italic" : "normal");")
        }
        if let spacing = style.text.letterSpacing {
            result.append("letter-spacing: \(formatLength(spacing));")
        }
        if let height = style.text.lineHeight {
            result.append("line-height: \(formatLength(height));")
        }
        if style.text.underline != nil || style.text.strikethrough != nil {
            var values: [String] = []
            if style.text.underline == true { values.append("underline") }
            if style.text.strikethrough == true { values.append("line-through") }
            result.append("text-decoration: \(values.isEmpty ? "none" : values.joined(separator: " "));")
        }
        if let color = style.decoration.backgroundColorHex {
            result.append("background-color: \(formatColor(color));")
        }
        if let image = style.decoration.backgroundImage {
            result.append("background-image: url(yuedu-asset://\(image.assetID.uuidString.lowercased()));")
            switch image.contentMode {
            case .fill:
                result.append("background-size: cover;")
                result.append("background-repeat: no-repeat;")
            case .fit:
                result.append("background-size: contain;")
                result.append("background-repeat: no-repeat;")
            case .tile:
                result.append("background-size: auto;")
                result.append("background-repeat: repeat;")
            case .stretch:
                result.append("background-size: 100% 100%;")
                result.append("background-repeat: no-repeat;")
            }
            result.append(
                "background-position: \(formatNumber(image.focalX * 100))% \(formatNumber(image.focalY * 100))%;"
            )
        } else if let gradient = style.decoration.backgroundGradient {
            let stops = gradient.stops.map {
                "\(formatColor($0.colorHex)) \(formatNumber($0.location * 100))%"
            }.joined(separator: ", ")
            result.append("background-image: linear-gradient(\(formatNumber(gradient.angleDegrees))deg, \(stops));")
        }
        if let margin = style.decoration.margin {
            result.append("margin: \(formatEdges(margin));")
        }
        if let padding = style.decoration.padding {
            result.append("padding: \(formatEdges(padding));")
        }
        if let borders = style.decoration.borders, !borders.isEmpty {
            let all = ReaderStyleEdge.allCases.compactMap { borders[$0] }
            if all.count == ReaderStyleEdge.allCases.count, all.dropFirst().allSatisfy({ $0 == all[0] }) {
                result.append("border: \(formatBorder(all[0]));")
            } else {
                for edge in ReaderStyleEdge.allCases {
                    guard let border = borders[edge] else { continue }
                    result.append("border-\(cssName(for: edge)): \(formatBorder(border));")
                }
            }
        }
        if let radius = style.decoration.cornerRadius {
            result.append("border-radius: \(formatLength(radius));")
        }
        if !style.decoration.shadows.isEmpty {
            let shadows = style.decoration.shadows.map {
                "\(formatLength($0.x)) \(formatLength($0.y)) \(formatLength($0.radius)) \(formatColor($0.colorHex))"
            }.joined(separator: ", ")
            result.append("box-shadow: \(shadows);")
        }
        if let opacity = style.decoration.opacity {
            result.append("opacity: \(formatNumber(opacity));")
        }
        return result
    }

    private static func parseColor(_ raw: String) -> UInt32? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            if digits.count == 3 {
                let expanded = digits.map { "\($0)\($0)" }.joined()
                return UInt32(expanded, radix: 16)
            }
            if digits.count == 6 {
                return UInt32(digits, radix: 16)
            }
            return nil
        }

        let lower = value.lowercased()
        let named: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000,
            "green": 0x008000, "blue": 0x0000FF, "gray": 0x808080,
            "grey": 0x808080, "yellow": 0xFFFF00
        ]
        if let color = named[lower] { return color }
        guard lower.hasPrefix("rgb("), lower.hasSuffix(")") else { return nil }
        let body = lower.dropFirst(4).dropLast()
        let channels = body.split(separator: ",").map {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard channels.count == 3,
              let red = channels[0], let green = channels[1], let blue = channels[2],
              (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) else {
            return nil
        }
        return UInt32(red << 16 | green << 8 | blue)
    }

    private static func parseFontFamily(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(",") else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            let unquoted = value.dropFirst().dropLast()
            return unquoted.isEmpty ? nil : String(unquoted)
        }
        return value
    }

    private static func parseFontWeight(_ raw: String) -> Int? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "normal": return 400
        case "bold": return 700
        case let value:
            guard let weight = Int(value), (1...1_000).contains(weight) else { return nil }
            return weight
        }
    }

    private static func applyTextDecoration(_ raw: String, to style: inout ReaderStyleTextStyle) -> Bool {
        let tokens = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return false }
        if tokens == ["none"] {
            style.underline = false
            style.strikethrough = false
            return true
        }
        guard tokens.allSatisfy({ $0 == "underline" || $0 == "line-through" }) else { return false }
        style.underline = tokens.contains("underline")
        style.strikethrough = tokens.contains("line-through")
        return true
    }

    private static func parseLength(_ raw: String, allowsUnitless: Bool = false) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number: String
        if value.hasSuffix("px") || value.hasSuffix("pt") {
            number = String(value.dropLast(2))
        } else if value == "0" || allowsUnitless {
            number = value
        } else {
            return nil
        }
        guard let parsed = Double(number), parsed.isFinite else { return nil }
        return parsed
    }

    private static func parsePercentage(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix("%"),
              let percentage = Double(value.dropLast()),
              percentage.isFinite else {
            return nil
        }
        return percentage / 100
    }

    private static func parseRotation(_ raw: String) -> Double? {
        let value = normalizedWhitespace(raw).lowercased()
        guard value.hasPrefix("rotate("), value.hasSuffix("deg)") else { return nil }
        return Double(value.dropFirst(7).dropLast(4)).flatMap { $0.isFinite ? $0 : nil }
    }

    private static func parseEdges(_ raw: String, permitsNegative: Bool) -> ReaderStyleEdges? {
        let values = raw.split(whereSeparator: \.isWhitespace).compactMap { parseLength(String($0)) }
        let tokenCount = raw.split(whereSeparator: \.isWhitespace).count
        guard values.count == tokenCount, (1...4).contains(values.count),
              permitsNegative || values.allSatisfy({ $0 >= 0 }) else { return nil }
        switch values.count {
        case 1:
            return ReaderStyleEdges(top: values[0], leading: values[0], bottom: values[0], trailing: values[0])
        case 2:
            return ReaderStyleEdges(top: values[0], leading: values[1], bottom: values[0], trailing: values[1])
        case 3:
            return ReaderStyleEdges(top: values[0], leading: values[1], bottom: values[2], trailing: values[1])
        case 4:
            return ReaderStyleEdges(top: values[0], leading: values[3], bottom: values[2], trailing: values[1])
        default:
            return nil
        }
    }

    private static func set(_ value: Double, for property: String, in edges: inout ReaderStyleEdges) {
        if property.hasSuffix("-top") { edges.top = value }
        else if property.hasSuffix("-right") { edges.trailing = value }
        else if property.hasSuffix("-bottom") { edges.bottom = value }
        else if property.hasSuffix("-left") { edges.leading = value }
    }

    private static func parseBorder(_ raw: String) -> ReaderStyleBorder? {
        let value = normalizedWhitespace(raw).lowercased()
        if value == "none" { return ReaderStyleBorder() }
        let tokens = value.split(separator: " ").map(String.init)
        guard let width = tokens.compactMap({ parseLength($0) }).first, width >= 0 else { return nil }
        if tokens.contains(where: { ["dashed", "dotted", "double"].contains($0) }) { return nil }
        let ignored: Set<String> = ["solid"]
        let remaining = tokens.filter { parseLength($0) == nil && !ignored.contains($0) }
        guard remaining.count <= 1 else { return nil }
        let color = remaining.first.flatMap(parseColor) ?? 0
        if !remaining.isEmpty, parseColor(remaining[0]) == nil { return nil }
        return ReaderStyleBorder(width: width, colorHex: color)
    }

    private static func parseShadows(_ raw: String) -> [ReaderStyleShadow]? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" { return [] }
        let components = splitTopLevel(raw, separator: ",")
        var shadows: [ReaderStyleShadow] = []
        for component in components {
            let tokens = component.split(whereSeparator: \.isWhitespace).map(String.init)
            var lengths: [Double] = []
            var color: UInt32?
            for token in tokens {
                if let parsed = parseLength(token) {
                    lengths.append(parsed)
                } else if let parsed = parseColor(token), color == nil {
                    color = parsed
                } else {
                    return nil
                }
            }
            guard (2...3).contains(lengths.count) else { return nil }
            shadows.append(ReaderStyleShadow(
                colorHex: color ?? 0,
                radius: lengths.count == 3 ? lengths[2] : 0,
                x: lengths[0],
                y: lengths[1]
            ))
        }
        return shadows
    }

    private static func parseGradient(_ raw: String) -> ReaderStyleGradient? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "linear-gradient("
        guard value.lowercased().hasPrefix(prefix), value.hasSuffix(")") else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let body = String(value[start..<value.index(before: value.endIndex)])
        var parts = splitTopLevel(body, separator: ",")
        guard parts.count >= 2 else { return nil }

        var angle = 180.0
        let first = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if first.hasSuffix("deg"), let parsed = Double(first.dropLast(3)), parsed.isFinite {
            angle = parsed
            parts.removeFirst()
        } else if first.hasPrefix("to ") {
            let directions: [String: Double] = [
                "to top": 0, "to right": 90, "to bottom": 180, "to left": 270
            ]
            guard let parsed = directions[first] else { return nil }
            angle = parsed
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }

        var parsedStops: [(UInt32, Double?)] = []
        for part in parts {
            let tokens = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard (1...2).contains(tokens.count), let color = parseColor(tokens[0]) else { return nil }
            var location: Double?
            if tokens.count == 2 {
                guard tokens[1].hasSuffix("%"),
                      let percent = Double(tokens[1].dropLast()), percent.isFinite else { return nil }
                location = min(max(percent / 100, 0), 1)
            }
            parsedStops.append((color, location))
        }
        let denominator = Double(max(parsedStops.count - 1, 1))
        let stops = parsedStops.enumerated().map { index, stop in
            ReaderStyleGradientStop(
                colorHex: stop.0,
                location: stop.1 ?? Double(index) / denominator
            )
        }
        return ReaderStyleGradient(angleDegrees: angle, stops: stops)
    }

    private static func parseManagedAssetURL(_ raw: String) -> UUID? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("url("), value.hasSuffix(")") else { return nil }
        var body = String(value.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if (body.hasPrefix("\"") && body.hasSuffix("\"")) ||
            (body.hasPrefix("'") && body.hasSuffix("'")) {
            body = String(body.dropFirst().dropLast())
        }
        let prefix = "yuedu-asset://"
        guard body.lowercased().hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(body.dropFirst(prefix.count)))
    }

    private static func parseBackgroundPosition(_ raw: String) -> (x: Double, y: Double)? {
        let tokens = normalizedWhitespace(raw).lowercased().split(separator: " ").map(String.init)
        guard (1...2).contains(tokens.count) else { return nil }
        func component(_ token: String, horizontal: Bool) -> Double? {
            switch token {
            case "center": return 0.5
            case "left" where horizontal: return 0
            case "right" where horizontal: return 1
            case "top" where !horizontal: return 0
            case "bottom" where !horizontal: return 1
            default:
                guard token.hasSuffix("%"), let percent = Double(token.dropLast()), percent.isFinite else {
                    return nil
                }
                return min(max(percent / 100, 0), 1)
            }
        }
        if tokens.count == 1 {
            guard let x = component(tokens[0], horizontal: true) else { return nil }
            return (x, 0.5)
        }
        guard let x = component(tokens[0], horizontal: true),
              let y = component(tokens[1], horizontal: false) else { return nil }
        return (x, y)
    }

    private static func validateChapterOnly(property: String, value: String) -> Bool {
        let normalized = normalizedWhitespace(value).lowercased()
        switch property {
        case "position": return ["absolute", "relative"].contains(normalized)
        case "box-sizing": return ["border-box", "content-box"].contains(normalized)
        case "text-align": return ["left", "center", "right", "start", "end"].contains(normalized)
        case "left", "top", "width", "height":
            if normalized.hasSuffix("%"), let number = Double(normalized.dropLast()) {
                return number.isFinite
            }
            return parseLength(normalized) != nil
        case "transform": return parseRotation(normalized) != nil
        case "writing-mode": return ["horizontal-tb", "vertical-rl"].contains(normalized)
        case "object-fit": return ["cover", "contain", "none", "fill"].contains(normalized)
        case "object-position": return parseBackgroundPosition(normalized) != nil
        case "-yuedu-image-source": return parseManagedAssetURL(normalized) != nil
        case "-yuedu-image-opacity":
            guard let opacity = Double(normalized), opacity.isFinite else { return false }
            return (0...1).contains(opacity)
        default: return false
        }
    }

    private static func splitTopLevel(_ source: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in source {
            if escaped {
                escaped = false
            } else if character == "\\", quote != nil {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "(" { depth += 1 }
                else if character == ")" { depth -= 1 }
                else if character == separator, depth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private static func normalizedWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func edge(for property: String) -> ReaderStyleEdge? {
        switch property {
        case "border-top": return .top
        case "border-right": return .trailing
        case "border-bottom": return .bottom
        case "border-left": return .leading
        default: return nil
        }
    }

    private static func cssName(for edge: ReaderStyleEdge) -> String {
        switch edge {
        case .top: return "top"
        case .leading: return "left"
        case .bottom: return "bottom"
        case .trailing: return "right"
        }
    }

    private static func formatColor(_ value: UInt32) -> String {
        String(format: "#%06X", value & 0xFFFFFF)
    }

    private static func formatFontFamily(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }

    private static func formatLength(_ value: Double) -> String {
        "\(formatNumber(value))px"
    }

    private static func formatEdges(_ edges: ReaderStyleEdges) -> String {
        if edges.top == edges.bottom, edges.leading == edges.trailing {
            if edges.top == edges.leading {
                return formatLength(edges.top)
            }
            return "\(formatLength(edges.top)) \(formatLength(edges.trailing))"
        }
        if edges.leading == edges.trailing {
            return "\(formatLength(edges.top)) \(formatLength(edges.trailing)) \(formatLength(edges.bottom))"
        }
        return [edges.top, edges.trailing, edges.bottom, edges.leading]
            .map(formatLength)
            .joined(separator: " ")
    }

    private static func formatBorder(_ border: ReaderStyleBorder) -> String {
        "\(formatLength(border.width)) solid \(formatColor(border.colorHex))"
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        var result = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }
}
