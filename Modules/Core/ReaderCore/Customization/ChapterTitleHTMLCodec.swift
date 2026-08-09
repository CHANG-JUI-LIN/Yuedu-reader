import Foundation
import SwiftSoup

enum ChapterTitleHTMLCodecError: Error, Equatable, Sendable {
    case malformedHTML(line: Int, column: Int)
    case unsupportedTag(name: String, line: Int, column: Int)
    case unsupportedAttribute(name: String, line: Int, column: Int)
    case duplicateLayerID(String)
    case invalidPlaceholder(String, line: Int, column: Int)
    case remoteResource(line: Int, column: Int)
    case lightDarkStructureMismatch
}

enum ChapterTitleHTMLCodec {
    static let supportedTags: Set<String> = ["div", "p", "span", "img", "hr"]

    static func encode(
        _ design: ChapterTitleDesign,
        appearance: ReaderStyleAppearance
    ) -> String {
        let design = design.sanitized()
        var lines = [
            "<div data-yuedu-version=\"\(design.version)\" " +
                "data-yuedu-canvas-aspect-ratio=\"\(number(design.canvasAspectRatio))\" " +
                "data-yuedu-canvas-height=\"\(number(design.canvasHeight))\">"
        ]
        for layer in design.layers {
            lines.append("  \(encode(layer, appearance: appearance))")
        }
        lines.append("</div>")
        return lines.joined(separator: "\n")
    }

    static func decode(light: String, dark: String) throws -> ChapterTitleDesign {
        let lightDocument = try parseCanonical(light)
        let darkDocument = try parseCanonical(dark)
        guard lightDocument.structure == darkDocument.structure else {
            throw ChapterTitleHTMLCodecError.lightDarkStructureMismatch
        }

        let layers = zip(lightDocument.layers, darkDocument.layers).map { lightLayer, darkLayer in
            ChapterTitleLayer(
                id: lightLayer.id,
                name: lightLayer.name,
                kind: lightLayer.kind,
                frame: lightLayer.style.frame,
                rotation: lightLayer.style.rotation,
                isVisible: lightLayer.isVisible,
                isLocked: lightLayer.isLocked,
                content: lightLayer.content,
                lightStyle: lightLayer.layerStyle,
                darkStyle: darkLayer.layerStyle
            )
        }
        return ChapterTitleDesign(
            version: lightDocument.version,
            canvasAspectRatio: lightDocument.canvasAspectRatio,
            canvasHeight: lightDocument.canvasHeight,
            layers: layers
        ).sanitized()
    }

    /// Migration is deliberately pure: the caller swaps its stored design only
    /// after both appearances have parsed and matched. The original templates
    /// remain attached to the returned design for audit/export and remain
    /// untouched when any validation step throws.
    static func migrateLegacySource(
        _ source: ChapterTitleLegacySource
    ) throws -> ChapterTitleDesign {
        let light = try parseLegacy(source.light)
        let dark = try parseLegacy(source.dark)
        guard light.map(\.structure) == dark.map(\.structure) else {
            throw ChapterTitleHTMLCodecError.lightDarkStructureMismatch
        }

        let count = max(light.count, 1)
        let layers = zip(light, dark).enumerated().map { index, pair in
            let frame = ReaderStyleNormalizedRect(
                x: 0,
                y: Double(index) / Double(count),
                width: 1,
                height: 1 / Double(count)
            )
            return ChapterTitleLayer(
                id: legacyLayerID(index),
                name: pair.0.name,
                kind: pair.0.kind,
                frame: frame,
                rotation: .init(degrees: 0),
                isVisible: true,
                isLocked: false,
                content: pair.0.content,
                lightStyle: pair.0.style,
                darkStyle: pair.1.style
            )
        }
        return ChapterTitleDesign(layers: layers, legacySource: source).sanitized()
    }
}

// MARK: - Canonical source

fileprivate extension ChapterTitleHTMLCodec {
    struct ParsedDocument {
        var version: Int
        var canvasAspectRatio: Double
        var canvasHeight: Double
        var layers: [ParsedLayer]

        var structure: DocumentStructure {
            DocumentStructure(
                version: version,
                canvasAspectRatio: canvasAspectRatio,
                canvasHeight: canvasHeight,
                layers: layers.map(\.structure)
            )
        }
    }

    struct ParsedLayer {
        var tag: String
        var id: UUID
        var name: String
        var kind: ChapterTitleLayerKind
        var isVisible: Bool
        var isLocked: Bool
        var content: ChapterTitleLayerContent
        var style: ReaderStyleChapterLayerDeclarations

        var layerStyle: ChapterTitleLayerStyle {
            ChapterTitleLayerStyle(
                ruleStyle: style.ruleStyle,
                textAlignment: style.textAlignment,
                writingDirection: style.writingDirection,
                imagePresentation: style.imagePresentation
            )
        }

        var structure: LayerStructure {
            LayerStructure(
                tag: tag,
                id: id,
                name: name,
                kind: kind,
                frame: style.frame,
                rotation: style.rotation,
                isVisible: isVisible,
                isLocked: isLocked,
                content: content
            )
        }
    }

    struct DocumentStructure: Equatable {
        var version: Int
        var canvasAspectRatio: Double
        var canvasHeight: Double
        var layers: [LayerStructure]
    }

    struct LayerStructure: Equatable {
        var tag: String
        var id: UUID
        var name: String
        var kind: ChapterTitleLayerKind
        var frame: ReaderStyleNormalizedRect
        var rotation: ReaderStyleRotation
        var isVisible: Bool
        var isLocked: Bool
        var content: ChapterTitleLayerContent
    }

    static let rootAttributes: Set<String> = [
        "data-yuedu-version", "data-yuedu-canvas-aspect-ratio", "data-yuedu-canvas-height",
    ]
    static let layerAttributes: Set<String> = [
        "data-yuedu-layer-id", "data-yuedu-layer-kind", "data-yuedu-layer-name",
        "data-yuedu-visible", "data-yuedu-locked", "data-yuedu-content",
        "data-yuedu-line-width", "data-yuedu-line-color", "data-yuedu-line-dashed",
        "style", "src",
    ]

    static func parseCanonical(_ source: String) throws -> ParsedDocument {
        let tokens = try HTMLSourceValidator.validate(source)
        guard let document = try? SwiftSoup.parseBodyFragment(source),
              let body = document.body() else {
            throw ChapterTitleHTMLCodecError.malformedHTML(line: 1, column: 1)
        }
        let roots = body.children().array()
        guard roots.count == 1,
              roots[0].tagName().lowercased() == "div",
              let rootToken = tokens.first else {
            throw ChapterTitleHTMLCodecError.malformedHTML(line: 1, column: 1)
        }
        try rejectUnexpectedAttributes(rootToken, allowed: rootAttributes)

        guard let version = rootToken.int("data-yuedu-version"),
              let aspectRatio = rootToken.double("data-yuedu-canvas-aspect-ratio"),
              let canvasHeight = rootToken.double("data-yuedu-canvas-height"),
              version >= 0,
              aspectRatio.isFinite, aspectRatio > 0,
              canvasHeight.isFinite, canvasHeight > 0 else {
            throw ChapterTitleHTMLCodecError.malformedHTML(
                line: rootToken.position.line,
                column: rootToken.position.column
            )
        }

        let elements = roots[0].children().array()
        let layerTokens = tokens.filter { $0.attributes["data-yuedu-layer-id"] != nil }
        guard elements.count == layerTokens.count else {
            throw ChapterTitleHTMLCodecError.malformedHTML(
                line: rootToken.position.line,
                column: rootToken.position.column
            )
        }

        var seenIDs: Set<UUID> = []
        var layers: [ParsedLayer] = []
        for (element, token) in zip(elements, layerTokens) {
            guard element.children().array().isEmpty else {
                throw ChapterTitleHTMLCodecError.malformedHTML(
                    line: token.position.line,
                    column: token.position.column
                )
            }
            try rejectUnexpectedAttributes(token, allowed: layerAttributes)
            guard let rawID = token.value("data-yuedu-layer-id"),
                  let id = UUID(uuidString: rawID),
                  let rawKind = token.value("data-yuedu-layer-kind"),
                  let kind = ChapterTitleLayerKind(rawValue: rawKind),
                  let name = token.value("data-yuedu-layer-name"),
                  let visible = token.bool("data-yuedu-visible"),
                  let locked = token.bool("data-yuedu-locked"),
                  let rawContentKind = token.value("data-yuedu-content"),
                  let rawStyle = token.value("style") else {
                throw ChapterTitleHTMLCodecError.malformedHTML(
                    line: token.position.line,
                    column: token.position.column
                )
            }
            guard seenIDs.insert(id).inserted else {
                throw ChapterTitleHTMLCodecError.duplicateLayerID(rawID)
            }
            let text = element.textNodes().map { $0.getWholeText() }.joined()
            try validatePlaceholders(in: text, source: source, fallback: token.position)
            let content = try decodeContent(
                rawContentKind,
                text: text,
                token: token
            )
            let style: ReaderStyleChapterLayerDeclarations
            do {
                style = try ReaderStyleCSSCodec.decodeChapterLayerDeclarations(rawStyle)
            } catch let error as ReaderStyleCSSCodecError {
                throw translate(error, fromStyleIn: token)
            }
            layers.append(ParsedLayer(
                tag: token.name,
                id: id,
                name: name,
                kind: kind,
                isVisible: visible,
                isLocked: locked,
                content: content,
                style: style
            ))
        }
        return ParsedDocument(
            version: version,
            canvasAspectRatio: aspectRatio,
            canvasHeight: canvasHeight,
            layers: layers
        )
    }

    static func encode(_ layer: ChapterTitleLayer, appearance: ReaderStyleAppearance) -> String {
        let style = appearance == .light ? layer.lightStyle : layer.darkStyle
        let declarations = ReaderStyleChapterLayerDeclarations(
            ruleStyle: style.ruleStyle,
            frame: layer.frame,
            rotation: layer.rotation,
            textAlignment: style.textAlignment,
            writingDirection: style.writingDirection,
            imagePresentation: style.imagePresentation
        )
        let css = ReaderStyleCSSCodec.encodeChapterLayerDeclarations(declarations)
        var attributes = [
            "data-yuedu-layer-id=\"\(layer.id.uuidString.lowercased())\"",
            "data-yuedu-layer-kind=\"\(layer.kind.rawValue)\"",
            "data-yuedu-layer-name=\"\(attributeEscaped(layer.name))\"",
            "data-yuedu-visible=\"\(layer.isVisible)\"",
            "data-yuedu-locked=\"\(layer.isLocked)\"",
            "data-yuedu-content=\"\(contentKind(layer.content))\"",
            "style=\"\(attributeEscaped(css))\"",
        ]
        let tag: String
        let body: String
        var isVoid = false
        switch layer.content {
        case let .dynamic(field):
            tag = layer.kind == .customText || layer.kind == .ornament ? "span" : "p"
            body = "{\(field.rawValue)}"
        case let .text(text):
            tag = layer.kind == .customText || layer.kind == .ornament ? "span" : "p"
            body = textEscaped(text)
        case let .line(line):
            tag = "hr"
            body = ""
            isVoid = true
            attributes.append("data-yuedu-line-width=\"\(number(line.width))\"")
            attributes.append("data-yuedu-line-color=\"#\(String(format: "%06X", line.colorHex & 0xFFFFFF))\"")
            attributes.append("data-yuedu-line-dashed=\"\(line.isDashed)\"")
        case let .image(assetID):
            tag = "img"
            body = ""
            isVoid = true
            attributes.append("src=\"yuedu-asset://\(assetID.uuidString.lowercased())\"")
        case .none:
            tag = "div"
            body = ""
        }
        let opening = "<\(tag) \(attributes.joined(separator: " "))>"
        return isVoid ? opening : "\(opening)\(body)</\(tag)>"
    }

    static func decodeContent(
        _ kind: String,
        text: String,
        token: HTMLSourceToken
    ) throws -> ChapterTitleLayerContent {
        switch kind {
        case "dynamic-number":
            guard text == "{number}" else { throw invalidContent(token) }
            return .dynamic(.number)
        case "dynamic-name":
            guard text == "{name}" else { throw invalidContent(token) }
            return .dynamic(.name)
        case "dynamic-title":
            guard text == "{title}" else { throw invalidContent(token) }
            return .dynamic(.title)
        case "text": return .text(text)
        case "line":
            guard let width = token.double("data-yuedu-line-width"),
                  let rawColor = token.value("data-yuedu-line-color"),
                  let color = parseHex(rawColor),
                  let dashed = token.bool("data-yuedu-line-dashed") else {
                throw invalidContent(token)
            }
            return .line(.init(width: width, colorHex: color, isDashed: dashed))
        case "image":
            guard let rawSource = token.value("src"),
                  let id = managedAssetID(rawSource) else {
                throw invalidContent(token)
            }
            return .image(id)
        case "none": return .none
        default: throw invalidContent(token)
        }
    }

    static func contentKind(_ content: ChapterTitleLayerContent) -> String {
        switch content {
        case let .dynamic(field): return "dynamic-\(field.rawValue)"
        case .text: return "text"
        case .line: return "line"
        case .image: return "image"
        case .none: return "none"
        }
    }

    static func invalidContent(_ token: HTMLSourceToken) -> ChapterTitleHTMLCodecError {
        .malformedHTML(line: token.position.line, column: token.position.column)
    }
}

// MARK: - Legacy migration

fileprivate extension ChapterTitleHTMLCodec {
    struct LegacyLayer {
        var name: String
        var kind: ChapterTitleLayerKind
        var content: ChapterTitleLayerContent
        var style: ChapterTitleLayerStyle

        var structure: LegacyStructure { .init(kind: kind, content: content) }
    }

    struct LegacyStructure: Equatable {
        var kind: ChapterTitleLayerKind
        var content: ChapterTitleLayerContent
    }

    struct LegacyContext {
        var ruleStyle = ReaderStyleRuleStyle()
        var alignment = ChapterTitleAlignment.center
    }

    static func parseLegacy(_ source: String) throws -> [LegacyLayer] {
        let tokens = try HTMLSourceValidator.validate(source)
        guard let document = try? SwiftSoup.parseBodyFragment(source),
              let body = document.body() else {
            throw ChapterTitleHTMLCodecError.malformedHTML(line: 1, column: 1)
        }
        var result: [LegacyLayer] = []
        var tokenIndex = 0

        func walk(_ element: SwiftSoup.Element, inherited: LegacyContext) throws {
            guard tokenIndex < tokens.count else {
                throw ChapterTitleHTMLCodecError.malformedHTML(line: 1, column: 1)
            }
            let token = tokens[tokenIndex]
            tokenIndex += 1
            let rawStyle = (try? element.attr("style")) ?? ""
            let context: LegacyContext
            do {
                context = try legacyContext(rawStyle, inherited: inherited)
            } catch let error as ReaderStyleCSSCodecError {
                throw translate(error, fromStyleIn: token)
            }

            let directText = element.textNodes().map { $0.getWholeText() }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !directText.isEmpty {
                try validatePlaceholders(in: directText, source: source, fallback: token.position)
                let content = legacyTextContent(directText)
                result.append(LegacyLayer(
                    name: legacyName(for: content),
                    kind: legacyKind(for: content),
                    content: content,
                    style: ChapterTitleLayerStyle(
                        ruleStyle: context.ruleStyle,
                        textAlignment: context.alignment
                    )
                ))
            } else if token.name == "hr" {
                let border = context.ruleStyle.decoration.borders?[.top]
                    ?? context.ruleStyle.decoration.borders?[.bottom]
                    ?? ReaderStyleBorder(width: 1, colorHex: 0)
                result.append(LegacyLayer(
                    name: "Line",
                    kind: .line,
                    content: .line(.init(width: border.width, colorHex: border.colorHex, isDashed: false)),
                    style: ChapterTitleLayerStyle(ruleStyle: context.ruleStyle, textAlignment: context.alignment)
                ))
            } else if token.name == "img" {
                guard let rawSource = token.value("src"), let id = managedAssetID(rawSource) else {
                    throw ChapterTitleHTMLCodecError.remoteResource(
                        line: token.position.line,
                        column: token.position.column
                    )
                }
                result.append(LegacyLayer(
                    name: "Image",
                    kind: .image,
                    content: .image(id),
                    style: ChapterTitleLayerStyle(ruleStyle: context.ruleStyle, textAlignment: context.alignment)
                ))
            } else if hasVisualDecoration(context.ruleStyle) {
                result.append(LegacyLayer(
                    name: "Color block",
                    kind: .colorBlock,
                    content: .none,
                    style: ChapterTitleLayerStyle(ruleStyle: context.ruleStyle, textAlignment: context.alignment)
                ))
            }

            for child in element.children() {
                try walk(child, inherited: context)
            }
        }

        for root in body.children() {
            try walk(root, inherited: LegacyContext())
        }
        guard !result.isEmpty else {
            throw ChapterTitleHTMLCodecError.malformedHTML(line: 1, column: 1)
        }
        return result
    }

    static func legacyContext(_ source: String, inherited: LegacyContext) throws -> LegacyContext {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return inherited }
        let normalized = try legacyNormalizedDeclarations(source)
        let own = try ReaderStyleCSSCodec.decodeDeclarations(normalized, context: .chapterLayer)
        var result = inherited
        result.ruleStyle = merge(inherited.ruleStyle, own)
        for declaration in try ReaderStyleDeclarationScanner.scan(normalized) where declaration.name == "text-align" {
            switch declaration.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "left", "start": result.alignment = .left
            case "center": result.alignment = .center
            case "right", "end": result.alignment = .right
            default: break
            }
        }
        return result
    }

    static func legacyNormalizedDeclarations(_ source: String) throws -> String {
        try ReaderStyleDeclarationScanner.scan(source).map { declaration in
            let value = replaceEMLengths(in: declaration.value, baseSize: 28)
            return "\(declaration.name): \(value);"
        }.joined(separator: " ")
    }

    static func replaceEMLengths(in source: String, baseSize: Double) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(-?(?:\d+(?:\.\d*)?|\.\d+))em\b"#) else {
            return source
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var result = source
        for match in expression.matches(in: source, range: range).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: source),
                  let matchRange = Range(match.range, in: result),
                  let value = Double(source[numberRange]) else { continue }
            result.replaceSubrange(matchRange, with: "\(number(value * baseSize))px")
        }
        return result
    }

    static func merge(_ inherited: ReaderStyleRuleStyle, _ own: ReaderStyleRuleStyle) -> ReaderStyleRuleStyle {
        let parentText = inherited.text
        let childText = own.text
        let text = ReaderStyleTextStyle(
            colorHex: childText.colorHex ?? parentText.colorHex,
            fontPostScriptName: childText.fontPostScriptName ?? parentText.fontPostScriptName,
            fontSize: childText.fontSize ?? parentText.fontSize,
            fontWeight: childText.fontWeight ?? parentText.fontWeight,
            italic: childText.italic ?? parentText.italic,
            letterSpacing: childText.letterSpacing ?? parentText.letterSpacing,
            lineHeight: childText.lineHeight ?? parentText.lineHeight,
            underline: childText.underline ?? parentText.underline,
            strikethrough: childText.strikethrough ?? parentText.strikethrough
        )
        let childDecoration = own.decoration
        let decoration = ReaderStyleDecorationStyle(
            backgroundColorHex: childDecoration.backgroundColorHex,
            backgroundGradient: childDecoration.backgroundGradient,
            backgroundImage: childDecoration.backgroundImage,
            padding: childDecoration.padding,
            margin: childDecoration.margin,
            visualGap: childDecoration.visualGap,
            borders: childDecoration.borders,
            cornerRadius: childDecoration.cornerRadius,
            shadows: childDecoration.shadows,
            opacity: childDecoration.opacity
        )
        return ReaderStyleRuleStyle(text: text, decoration: decoration)
    }

    static func legacyTextContent(_ text: String) -> ChapterTitleLayerContent {
        switch text {
        case "{number}": return .dynamic(.number)
        case "{name}": return .dynamic(.name)
        case "{title}": return .dynamic(.title)
        default: return .text(text)
        }
    }

    static func legacyKind(for content: ChapterTitleLayerContent) -> ChapterTitleLayerKind {
        switch content {
        case .dynamic(.number): return .chapterNumber
        case .dynamic(.name): return .chapterName
        case .dynamic(.title): return .originalTitle
        case let .text(text):
            return text.contains(where: { $0.isLetter || $0.isNumber }) ? .customText : .ornament
        case .line: return .line
        case .image: return .image
        case .none: return .colorBlock
        }
    }

    static func legacyName(for content: ChapterTitleLayerContent) -> String {
        switch legacyKind(for: content) {
        case .chapterNumber: return "Chapter number"
        case .chapterName: return "Chapter name"
        case .originalTitle: return "Original title"
        case .customText: return "Text"
        case .ornament: return "Ornament"
        case .line: return "Line"
        case .colorBlock: return "Color block"
        case .image: return "Image"
        }
    }

    static func hasVisualDecoration(_ style: ReaderStyleRuleStyle) -> Bool {
        let decoration = style.decoration
        return decoration.backgroundColorHex != nil || decoration.backgroundGradient != nil ||
            decoration.backgroundImage != nil || !(decoration.borders ?? [:]).isEmpty
    }

    static func legacyLayerID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "4C454741-4359-4000-8000-%012X", index + 1))!
    }
}

// MARK: - Source validation and helpers

fileprivate struct HTMLSourcePosition: Equatable {
    var line: Int
    var column: Int
}

fileprivate struct HTMLSourceAttribute {
    var value: String
    var namePosition: HTMLSourcePosition
    var valuePosition: HTMLSourcePosition
}

fileprivate struct HTMLSourceToken {
    var name: String
    var position: HTMLSourcePosition
    var attributes: [String: HTMLSourceAttribute]

    func value(_ name: String) -> String? {
        attributes[name].map { attribute in
            attribute.value
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }
    func bool(_ name: String) -> Bool? {
        switch value(name)?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
}

fileprivate enum HTMLSourceValidator {
    static let knownAttributes = ChapterTitleHTMLCodec.rootAttributes
        .union(ChapterTitleHTMLCodec.layerAttributes)

    static func validate(_ source: String) throws -> [HTMLSourceToken] {
        let characters = Array(source)
        var positions: [HTMLSourcePosition] = []
        var line = 1
        var column = 1
        for character in characters {
            positions.append(.init(line: line, column: column))
            if character == "\n" { line += 1; column = 1 } else { column += 1 }
        }
        positions.append(.init(line: line, column: column))

        func malformed(_ offset: Int) -> ChapterTitleHTMLCodecError {
            let position = positions[min(max(offset, 0), positions.count - 1)]
            return .malformedHTML(line: position.line, column: position.column)
        }
        func skipSpaces(_ index: inout Int) {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
        func readName(_ index: inout Int) -> String {
            let start = index
            while index < characters.count,
                  characters[index].isLetter || characters[index].isNumber ||
                    ["-", ":"].contains(characters[index]) {
                index += 1
            }
            return String(characters[start..<index]).lowercased()
        }

        var tokens: [HTMLSourceToken] = []
        var stack: [(String, Int)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "<" else { index += 1; continue }
            let tagOffset = index
            if index + 3 < characters.count,
               String(characters[index...min(index + 3, characters.count - 1)]) == "<!--" {
                index += 4
                while index + 2 < characters.count,
                      String(characters[index...index + 2]) != "-->" { index += 1 }
                guard index + 2 < characters.count else { throw malformed(tagOffset) }
                index += 3
                continue
            }
            index += 1
            let closing = index < characters.count && characters[index] == "/"
            if closing { index += 1 }
            skipSpaces(&index)
            let name = readName(&index)
            guard !name.isEmpty else { throw malformed(tagOffset) }
            guard ChapterTitleHTMLCodec.supportedTags.contains(name) else {
                let position = positions[tagOffset]
                throw ChapterTitleHTMLCodecError.unsupportedTag(
                    name: name,
                    line: position.line,
                    column: position.column
                )
            }
            if closing {
                skipSpaces(&index)
                guard index < characters.count, characters[index] == ">",
                      let open = stack.popLast(), open.0 == name else {
                    throw malformed(tagOffset)
                }
                index += 1
                continue
            }

            var attributes: [String: HTMLSourceAttribute] = [:]
            var selfClosing = false
            while index < characters.count {
                skipSpaces(&index)
                guard index < characters.count else { throw malformed(tagOffset) }
                if characters[index] == ">" { index += 1; break }
                if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == ">" {
                    selfClosing = true
                    index += 2
                    break
                }
                let nameOffset = index
                let attributeName = readName(&index)
                guard !attributeName.isEmpty else { throw malformed(index) }
                guard knownAttributes.contains(attributeName) else {
                    let position = positions[nameOffset]
                    throw ChapterTitleHTMLCodecError.unsupportedAttribute(
                        name: attributeName,
                        line: position.line,
                        column: position.column
                    )
                }
                guard attributes[attributeName] == nil else { throw malformed(nameOffset) }
                skipSpaces(&index)
                guard index < characters.count, characters[index] == "=" else { throw malformed(index) }
                index += 1
                skipSpaces(&index)
                guard index < characters.count, characters[index] == "\"" || characters[index] == "'" else {
                    throw malformed(index)
                }
                let quote = characters[index]
                index += 1
                let valueOffset = index
                let valueStart = index
                while index < characters.count, characters[index] != quote { index += 1 }
                guard index < characters.count else { throw malformed(valueOffset) }
                let value = String(characters[valueStart..<index])
                index += 1
                attributes[attributeName] = HTMLSourceAttribute(
                    value: value,
                    namePosition: positions[nameOffset],
                    valuePosition: positions[valueOffset]
                )
            }
            let position = positions[tagOffset]
            let token = HTMLSourceToken(name: name, position: position, attributes: attributes)
            try rejectRemoteResources(in: token)
            tokens.append(token)
            if !selfClosing, name != "img", name != "hr" { stack.append((name, tagOffset)) }
        }
        guard stack.isEmpty else { throw malformed(stack.last?.1 ?? characters.count) }
        return tokens
    }

    static func rejectRemoteResources(in token: HTMLSourceToken) throws {
        if let source = token.value("src"), ChapterTitleHTMLCodec.managedAssetID(source) == nil {
            throw ChapterTitleHTMLCodecError.remoteResource(
                line: token.position.line,
                column: token.position.column
            )
        }
        guard let style = token.value("style") else { return }
        let lower = style.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: "url(", range: searchStart..<lower.endIndex) {
            guard let close = lower[range.upperBound...].firstIndex(of: ")") else {
                throw ChapterTitleHTMLCodecError.malformedHTML(
                    line: token.position.line,
                    column: token.position.column
                )
            }
            var body = lower[range.upperBound..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            if (body.hasPrefix("\"") && body.hasSuffix("\"")) ||
                (body.hasPrefix("'") && body.hasSuffix("'")) {
                body = String(body.dropFirst().dropLast())
            }
            if ChapterTitleHTMLCodec.managedAssetID(body) == nil {
                throw ChapterTitleHTMLCodecError.remoteResource(
                    line: token.position.line,
                    column: token.position.column
                )
            }
            searchStart = lower.index(after: close)
        }
    }
}

fileprivate extension ChapterTitleHTMLCodec {
    static func rejectUnexpectedAttributes(_ token: HTMLSourceToken, allowed: Set<String>) throws {
        if let unexpected = token.attributes.first(where: { !allowed.contains($0.key) }) {
            throw ChapterTitleHTMLCodecError.unsupportedAttribute(
                name: unexpected.key,
                line: unexpected.value.namePosition.line,
                column: unexpected.value.namePosition.column
            )
        }
    }

    static func validatePlaceholders(
        in text: String,
        source: String,
        fallback: HTMLSourcePosition
    ) throws {
        guard let expression = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let placeholder = String(text[matchRange])
            guard ["{number}", "{name}", "{title}"].contains(placeholder) else {
                let position = sourcePosition(of: placeholder, in: source) ?? fallback
                throw ChapterTitleHTMLCodecError.invalidPlaceholder(
                    placeholder,
                    line: position.line,
                    column: position.column
                )
            }
        }
    }

    static func translate(
        _ error: ReaderStyleCSSCodecError,
        fromStyleIn token: HTMLSourceToken
    ) -> ChapterTitleHTMLCodecError {
        let base = token.attributes["style"]?.valuePosition ?? token.position
        switch error {
        case let .unsupportedProperty(name, line, column):
            let position = translated(line: line, column: column, from: base)
            return .unsupportedAttribute(name: name, line: position.line, column: position.column)
        case let .malformedDeclaration(line, column), let .invalidValue(_, _, line, column):
            let position = translated(line: line, column: column, from: base)
            return .malformedHTML(line: position.line, column: position.column)
        }
    }

    static func translated(line: Int, column: Int, from base: HTMLSourcePosition) -> HTMLSourcePosition {
        if line == 1 { return .init(line: base.line, column: base.column + column - 1) }
        return .init(line: base.line + line - 1, column: column)
    }

    static func sourcePosition(of needle: String, in source: String) -> HTMLSourcePosition? {
        guard let range = source.range(of: needle) else { return nil }
        var line = 1
        var column = 1
        for character in source[..<range.lowerBound] {
            if character == "\n" { line += 1; column = 1 } else { column += 1 }
        }
        return .init(line: line, column: column)
    }

    static func managedAssetID(_ source: String) -> UUID? {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("url("), value.hasSuffix(")") {
            value = String(value.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        let prefix = "yuedu-asset://"
        guard value.lowercased().hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
    }

    static func parseHex(_ source: String) -> UInt32? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#"), value.count == 7 else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        var result = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }

    static func attributeEscaped(_ source: String) -> String {
        textEscaped(source).replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func textEscaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
