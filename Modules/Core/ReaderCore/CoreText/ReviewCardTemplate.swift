import CoreGraphics
import Foundation

/// A reader's own drawing of a source review card (本章說 / 作者說 / 神評論): an SVG whose
/// `${…}` placeholders are filled from the card the source shipped (`ReviewCardContent`).
///
/// The contract a template is written to — the help under 氣泡設定 says the same:
/// - The card is always the reading column wide; the root's `height` is its least height, in
///   points. A root `viewBox` is dropped, so one SVG unit is one point and `1em` is the
///   reading body size. Lay the card out with percentages and `em`.
/// - Text is HTML inside `<foreignObject>`, which wraps and clamps it. A `<foreignObject>`
///   whose HTML outgrows its `height` grows to fit, and the card grows with it.
/// - `${title}` `${count}` `${num}` `${color}` describe the card, `${accent}` is the colour
///   起點 marks a card with on the reading background (red on 白色 and 黑色, green on 護眼綠,
///   brown on 棕色); `${user}` `${likes}` `${content}` describe a comment. An element marked `data-yd-repeat` is drawn once per
///   comment (at most as many as its value, when it has one); outside it, the comment
///   placeholders read the first comment. `data-yd-optional="likes user"` drops the element
///   when any field it names is empty.
/// - An element marked `data-yd-glass` is a panel of the system's glass: the reader draws the
///   glass in its place, with the element's `border-radius`, and its own background, border
///   and shadow are not painted.
/// - The root carries the class `yd-day` or `yd-night`, the reading font, size and text colour.
///
/// It is drawn in a WebView, so it is sanitized as it is read: scripts, event handlers and
/// anything that would load from outside the template are removed.
struct ReviewCardTemplate: Sendable {

    enum Failure: Error, Equatable, LocalizedError {
        case unreadable(line: Int, column: Int, reason: String)
        case notSVG
        case tooLarge

        var errorDescription: String? {
            switch self {
            case let .unreadable(line, column, reason):
                return String(format: localized("模板無法讀取（第 %d 行第 %d 欄）：%@"), line, column, reason)
            case .notSVG:
                return localized("模板的最外層必須是 <svg>。")
            case .tooLarge:
                return localized("模板太大，請縮小到 256 KB 以內。")
            }
        }
    }

    /// The SVG a filled template is drawn from, and how it wants the reader's text.
    struct Appearance: Equatable, Sendable {
        /// The reading body size, in points: `1em` in the template.
        var pointSize: CGFloat
        /// CSS `font-family` value for the reading font.
        var fontFamilyCSS: String
        /// `@font-face` rules the family needs, or empty.
        var fontFaceCSS: String
        /// The reading text colour, as CSS.
        var textColorHex: String
        /// The reading theme's accent (`ReaderTheme.commentCardAccent`), as CSS.
        var accentHex: String
        var isNight: Bool
    }

    static let maximumSourceLength = 256 * 1024

    private let root: Element

    init(source: String) throws {
        guard source.utf8.count <= Self.maximumSourceLength else { throw Failure.tooLarge }
        let builder = TreeBuilder(source: Self.numericEntities(in: source))
        let root = try builder.parse()
        guard root.name.lowercased() == "svg" else { throw Failure.notSVG }
        self.root = root
    }

    /// The template filled from `card`, ready for `SVGWebViewRasterizer.renderCard`.
    /// `colorHex` is what `${color}` stands for.
    func filled(
        with card: ReviewCardContent,
        appearance: Appearance,
        width: CGFloat,
        colorHex: String
    ) -> String {
        let first = card.comments.first
        let cardValues: [String: String] = [
            "title": card.title.isEmpty ? card.kind.localizedTitle : card.title,
            "count": card.count,
            "num": card.number,
            "color": colorHex,
            "accent": appearance.accentHex,
            "user": first?.user ?? "",
            "likes": first?.likes ?? "",
            "content": first?.content ?? "",
        ]
        var filledRoot = Self.expanded(root, values: cardValues, comments: card.comments)
            ?? Element(name: "svg", attributes: [:], children: [])
        Self.dress(&filledRoot, appearance: appearance, width: width)
        var output = ""
        Self.serialize(.element(filledRoot), into: &output, inHTML: false, parentName: "")
        return output
    }

    // MARK: - Built-in

    /// The built-in 玻璃 template for `kind`, laid out as 起點 lays out its cards: the card's
    /// text on a `data-yd-glass` panel, which the reader draws as the system's glass
    /// (`ReviewCardGlassPanel`).
    static func builtinSource(for kind: ReaderCommentCardKind) -> String {
        switch kind {
        case .chapterSay: return chapterSayGlass
        case .authorSay: return authorSayGlass
        case .hotComment: return hotCommentGlass
        }
    }

    /// Layout only: the panel behind it is the system's glass, so nothing here paints one.
    ///
    /// 起點 sets its cards apart from the prose, in the system font at fixed sizes whatever the
    /// reading font and size. The sizes are measured off 起點 on an iPhone 16 Pro Max
    /// (2026-10-21): its 本章說 has a 15pt title, 14pt names and comments (two lines at most),
    /// likes in a 22pt capsule, 10pt corners and 16pt insets. Sizes here are in `px` (a point)
    /// for that reason; 作家說, which 起點 sizes with the reading text, overrides them in `em`,
    /// as a custom template gets the reading text through `1em`.
    ///
    /// A comment's lines run to the card's edge before the clamp cuts them (`break-all`): kept
    /// whole, a Latin word or a run of digits (`hhhhhh`, `666`) moves down entire, the line it
    /// leaves ends short, and the clamp's `…` comes before the card is full.
    private static let cardStyle = """
    .card { box-sizing: border-box; margin: 6px 0; padding: 14px 16px 16px;
      border-radius: 10px; color: ${color}; font-family: -apple-system, sans-serif;
      font-size: 14px; line-height: 1.53; }
    .head { display: flex; justify-content: space-between; align-items: baseline; }
    .title { font-size: 15px; font-weight: 500; }
    .count { flex: none; margin-left: 8px; opacity: 0.5; }
    .cmt { margin-top: 9px; }
    .head + .cmt { margin-top: 14px; }
    .meta { display: flex; align-items: center; justify-content: space-between; min-height: 22px; }
    .user { opacity: 0.5; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .likes { flex: none; display: flex; align-items: center; gap: 2px; margin-left: 8px; padding: 0 9px;
      height: 22px; border-radius: 11px; background: rgba(128, 128, 128, 0.12); font-size: 13px; }
    .likes svg, .likes .n { opacity: 0.55; }
    .likes svg { width: 14px; height: 14px; }
    .text { margin-top: 5px; overflow: hidden; display: -webkit-box; -webkit-box-orient: vertical;
      word-break: break-all; }
    """

    /// A like count with its thumbs-up, as 起點 draws it.
    private static let likes = """
    <span class="likes" data-yd-optional="likes"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M5 7.2V14H2.6a.6.6 0 0 1-.6-.6V7.8a.6.6 0 0 1 .6-.6H5Zm0 0 2.5-5c.2-.4.6-.6 1-.5.9.2 1.4 1 1.3 1.9L9.5 6H13a1.5 1.5 0 0 1 1.5 1.8l-1 4.9A1.6 1.6 0 0 1 12 14H5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg><span class="n">${likes}</span></span>
    """

    /// 起點 shows a chapter's two top comments, each up to two lines.
    private static let chapterSayGlass = """
    <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="1">
    <style>
    \(cardStyle)
    .text { -webkit-line-clamp: 2; }
    </style>
    <foreignObject x="0" y="0" width="100%" height="1">
    <div xmlns="http://www.w3.org/1999/xhtml" class="card" data-yd-glass="">
    <div class="head"><span class="title">${title}</span><span class="count" data-yd-optional="count">${count} ›</span></div>
    <div class="cmt" data-yd-repeat="2">
    <div class="meta" data-yd-optional="user"><span class="user">${user}</span>\(likes)</div>
    <div class="text" data-yd-optional="content">${content}</div>
    </div>
    </div>
    </foreignObject>
    </svg>
    """

    /// 起點's 作家說, laid out as 起點 lays it out: the heading as a tag in the card's top-right
    /// corner, flaring into its top edge; the author's name on a row of its own (where 起點
    /// has the avatar, which a source card does not carry); the note muted, kept to its own
    /// lines (a 推薦, a sign-off), up to eight of them.
    ///
    /// Unlike 本章說 and 神評論, 起點 sizes its 作家說 with the reading text, so this card is
    /// in `em`: 0.75em, the 14pt 起點 shows at a 19pt reading size, and everything in it
    /// scales from that.
    private static let authorSayGlass = """
    <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="1">
    <style>
    \(cardStyle)
    .card { position: relative; font-size: 0.75em; padding: 0.86em 1.14em 1.29em; border-radius: 0.71em; }
    .tag { position: absolute; top: 0; right: 0; padding: 0 0.67em; border-radius: 0 0.83em 0 0.83em;
      background: linear-gradient(90deg, #5B7BF5, #7E97F7); color: #FFFFFF;
      font-size: 0.86em; font-weight: 500; line-height: 1.67; }
    .tag::before { content: ""; position: absolute; top: 0; left: -0.83em; width: 0.83em; height: 0.83em;
      background: radial-gradient(circle at 0 100%, transparent 0.83em, #5B7BF5 0.87em); }
    .cmt, .head + .cmt { margin-top: 0; }
    .meta { min-height: 1.71em; }
    .user { opacity: 1; }
    .text { margin-top: 0.43em; opacity: 0.75; white-space: pre-line; -webkit-line-clamp: 8; }
    </style>
    <foreignObject x="0" y="0" width="100%" height="1">
    <div xmlns="http://www.w3.org/1999/xhtml" class="card" data-yd-glass="">
    <span class="tag">${title}</span>
    <div class="cmt" data-yd-repeat="">
    <div class="meta"><span class="user" data-yd-optional="user">${user}</span></div>
    <div class="text" data-yd-optional="content">${content}</div>
    </div>
    </div>
    </foreignObject>
    </svg>
    """

    /// 起點's 神評論, measured the same way: its 10pt tag in white on the background's accent,
    /// then the comment in 13pt on one line, in a card 40pt tall with 8pt corners. No like
    /// count, as 起點 shows none here.
    private static let hotCommentGlass = """
    <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="1">
    <style>
    \(cardStyle)
    .cards { display: flow-root; }
    .card { display: flex; align-items: center; min-height: 40px; padding: 0 12px 0 10px;
      border-radius: 8px; font-size: 13px; line-height: 1.45; }
    .title { flex: none; margin-right: 6px; padding: 0 4px; border-radius: 4px; line-height: 16px;
      background: ${accent}; color: #FFFFFF; font-size: 10px; font-weight: 600; }
    .text { flex: 1; min-width: 0; margin-top: 0; display: block; opacity: 0.8;
      text-overflow: ellipsis; white-space: nowrap; }
    </style>
    <foreignObject x="0" y="0" width="100%" height="1">
    <div xmlns="http://www.w3.org/1999/xhtml" class="cards">
    <div class="card" data-yd-glass="" data-yd-repeat=""><span class="title">${title}</span><span class="text">${content}</span></div>
    </div>
    </foreignObject>
    </svg>
    """

    // MARK: - Tree

    fileprivate struct Element: Sendable {
        var name: String
        var attributes: [String: String]
        var children: [Node]
    }

    fileprivate indirect enum Node: Sendable {
        case element(Element)
        case text(String)
    }

    // MARK: - Filling

    private static let repeatAttribute = "data-yd-repeat"
    private static let optionalAttribute = "data-yd-optional"

    /// `element` with its repeats expanded, its optional parts dropped and its placeholders
    /// filled; nil when it is optional and a field it names is empty.
    private static func expanded(
        _ element: Element,
        values: [String: String],
        comments: [ReviewCardContent.Comment]
    ) -> Element? {
        var element = element
        if let optional = element.attributes.removeValue(forKey: optionalAttribute) {
            let names = optional.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            if names.contains(where: { (values[$0] ?? "").isEmpty }) { return nil }
        }
        element.attributes = element.attributes.mapValues { filledText($0, values: values) }
        var children: [Node] = []
        for child in element.children {
            switch child {
            case .text(let text):
                children.append(.text(filledText(text, values: values)))
            case .element(let childElement):
                guard let limit = childElement.attributes[repeatAttribute] else {
                    if let filled = expanded(childElement, values: values, comments: comments) {
                        children.append(.element(filled))
                    }
                    continue
                }
                var template = childElement
                template.attributes.removeValue(forKey: repeatAttribute)
                let cap = Int(limit.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
                for comment in comments.prefix(cap ?? comments.count) {
                    var commentValues = values
                    commentValues["user"] = comment.user
                    commentValues["likes"] = comment.likes
                    commentValues["content"] = comment.content
                    if let filled = expanded(template, values: commentValues, comments: comments) {
                        children.append(.element(filled))
                    }
                }
            }
        }
        element.children = children
        return element
    }

    /// One pass, left to right: a comment that itself says `${title}` stays as it was written.
    private static func filledText(_ text: String, values: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = String(rest[open.upperBound..<close])
            result += values[name] ?? String(rest[open.lowerBound...close])
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// Sizes the root to the column and hands it the reader's text.
    private static func dress(_ root: inout Element, appearance: Appearance, width: CGFloat) {
        let declaredHeight = root.attributes["height"].flatMap(points) ?? 1
        root.attributes.removeValue(forKey: "viewBox")
        root.attributes.removeValue(forKey: "preserveAspectRatio")
        root.attributes["xmlns"] = "http://www.w3.org/2000/svg"
        root.attributes["width"] = number(width)
        root.attributes["height"] = number(max(1, declaredHeight))
        let modeClass = appearance.isNight ? "yd-night" : "yd-day"
        root.attributes["class"] = [root.attributes["class"], "yd-card", modeClass]
            .compactMap { $0 }
            .joined(separator: " ")
        let readerStyle = "font-size:\(number(appearance.pointSize))px;"
            + "font-family:\(appearance.fontFamilyCSS);"
            + "color:\(appearance.textColorHex);"
        root.attributes["style"] = readerStyle + (root.attributes["style"] ?? "")
        if !appearance.fontFaceCSS.isEmpty {
            let fontStyle = Element(name: "style", attributes: [:], children: [.text(appearance.fontFaceCSS)])
            root.children.insert(.element(fontStyle), at: 0)
        }
    }

    private static func points(_ raw: String) -> CGFloat? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for unit in ["px", "pt"] where trimmed.hasSuffix(unit) {
            trimmed = String(trimmed.dropLast(unit.count))
        }
        return Double(trimmed).map { CGFloat($0) }
    }

    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }

    // MARK: - Writing

    /// HTML elements that have no end tag. Every other element inside a `<foreignObject>` must
    /// be written with one: the page is parsed as HTML there, where `<div/>` opens a `<div>`.
    private static let voidHTMLElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]

    private static func serialize(_ node: Node, into output: inout String, inHTML: Bool, parentName: String) {
        switch node {
        case .text(let text):
            if inHTML && parentName.lowercased() == "style" {
                // HTML reads a <style> as raw text: entities would stay entities.
                output += text.replacingOccurrences(of: "</", with: "<\\/")
            } else {
                output += escaped(text, quote: false)
            }
        case .element(let element):
            output += "<\(element.name)"
            for name in element.attributes.keys.sorted() {
                output += " \(name)=\"\(escaped(element.attributes[name] ?? "", quote: true))\""
            }
            let childrenAreHTML = inHTML || element.name.lowercased() == "foreignobject"
            guard !element.children.isEmpty else {
                if inHTML && !voidHTMLElements.contains(element.name.lowercased()) {
                    output += "></\(element.name)>"
                } else {
                    output += "/>"
                }
                return
            }
            output += ">"
            for child in element.children {
                serialize(child, into: &output, inHTML: childrenAreHTML, parentName: element.name)
            }
            output += "</\(element.name)>"
        }
    }

    private static func escaped(_ text: String, quote: Bool) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote { result = result.replacingOccurrences(of: "\"", with: "&quot;") }
        return result
    }

    // MARK: - Reading

    /// HTML's named entities a template author reaches for, which XML does not know.
    private static let htmlEntities: [String: String] = [
        "nbsp": "160", "middot": "183", "hellip": "8230", "mdash": "8212", "ndash": "8211",
        "lsaquo": "8249", "rsaquo": "8250", "laquo": "171", "raquo": "187", "hearts": "9829",
        "rarr": "8594", "larr": "8592", "times": "215", "bull": "8226", "copy": "169",
        "ldquo": "8220", "rdquo": "8221", "lsquo": "8216", "rsquo": "8217", "emsp": "8195", "ensp": "8194",
    ]

    private static func numericEntities(in source: String) -> String {
        guard source.contains("&") else { return source }
        var result = source
        for (name, code) in htmlEntities {
            result = result.replacingOccurrences(of: "&\(name);", with: "&#\(code);")
        }
        return result
    }

    /// Builds the element tree, leaving out what a template must not carry into a WebView.
    private final class TreeBuilder: NSObject, XMLParserDelegate {
        private let source: String
        private var stack: [Element] = []
        private var root: Element?
        /// Depth inside a dropped element; its whole subtree is skipped.
        private var droppedDepth = 0

        private static let droppedElements: Set<String> = [
            "script", "iframe", "object", "embed", "link", "meta", "base", "audio", "video",
            "frame", "frameset", "form", "input", "button", "textarea", "select", "animate",
            "set", "animatemotion", "animatetransform", "handler", "listener",
        ]

        init(source: String) {
            self.source = source
        }

        func parse() throws -> Element {
            let parser = XMLParser(data: Data(source.utf8))
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            guard parser.parse(), let root else {
                let reason = parser.parserError.map { ($0 as NSError).localizedDescription } ?? ""
                if parser.parserError == nil, root == nil { throw Failure.notSVG }
                throw Failure.unreadable(line: parser.lineNumber, column: parser.columnNumber, reason: reason)
            }
            return root
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            if droppedDepth > 0 || Self.droppedElements.contains(elementName.lowercased()) {
                droppedDepth += 1
                return
            }
            stack.append(Element(name: elementName, attributes: Self.safeAttributes(attributes), children: []))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if droppedDepth > 0 {
                droppedDepth -= 1
                return
            }
            guard var element = stack.popLast() else { return }
            if element.name.lowercased() == "style" {
                element.children = element.children.map { child in
                    guard case .text(let css) = child else { return child }
                    return .text(Self.safeCSS(css))
                }
            }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(.element(element))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func appendText(_ text: String) {
            guard droppedDepth == 0, !stack.isEmpty else { return }
            if case .text(let previous)? = stack[stack.count - 1].children.last {
                stack[stack.count - 1].children[stack[stack.count - 1].children.count - 1] = .text(previous + text)
            } else {
                stack[stack.count - 1].children.append(.text(text))
            }
        }

        private static func safeAttributes(_ attributes: [String: String]) -> [String: String] {
            var safe: [String: String] = [:]
            for (name, value) in attributes {
                let lower = name.lowercased()
                if lower.hasPrefix("on") { continue }
                if lower == "href" || lower.hasSuffix(":href") || lower == "src" {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard trimmed.hasPrefix("#") || trimmed.hasPrefix("data:image/") else { continue }
                }
                safe[name] = lower == "style" ? safeCSS(value) : value
            }
            return safe
        }

        /// CSS without `@import` and without any `url()` that is not an embedded image.
        static func safeCSS(_ css: String) -> String {
            var result = css.replacingOccurrences(
                of: #"@import[^;]*;?"#, with: "", options: [.regularExpression, .caseInsensitive]
            )
            result = result.replacingOccurrences(
                of: #"url\(\s*(?!['"]?(?:data:image/|#))[^)]*\)"#,
                with: "none",
                options: [.regularExpression, .caseInsensitive]
            )
            return result
        }
    }
}
