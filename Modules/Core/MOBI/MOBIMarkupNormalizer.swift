import Foundation
import SwiftSoup

/// Rewrites a MOBI 6 section's HTML into XHTML that both reading engines and
/// WebKit read the way a Kindle shows it.
///
/// MOBI 6 has no CSS. Kindle formatting lives in presentational HTML and in two
/// attributes with Kindle-only meanings, documented on the MobileRead wiki's MOBI
/// page: `height` on a block is the space above it and `width` its first-line
/// indent, a negative one hanging. Browsers ignore those two, and the CoreText
/// engine reads no presentational attribute but an image's size and treats every
/// tag it does not know (`font`, `center`, `tt`…) as a block. So each becomes
/// inline CSS here.
enum MOBIMarkupNormalizer {
    /// Kindle's `<font size>` 1…7, as the HTML legacy font-size table maps them to
    /// keywords (x-small…xxx-large), written in `rem` because the engine knows
    /// neither end keyword and the keywords are relative to the root, not the parent.
    static let fontSizes = ["0.625rem", "0.8125rem", "1rem", "1.125rem", "1.5rem", "2rem", "3rem"]

    private static let blockTags: Set<String> = [
        "p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li", "dd", "dt",
    ]
    private static let alignTags: Set<String> = [
        "p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li", "dd", "dt",
        "td", "th", "tr", "caption",
    ]
    private static let voidTags: Set<String> = ["img", "br", "hr"]
    /// Where `width` and `height` keep their HTML meaning.
    private static let sizedTags: Set<String> = ["img", "td", "th", "table"]
    /// Elements an anchor cannot be moved into without breaking their content model.
    private static let structuralTags: Set<String> = [
        "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "dl", "select",
    ]

    /// Normalises `body` in place. `image(recindex)` is the `src` of a `recindex`
    /// image, relative to the chapter, nil when the file has no usable image there.
    static func normalize(_ body: Element, image: (Int) throws -> String?, warnings: inout [String]) throws {
        try removeComments(in: body)
        for element in try body.select("guide, reference, script").array() {
            try element.remove()
        }
        // Children before parents, so an unwrapped element's children are done.
        for element in try body.getAllElements().array().reversed() where element !== body {
            try normalizeElement(element, image: image, warnings: &warnings)
        }
        try sanitizeText(in: body)
        try placeAnchors(in: body)
    }

    private static func normalizeElement(_ element: Element, image: (Int) throws -> String?,
                                         warnings: inout [String]) throws {
        let tag = element.tagName().lowercased()
        // `mbp:` and any other name XML cannot hold: keep the content, drop the tag.
        guard isXMLName(tag) else {
            try element.unwrap()
            return
        }
        var styles: [(String, String)] = []

        switch tag {
        case "font":
            if let size = try fontSize(element.attr("size")) { styles.append(("font-size", size)) }
            if let color = try cssToken(element.attr("color")) { styles.append(("color", color)) }
            if let face = try fontFamily(element.attr("face")) { styles.append(("font-family", face)) }
            try element.tagName("span")
        case "center":
            styles.append(("text-align", "center"))
            try element.tagName("div")
        case "tt":
            styles.append(("font-family", "monospace"))
            try element.tagName("span")
        case "big":
            styles.append(("font-size", "larger"))
            try element.tagName("span")
        case "u", "ins":
            styles.append(("text-decoration", "underline"))
            try element.tagName("span")
        case "s", "strike", "del":
            styles.append(("text-decoration", "line-through"))
            try element.tagName("span")
        case "img":
            if element.hasAttr("recindex") {
                let recindex = try element.attr("recindex")
                if let index = Int(recindex.trimmingCharacters(in: .whitespaces)), index > 0,
                   let path = try image(index) {
                    try element.attr("src", path)
                } else {
                    warnings.append("an image names recindex \(recindex), which holds no image")
                    try element.remove()
                    return
                }
            }
        case "a":
            // Kindle tools leave anchors with nothing to point at or from.
            if element.getAttributes()?.size() == 0 {
                try element.unwrap()
                return
            }
        default:
            break
        }

        if blockTags.contains(tag) || tag == "center" {
            if let height = try length(element.attr("height")) { styles.append(("margin-top", height)) }
            if let width = try length(element.attr("width")) {
                styles.append(("text-indent", width))
                // A negative indent hangs: the rest of the block moves right by it.
                if width.hasPrefix("-") { styles.append(("margin-left", String(width.dropFirst()))) }
            }
        }
        if alignTags.contains(tag) || tag == "center", let align = try textAlign(element.attr("align")) {
            styles.append(("text-align", align))
        }
        if tag == "table", try element.attr("align").lowercased() == "center" {
            styles.append(("margin-left", "auto"))
            styles.append(("margin-right", "auto"))
        }
        try cleanAttributes(of: element, tag: tag)
        if !styles.isEmpty {
            let declared = styles.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            let existing = try element.attr("style").trimmingCharacters(in: .whitespaces)
            // The element's own style comes last, so it wins as it would have.
            try element.attr("style", existing.isEmpty ? declared : declared + "; " + existing)
        }
    }

    /// Drops what XHTML cannot carry or what was turned into CSS above.
    private static func cleanAttributes(of element: Element, tag: String) throws {
        guard let attributes = element.getAttributes() else { return }
        var drop: [String] = []
        for attribute in attributes {
            let key = attribute.getKey()
            let lower = key.lowercased()
            if !isXMLName(key) || lower.hasPrefix("xmlns") {
                drop.append(key)
                continue
            }
            switch lower {
            case "recindex", "valign", "size", "color", "face", "align":
                // Turned into CSS above, or (`align` on an image: `baseline` and
                // the like) nothing both engines share.
                drop.append(key)
            case "height" where !sizedTags.contains(tag), "width" where !sizedTags.contains(tag):
                drop.append(key)
            default:
                let value = attribute.getValue()
                let clean = xmlSafe(value)
                if clean != value { try element.attr(key, clean) }
            }
        }
        for key in drop { try element.removeAttr(key) }
    }

    // MARK: Values

    /// `1em`, `0pt`, `-14pt`, `5%`, or a bare number (pixels, as in HTML).
    static func length(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = value.range(of: #"^-?[0-9]*\.?[0-9]+(em|ex|pt|px|pc|in|cm|mm|%)?$"#,
                                      options: .regularExpression),
              match == value.startIndex..<value.endIndex else { return nil }
        let hasUnit = value.last.map { !$0.isNumber && $0 != "." } ?? false
        return hasUnit ? value : value + "px"
    }

    /// `1`…`7`, or `+n`/`-n` from the default 3.
    static func fontSize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let size: Int
        if value.hasPrefix("+") || value.hasPrefix("-"), let delta = Int(value) {
            size = 3 + delta
        } else if let absolute = Int(value) {
            size = absolute
        } else {
            return nil
        }
        return fontSizes[min(max(size, 1), 7) - 1]
    }

    private static func textAlign(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return ["left", "right", "center", "justify"].contains(value) ? value : nil
    }

    /// A colour name or `#rrggbb`: letters, digits and `#` only, so nothing can
    /// close the declaration.
    private static func cssToken(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "#"
        }) else { return nil }
        return value
    }

    private static func fontFamily(_ raw: String) -> String? {
        let names = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).filter { $0 != "\"" && $0 != "'" && $0 != ";" }
        }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.map { "'\($0)'" }.joined(separator: ", ")
    }

    // MARK: XML

    /// Text for an XML text node or a double-quoted attribute.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count)
        for scalar in xmlSafe(text).unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// An XML name without a namespace prefix.
    static func isXMLName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// Removes the characters XML 1.0 does not allow: C0 controls other than tab,
    /// newline and return, and U+FFFE/U+FFFF.
    static func xmlSafe(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isForbiddenInXML) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isForbiddenInXML($0) })
        return String(scalars)
    }

    private static func isForbiddenInXML(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D)
            || scalar.value == 0xFFFE || scalar.value == 0xFFFF
    }

    private static func removeComments(in node: Node) throws {
        for child in node.getChildNodes() {
            if child is Comment {
                try child.remove()
            } else {
                try removeComments(in: child)
            }
        }
    }

    private static func sanitizeText(in node: Node) throws {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                let whole = text.getWholeText()
                let clean = xmlSafe(whole)
                if clean != whole { text.text(clean) }
            } else {
                try sanitizeText(in: child)
            }
        }
    }

    // MARK: Anchors

    /// The converter puts an empty `<a id="fileposN">` wherever a link points.
    /// Between two blocks it would be an empty inline line of its own, so the id
    /// moves onto the element it stands before, or into it when that element has
    /// an id already. Last first, so a run of anchors before one block ends up
    /// on and inside that block in order.
    private static func placeAnchors(in body: Element) throws {
        for anchor in try body.select("a[id^=filepos]").array().reversed()
        where anchor.childNodeSize() == 0 && !anchor.hasAttr("href") {
            var next = anchor.nextSibling()
            while let text = next as? TextNode, text.isBlank() { next = text.nextSibling() }
            guard let target = next as? Element else { continue }
            let tag = target.tagName().lowercased()
            if !target.hasAttr("id") {
                try target.attr("id", anchor.attr("id"))
                try anchor.remove()
            } else if !voidTags.contains(tag), !structuralTags.contains(tag) {
                try target.prependChild(anchor)
            }
        }
    }
}
