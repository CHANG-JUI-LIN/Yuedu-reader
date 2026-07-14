import Foundation

enum ReaderBatterySVGError: Error, Equatable, Sendable {
    case sourceTooLarge
    case malformedXML
    case forbiddenDocumentType
    case multipleRoots
    case invalidRoot
    case forbiddenElement(String)
    case forbiddenAttribute(String)
    case externalReference(String)
    case invalidRole(String)
    case invalidVisibility(String)
    case invalidDirection(String)
    case conflictingDirections
    case missingCoordinateSystem
    case invalidViewBox
    case invalidDimensions
    case maximumDepthExceeded
    case maximumNodeCountExceeded
    case invalidColor(String)
    case invalidLevel
}

struct ReaderBatterySVGTemplate: Equatable, Sendable {
    static let validationVersion = 1

    let validatedSource: String

    private let root: SVGElement
    private let viewBox: SVGViewBox
    private let direction: BatteryFillDirection

    init(source: String) throws {
        guard source.utf8.count <= SVGParserDelegate.maximumSourceSize else {
            throw ReaderBatterySVGError.sourceTooLarge
        }
        guard !Self.containsDocumentTypeOrEntity(in: source) else {
            throw ReaderBatterySVGError.forbiddenDocumentType
        }

        let delegate = SVGParserDelegate()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw delegate.failure ?? ReaderBatterySVGError.malformedXML
        }
        if let failure = delegate.failure {
            throw failure
        }
        guard var root = delegate.root, root.name == "svg" else {
            throw ReaderBatterySVGError.invalidRoot
        }

        try Self.validateMarkerPlacement(in: root, insideResourceDefinition: false)
        let viewBox = try Self.resolveViewBox(in: &root)
        let directions = Self.batteryDirections(in: root)
        guard Set(directions).count <= 1 else {
            throw ReaderBatterySVGError.conflictingDirections
        }

        self.root = root
        self.viewBox = viewBox
        direction = directions.first ?? .leftToRight
        validatedSource = SVGSerializer.serialize(root)
    }

    func render(
        level: Double,
        isCharging: Bool,
        colorHex: String
    ) throws -> String {
        guard level.isFinite else {
            throw ReaderBatterySVGError.invalidLevel
        }
        guard Self.isRGBAHex(colorHex) else {
            throw ReaderBatterySVGError.invalidColor(colorHex)
        }

        let normalizedLevel = min(max(level, 0), 1)
        let percent = Int((normalizedLevel * 100).rounded())
        let clipID = Self.uniqueClipID(in: root)
        let clipRect = Self.makeClipRect(
            viewBox: viewBox,
            level: normalizedLevel,
            direction: direction
        )

        var renderedRoot = root
        let hasBatteryLevel = Self.containsBatteryLevel(in: renderedRoot)
        renderedRoot = Self.transform(
            renderedRoot,
            clipID: hasBatteryLevel ? clipID : nil,
            percent: percent,
            isCharging: isCharging
        )
        if hasBatteryLevel {
            Self.injectClipPath(id: clipID, rect: clipRect, into: &renderedRoot)
        }
        renderedRoot.attributes["color"] = colorHex.uppercased()
        return SVGSerializer.serialize(renderedRoot)
    }

    private static func resolveViewBox(in root: inout SVGElement) throws -> SVGViewBox {
        if let rawViewBox = root.attributes["viewBox"] {
            guard let viewBox = SVGViewBox(rawValue: rawViewBox) else {
                throw ReaderBatterySVGError.invalidViewBox
            }
            return viewBox
        }

        guard let rawWidth = root.attributes["width"],
              let rawHeight = root.attributes["height"] else {
            throw ReaderBatterySVGError.missingCoordinateSystem
        }
        guard let width = parseStableDimension(rawWidth),
              let height = parseStableDimension(rawHeight) else {
            throw ReaderBatterySVGError.invalidDimensions
        }

        let viewBox = SVGViewBox(minX: 0, minY: 0, width: width, height: height)
        root.attributes["viewBox"] = viewBox.serialized
        return viewBox
    }

    private static func parseStableDimension(_ rawValue: String) -> Double? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix("px") {
            value.removeLast(2)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "+-0123456789.eE").contains($0)
              }),
              let number = Double(value),
              number.isFinite,
              number > 0 else {
            return nil
        }
        return number
    }

    private static func batteryDirections(in element: SVGElement) -> [BatteryFillDirection] {
        var results: [BatteryFillDirection] = []
        if element.attributes["data-yuedu-role"] == "battery-level" {
            let rawDirection = element.attributes["data-yuedu-direction"] ?? BatteryFillDirection.leftToRight.rawValue
            if let direction = BatteryFillDirection(rawValue: rawDirection) {
                results.append(direction)
            }
        }
        for child in element.children {
            if case let .element(childElement) = child {
                results.append(contentsOf: batteryDirections(in: childElement))
            }
        }
        return results
    }

    private static func validateMarkerPlacement(
        in element: SVGElement,
        insideResourceDefinition: Bool
    ) throws {
        let resourceElements: Set<String> = ["defs", "clipPath", "mask", "linearGradient", "radialGradient"]
        let isInsideResourceDefinition = insideResourceDefinition || resourceElements.contains(element.name)
        if isInsideResourceDefinition {
            if let role = element.attributes["data-yuedu-role"] {
                throw ReaderBatterySVGError.invalidRole(role)
            }
            if let visibility = element.attributes["data-yuedu-visible"] {
                throw ReaderBatterySVGError.invalidVisibility(visibility)
            }
        }
        for child in element.children {
            if case let .element(childElement) = child {
                try validateMarkerPlacement(
                    in: childElement,
                    insideResourceDefinition: isInsideResourceDefinition
                )
            }
        }
    }

    private static func containsBatteryLevel(in element: SVGElement) -> Bool {
        if element.attributes["data-yuedu-role"] == "battery-level" {
            return true
        }
        return element.children.contains { child in
            guard case let .element(childElement) = child else { return false }
            return containsBatteryLevel(in: childElement)
        }
    }

    private static func transform(
        _ element: SVGElement,
        clipID: String?,
        percent: Int,
        isCharging: Bool
    ) -> SVGElement {
        var result = element
        let role = result.attributes["data-yuedu-role"]

        if role == "battery-percent" {
            result.children = [.text("\(percent)%")]
        } else {
            result.children = result.children.compactMap { child in
                guard case let .element(childElement) = child else { return child }
                if childElement.attributes["data-yuedu-visible"] == "charging", !isCharging {
                    return nil
                }
                let childRole = childElement.attributes["data-yuedu-role"]
                let transformedChild = transform(
                    childElement,
                    clipID: clipID,
                    percent: percent,
                    isCharging: isCharging
                )
                if childRole == "battery-level", let clipID {
                    return .element(SVGElement(
                        name: "g",
                        attributes: ["clip-path": "url(#\(clipID))"],
                        children: [.element(transformedChild)]
                    ))
                }
                return .element(transformedChild)
            }
        }

        for key in result.attributes.keys where key.hasPrefix("data-yuedu-") {
            result.attributes.removeValue(forKey: key)
        }
        return result
    }

    private static func uniqueClipID(in root: SVGElement) -> String {
        var identifiers: Set<String> = []
        collectIdentifiers(in: root, into: &identifiers)
        let base = "yuedu-battery-level-clip"
        guard identifiers.contains(base) else { return base }

        var suffix = 2
        while identifiers.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static func collectIdentifiers(in element: SVGElement, into identifiers: inout Set<String>) {
        if let identifier = element.attributes["id"] {
            identifiers.insert(identifier)
        }
        for child in element.children {
            if case let .element(childElement) = child {
                collectIdentifiers(in: childElement, into: &identifiers)
            }
        }
    }

    private static func makeClipRect(
        viewBox: SVGViewBox,
        level: Double,
        direction: BatteryFillDirection
    ) -> SVGElement {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        switch direction {
        case .leftToRight:
            x = viewBox.minX
            y = viewBox.minY
            width = viewBox.width * level
            height = viewBox.height
        case .rightToLeft:
            x = viewBox.minX + viewBox.width * (1 - level)
            y = viewBox.minY
            width = viewBox.width * level
            height = viewBox.height
        case .bottomToTop:
            x = viewBox.minX
            y = viewBox.minY + viewBox.height * (1 - level)
            width = viewBox.width
            height = viewBox.height * level
        case .topToBottom:
            x = viewBox.minX
            y = viewBox.minY
            width = viewBox.width
            height = viewBox.height * level
        }

        return SVGElement(
            name: "rect",
            attributes: [
                "x": SVGNumber.format(x),
                "y": SVGNumber.format(y),
                "width": SVGNumber.format(width),
                "height": SVGNumber.format(height)
            ],
            children: []
        )
    }

    private static func injectClipPath(id: String, rect: SVGElement, into root: inout SVGElement) {
        let clipPath = SVGElement(
            name: "clipPath",
            attributes: ["id": id],
            children: [.element(rect)]
        )
        if let index = root.children.firstIndex(where: { child in
            guard case let .element(element) = child else { return false }
            return element.name == "defs"
        }), case var .element(defs) = root.children[index] {
            defs.children.insert(.element(clipPath), at: 0)
            root.children[index] = .element(defs)
        } else {
            root.children.insert(
                .element(SVGElement(name: "defs", attributes: [:], children: [.element(clipPath)])),
                at: 0
            )
        }
    }

    private static func containsDocumentTypeOrEntity(in source: String) -> Bool {
        let uppercase = source.uppercased()
        return uppercase.contains("<!DOCTYPE") || uppercase.contains("<!ENTITY")
    }

    private static func isRGBAHex(_ value: String) -> Bool {
        guard value.count == 9, value.first == "#" else { return false }
        return value.dropFirst().unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0)
        }
    }
}

private enum BatteryFillDirection: String, Equatable, Sendable {
    case leftToRight = "left-to-right"
    case rightToLeft = "right-to-left"
    case bottomToTop = "bottom-to-top"
    case topToBottom = "top-to-bottom"
}

private struct SVGViewBox: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    init?(rawValue: String) {
        let components = rawValue
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard components.count == 4 else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == components.count,
              values.allSatisfy(\.isFinite),
              values[2] > 0,
              values[3] > 0 else {
            return nil
        }
        self.init(minX: values[0], minY: values[1], width: values[2], height: values[3])
    }

    var serialized: String {
        [minX, minY, width, height].map(SVGNumber.format).joined(separator: " ")
    }
}

private enum SVGNumber {
    static func format(_ value: Double) -> String {
        let normalized = value == 0 ? 0 : value
        if normalized >= Double(Int64.min),
           normalized <= Double(Int64.max),
           normalized.rounded() == normalized {
            return String(Int64(normalized))
        }
        return String(normalized)
    }
}

private struct SVGElement: Equatable, Sendable {
    var name: String
    var attributes: [String: String]
    var children: [SVGNode]
}

private indirect enum SVGNode: Equatable, Sendable {
    case element(SVGElement)
    case text(String)
}

private final class SVGParserDelegate: NSObject, XMLParserDelegate {
    static let maximumSourceSize = 256 * 1_024
    static let maximumDepth = 64
    static let maximumNodeCount = 10_000

    private(set) var root: SVGElement?
    private(set) var failure: ReaderBatterySVGError?

    private var stack: [SVGElement] = []
    private var nodeCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        guard stack.count + 1 <= Self.maximumDepth else {
            fail(.maximumDepthExceeded, parser: parser)
            return
        }
        guard incrementNodeCount(parser: parser) else { return }

        let originalName = qName ?? elementName
        guard let name = SVGValidation.canonicalElementName(originalName) else {
            fail(.forbiddenElement(originalName), parser: parser)
            return
        }
        if stack.isEmpty, root != nil {
            fail(.multipleRoots, parser: parser)
            return
        }
        if stack.isEmpty, name != "svg" {
            fail(.invalidRoot, parser: parser)
            return
        }
        do {
            let attributes = try SVGValidation.validateAttributes(attributeDict, elementName: name)
            stack.append(SVGElement(name: name, attributes: attributes, children: []))
        } catch let error as ReaderBatterySVGError {
            fail(error, parser: parser)
        } catch {
            fail(.malformedXML, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            fail(.malformedXML, parser: parser)
            return
        }
        appendText(text, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil, let element = stack.popLast() else { return }
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(.element(element))
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil {
            failure = .malformedXML
        }
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        fail(.forbiddenDocumentType, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(.forbiddenDocumentType, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(.forbiddenDocumentType, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(.forbiddenDocumentType, parser: parser)
        return nil
    }

    private func appendText(_ text: String, parser: XMLParser) {
        guard failure == nil, !stack.isEmpty else { return }
        let preservesTextWhitespace = ["text", "tspan", "title", "desc"].contains(stack[stack.count - 1].name)
            || stack[stack.count - 1].children.last.map {
                if case .text = $0 { return true }
                return false
            } == true
        guard preservesTextWhitespace
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if case let .text(existing)? = stack[stack.count - 1].children.last {
            stack[stack.count - 1].children[stack[stack.count - 1].children.count - 1] = .text(existing + text)
            return
        }
        guard incrementNodeCount(parser: parser) else { return }
        stack[stack.count - 1].children.append(.text(text))
    }

    private func incrementNodeCount(parser: XMLParser) -> Bool {
        nodeCount += 1
        guard nodeCount <= Self.maximumNodeCount else {
            fail(.maximumNodeCountExceeded, parser: parser)
            return false
        }
        return true
    }

    private func fail(_ error: ReaderBatterySVGError, parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

private enum SVGValidation {
    private static let elementNames: [String: String] = [
        "svg": "svg",
        "g": "g",
        "defs": "defs",
        "clippath": "clipPath",
        "mask": "mask",
        "path": "path",
        "rect": "rect",
        "circle": "circle",
        "ellipse": "ellipse",
        "line": "line",
        "polyline": "polyline",
        "polygon": "polygon",
        "text": "text",
        "tspan": "tspan",
        "lineargradient": "linearGradient",
        "radialgradient": "radialGradient",
        "stop": "stop",
        "title": "title",
        "desc": "desc"
    ]

    private static let attributeNames: [String: String] = {
        let names = [
            "id", "class", "version", "xmlns", "xmlns:xlink", "xml:space",
            "viewBox", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
            "width", "height", "d", "points", "pathLength", "transform", "preserveAspectRatio",
            "opacity", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
            "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
            "clip-path", "clip-rule", "clipPathUnits", "mask", "maskUnits", "maskContentUnits",
            "gradientUnits", "gradientTransform", "spreadMethod", "offset", "stop-color", "stop-opacity",
            "href", "xlink:href", "color", "style", "font-family", "font-size", "font-weight", "font-style",
            "text-anchor", "dominant-baseline", "alignment-baseline", "baseline-shift", "letter-spacing",
            "word-spacing", "paint-order", "vector-effect", "visibility", "display", "shape-rendering",
            "text-rendering", "color-interpolation", "data-yuedu-role", "data-yuedu-visible",
            "data-yuedu-direction"
        ]
        return Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
    }()

    private static let safeStyleProperties: Set<String> = [
        "opacity", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
        "clip-path", "clip-rule", "mask", "color", "font-family", "font-size", "font-weight", "font-style",
        "text-anchor", "dominant-baseline", "alignment-baseline", "baseline-shift", "letter-spacing",
        "word-spacing", "paint-order", "vector-effect", "visibility", "display", "shape-rendering",
        "text-rendering", "stop-color", "stop-opacity"
    ]

    private static let batteryLevelElements: Set<String> = [
        "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon"
    ]

    static func canonicalElementName(_ name: String) -> String? {
        guard !name.contains(":") else { return nil }
        return elementNames[name.lowercased()]
    }

    static func validateAttributes(
        _ rawAttributes: [String: String],
        elementName: String
    ) throws -> [String: String] {
        var attributes: [String: String] = [:]
        for (rawName, value) in rawAttributes {
            let normalizedName = rawName.lowercased()
            guard !normalizedName.hasPrefix("on"),
                  let canonicalName = attributeNames[normalizedName] else {
                throw ReaderBatterySVGError.forbiddenAttribute(rawName)
            }
            guard attributes[canonicalName] == nil else {
                throw ReaderBatterySVGError.forbiddenAttribute(rawName)
            }

            if canonicalName == "xmlns", value != "http://www.w3.org/2000/svg" {
                throw ReaderBatterySVGError.externalReference(value)
            }
            if canonicalName == "xmlns:xlink", value != "http://www.w3.org/1999/xlink" {
                throw ReaderBatterySVGError.externalReference(value)
            }
            if canonicalName == "href" || canonicalName == "xlink:href" {
                guard isInternalFragment(value) else {
                    throw ReaderBatterySVGError.externalReference(value)
                }
            } else if canonicalName != "xmlns", canonicalName != "xmlns:xlink" {
                try validateReferences(in: value)
            }
            if canonicalName == "style" {
                try validateStyle(value)
            }

            attributes[canonicalName] = value
        }

        try validateYueduMarkers(attributes, elementName: elementName)
        return attributes
    }

    private static func validateYueduMarkers(
        _ attributes: [String: String],
        elementName: String
    ) throws {
        if let role = attributes["data-yuedu-role"] {
            guard role == "battery-level" || role == "battery-percent" else {
                throw ReaderBatterySVGError.invalidRole(role)
            }
            if role == "battery-level", !batteryLevelElements.contains(elementName) {
                throw ReaderBatterySVGError.invalidRole(role)
            }
            if role == "battery-percent", elementName != "text", elementName != "tspan" {
                throw ReaderBatterySVGError.invalidRole(role)
            }
        }

        if let visibility = attributes["data-yuedu-visible"] {
            guard visibility == "charging",
                  !["svg", "defs", "clipPath", "mask"].contains(elementName) else {
                throw ReaderBatterySVGError.invalidVisibility(visibility)
            }
        }

        if let direction = attributes["data-yuedu-direction"] {
            guard BatteryFillDirection(rawValue: direction) != nil else {
                throw ReaderBatterySVGError.invalidDirection(direction)
            }
            guard attributes["data-yuedu-role"] == "battery-level" else {
                throw ReaderBatterySVGError.forbiddenAttribute("data-yuedu-direction")
            }
        }
    }

    private static func validateStyle(_ style: String) throws {
        let lowered = style.lowercased()
        guard !lowered.contains("@"),
              !lowered.contains("{") && !lowered.contains("}"),
              !lowered.contains("expression(") else {
            throw ReaderBatterySVGError.externalReference(style)
        }

        for declaration in style.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = declaration.firstIndex(of: ":") else {
                throw ReaderBatterySVGError.forbiddenAttribute("style")
            }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard safeStyleProperties.contains(property), !value.isEmpty else {
                throw ReaderBatterySVGError.forbiddenAttribute("style")
            }
            try validateReferences(in: value)
        }
    }

    private static func validateReferences(in value: String) throws {
        let lowered = value.lowercased()
        let forbiddenSchemes = ["javascript:", "https:", "http:", "data:", "file:", "ftp:"]
        if forbiddenSchemes.contains(where: lowered.contains)
            || lowered.contains("//")
            || value.contains("\\")
            || lowered.contains("/*")
            || lowered.contains("*/") {
            throw ReaderBatterySVGError.externalReference(value)
        }

        var searchStart = value.startIndex
        while let range = value.range(of: "url(", options: .caseInsensitive, range: searchStart..<value.endIndex) {
            guard let close = value[range.upperBound...].firstIndex(of: ")") else {
                throw ReaderBatterySVGError.externalReference(value)
            }
            var target = value[range.upperBound..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            if target.count >= 2,
               (target.first == "\"" && target.last == "\"" || target.first == "'" && target.last == "'") {
                target.removeFirst()
                target.removeLast()
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard isInternalFragment(target) else {
                throw ReaderBatterySVGError.externalReference(value)
            }
            searchStart = value.index(after: close)
        }
    }

    private static func isInternalFragment<S: StringProtocol>(_ value: S) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#", trimmed.count > 1 else { return false }
        return trimmed.dropFirst().unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-.:".unicodeScalars.contains($0)
        }
    }
}

private enum SVGSerializer {
    static func serialize(_ element: SVGElement) -> String {
        var result = "<\(element.name)"
        for key in element.attributes.keys.sorted() {
            guard let value = element.attributes[key] else { continue }
            result += " \(key)=\"\(escape(value))\""
        }
        guard !element.children.isEmpty else {
            return result + "/>"
        }

        result += ">"
        for child in element.children {
            switch child {
            case let .element(childElement):
                result += serialize(childElement)
            case let .text(text):
                result += escape(text)
            }
        }
        return result + "</\(element.name)>"
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
