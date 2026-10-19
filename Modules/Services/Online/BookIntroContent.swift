import Foundation
import SwiftSoup

// MARK: - Book introduction modes (Legado prefix modes)

/// How a book's introduction is presented, following legado-E and MD3: an intro whose
/// text (after leading whitespace) starts with `<usehtml>`, `<md>` or `<useweb>` is
/// kept as written and rendered as HTML, Markdown or a web page; anything else is
/// cleaned to plain text by Legado's `HtmlFormatter.format`. MD3 matches the prefixes
/// regardless of case, and so does this.
enum BookIntroContent: Equatable, Sendable {
    case plain(String)
    /// `<usehtml>`: an HTML fragment with its CSS.
    case html(String)
    /// `<md>`: Markdown.
    case markdown(String)
    /// `<useweb>`: a full page, CSS and all.
    case web(String)

    private static let prefixes: [(tag: String, make: @Sendable (String) -> BookIntroContent)] = [
        ("usehtml", { .html($0) }),
        ("md", { .markdown($0) }),
        ("useweb", { .web($0) }),
    ]

    /// Parses an intro that has already been through
    /// `OnlineBookDetailPresentationPolicy.sanitizeIntro`.
    init(_ intro: String) {
        let trimmed = intro.drop { $0.isWhitespace }
        for prefix in Self.prefixes {
            let open = "<\(prefix.tag)>"
            guard trimmed.lowercased().hasPrefix(open) else { continue }
            var body = String(trimmed.dropFirst(open.count))
            // legado-E reads up to the last `<`, dropping the closing tag.
            let close = "</\(prefix.tag)>"
            if let range = body.range(of: close, options: [.caseInsensitive, .backwards]) {
                body = String(body[..<range.lowerBound])
            }
            self = prefix.make(body.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        self = .plain(intro)
    }

    /// Whether `intro` uses one of the prefix modes, so cleaning must keep its markup.
    static func usesPrefixMode(_ intro: String) -> Bool {
        if case .plain = BookIntroContent(intro) { return false }
        return true
    }

    var isEmpty: Bool {
        switch self {
        case .plain(let text), .html(let text), .markdown(let text), .web(let text):
            text.isEmpty
        }
    }
}

// MARK: - Legado HtmlFormatter

/// Legado's `HtmlFormatter.format`, applied by every fork to search, explore and
/// detail introductions: block tags become line breaks, every other tag is removed,
/// and each paragraph is indented with two ideographic spaces.
///
/// One deliberate difference: Legado decodes only `&nbsp;`, `&ensp;` and `&emsp;`, so
/// an intro carrying `&amp;` shows the entity itself. This decodes all entities before
/// formatting, which reads correctly and leaves every intro Legado shows unchanged.
enum LegadoHTMLFormatter {
    private static let nbsp = try! NSRegularExpression(pattern: "(&nbsp;)+", options: [.caseInsensitive])
    private static let esp = try! NSRegularExpression(pattern: "(&ensp;|&emsp;)", options: [.caseInsensitive])
    private static let noPrint = try! NSRegularExpression(
        pattern: "(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})",
        options: [.caseInsensitive]
    )
    private static let wrapTags = try! NSRegularExpression(
        pattern: "</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>",
        options: [.caseInsensitive]
    )
    private static let comments = try! NSRegularExpression(pattern: "<!--[^>]*-->")
    private static let otherTags = try! NSRegularExpression(pattern: "</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private static let lineBreaks = try! NSRegularExpression(pattern: "\\s*\\n+\\s*")
    private static let leading = try! NSRegularExpression(pattern: "^[\\n\\s]+")
    private static let trailing = try! NSRegularExpression(pattern: "[\\n\\s]+$")

    static func format(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
        text = replace(nbsp, in: text, with: " ")
        text = replace(esp, in: text, with: " ")
        text = replace(noPrint, in: text, with: "")
        text = replace(wrapTags, in: text, with: "\n")
        text = replace(comments, in: text, with: "")
        text = replace(otherTags, in: text, with: "")
        text = decodingEntities(text)
        text = replace(lineBreaks, in: text, with: "\n　　")
        text = replace(leading, in: text, with: "　　")
        text = replace(trailing, in: text, with: "")
        return text
    }

    /// MD3's display normalisation on top of `format`: every paragraph, the first
    /// included, starts with the same two-space indent. Plain `format` indents only
    /// paragraphs that began with whitespace or a block tag, so an intro whose first
    /// line had neither read unindented above indented ones.
    static func indentingEveryParagraph(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces.union(["\u{3000}"])) }
            .filter { !$0.isEmpty }
            .map { "　　" + $0 }
            .joined(separator: "\n")
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        do {
            return try Entities.unescape(text)
        } catch {
            AppLogger.parse("⟐ intro entities could not be decoded", error: error)
            return text
        }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }
}

// MARK: - Interactive `<usehtml>` (Legado's intro buttons and image clicks)

/// A tappable part of a `<usehtml>` intro, read the way legado-E's `TextViewTagHandler`
/// and MD3's `HtmlParser` read it. Tapping runs `script` in the book's source, as their
/// `BookInfoViewModel.onButtonClick` / `runIntroJs` do.
struct BookIntroAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `<button>名稱@onclick:腳本</button>`.
        case button
        /// An image whose src carries Legado's URL options with a click: `url,{"click":"腳本"}`.
        case image
    }

    let kind: Kind
    /// The button's label; empty for an image.
    let name: String
    let script: String

    /// What Legado calls the action in its error toast: `info button 名稱` / `info image`.
    var displayName: String {
        switch kind {
        case .button: name
        case .image: localized("圖片")
        }
    }
}

/// A `<usehtml>` fragment as the intro's web view renders it: each button shows only its
/// label, each image src is the bare URL, and every element that runs a script carries
/// `data-yd-action="<index into actions>"`.
struct BookIntroInteractiveFragment: Equatable, Sendable {
    let html: String
    let actions: [BookIntroAction]

    static let actionAttribute = "data-yd-action"
    static let buttonClass = "yd-intro-button"

    /// Legado's `<button>` separator between the label and the script.
    private static let buttonSplit = "@onclick:"
    /// `AnalyzeUrl.paramPattern`: the comma that starts a URL's JSON options.
    private static let urlOptions = try! NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)")

    init(html: String, actions: [BookIntroAction]) {
        self.html = html
        self.actions = actions
    }

    init(fragment: String) {
        do {
            let document = try SwiftSoup.parseBodyFragment(fragment)
            // Pretty printing would put line breaks between inline elements, which the
            // web view renders as spaces.
            document.outputSettings().prettyPrint(pretty: false)
            guard let body = document.body() else {
                self.init(html: fragment, actions: [])
                return
            }
            var actions: [BookIntroAction] = []
            try Self.markButtons(in: body, actions: &actions)
            try Self.markImages(in: body, actions: &actions)
            self.init(html: try body.html(), actions: actions)
        } catch {
            // The intro still shows, as written; only its buttons and image clicks are lost.
            AppLogger.parse("⟐ <usehtml> intro could not be parsed", error: error)
            self.init(html: fragment, actions: [])
        }
    }

    /// legado-E splits a button's text at the first `@onclick:` and draws the part before
    /// it as the button; MD3 does the same and trims both parts. A button without the
    /// separator is plain text in both, and a blank script draws a button that does nothing.
    private static func markButtons(in body: Element, actions: inout [BookIntroAction]) throws {
        for button in try body.select("button") {
            let text = try button.text()
            guard let split = text.range(of: buttonSplit) else {
                try button.tagName("span")
                continue
            }
            let name = String(text[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let script = String(text[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            try button.text(name)
            try button.addClass(buttonClass)
            try button.attr("type", "button")
            guard !script.isEmpty else { continue }
            try button.attr(actionAttribute, String(actions.count))
            actions.append(BookIntroAction(kind: .button, name: name, script: script))
        }
    }

    /// An image src of the form `url,{"click":"腳本"}` loads `url`; tapping it runs the
    /// script. legado-E and MD3 read the options as a string map and take `click`.
    private static func markImages(in body: Element, actions: inout [BookIntroAction]) throws {
        for image in try body.select("img[src]") {
            let src = try image.attr("src")
            let range = NSRange(src.startIndex..., in: src)
            guard let match = urlOptions.firstMatch(in: src, range: range),
                  let separator = Range(match.range, in: src) else { continue }
            try image.attr("src", String(src[..<separator.lowerBound]))
            let options = String(src[separator.upperBound...])
            guard let script = clickScript(inURLOptions: options) else { continue }
            try image.attr(actionAttribute, String(actions.count))
            // VoiceOver offers it as a button, read by its alt text.
            try image.attr("role", "button")
            try image.attr("tabindex", "0")
            actions.append(BookIntroAction(kind: .image, name: "", script: script))
        }
    }

    private static func clickScript(inURLOptions options: String) -> String? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(options.utf8))
        } catch {
            AppLogger.parse("⟐ intro image options are not JSON", error: error)
            return nil
        }
        guard let click = (object as? [String: Any])?["click"] as? String else { return nil }
        let script = click.trimmingCharacters(in: .whitespacesAndNewlines)
        return script.isEmpty ? nil : script
    }
}
