import Foundation

/// Writes one planned chapter as an XHTML document that BrowserAuto and the
/// legacy builder read as the same text (docs/aozora/epub-text-contract.md):
/// every block ends with `<br class="eol"/>`, which the stylesheet makes a block,
/// a line break inside a block is `<br/>`, headings are h3–h5, and U+3000 is
/// written as a character reference. Class names follow aozora2html
/// (`lib/aozora2html.rb` and `yml/command_table.yml` at 9ca5395), so the
/// stylesheet reads like 青空文庫's own.
enum AozoraXHTMLWriter {
    /// The rules every book gets: block breaks, no margins on paragraphs and
    /// headings, and notes a size smaller, as 青空文庫's aozora.css sets them
    /// (fetched 2026-11-04). No colour, so reader themes still apply.
    static let baseStylesheet = """
        br.eol { display: block; }
        p { margin: 0; }
        h3, h4, h5 { margin: 0; }
        .notes { font-size: smaller; }

        """

    /// The stylesheet for a book whose chapters are `chapters`: the base rules,
    /// then a rule for each class the chapters use, in a fixed order, so the same
    /// book always gives the same bytes. Values follow aozora.css and the inline
    /// styles aozora2html writes, with its physical properties made logical: the
    /// reader's 排版方向, not the book, sets the writing mode. aozora2html's
    /// font-size keywords are written in `rem` with WebKit's proportions (`small`
    /// is 13/16 of `medium`): like a keyword, relative to the reader's size, not
    /// the parent's, and read by both engines.
    static func stylesheet(forChapters chapters: [String]) -> String {
        let lists = chapters.flatMap(classLists(in:))
        let used = Set(lists.joined())
        func numbers(_ prefix: String) -> [Int] {
            used.compactMap { number($0, prefix) }.sorted()
        }
        var css = baseStylesheet
        for (name, rule) in headingRules where used.contains(name) { css += rule }
        for n in numbers("jisage_") { css += ".jisage_\(n) { margin-inline-start: \(n)em; }\n" }
        // 折り返して: the first line's own 字下げ, as an indent from the block's. A
        // pair without 字下げ comes first, so source order agrees with specificity.
        let hanging = Set(lists.compactMap { list -> [Int]? in
            guard let first = list.lazy.compactMap({ number($0, "first_") }).first else { return nil }
            return [list.lazy.compactMap { number($0, "jisage_") }.first ?? 0, first]
        })
        for pair in hanging.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let selector = (pair[0] > 0 ? ".jisage_\(pair[0])" : "") + ".first_\(pair[1])"
            css += "\(selector) { text-indent: \(pair[1] - pair[0])em; }\n"
        }
        for n in numbers("chitsuki_") { css += ".chitsuki_\(n) { text-align: end; margin-inline-end: \(n)em; }\n" }
        for n in numbers("jizume_") { css += ".jizume_\(n) { max-inline-size: \(n)em; }\n" }
        for n in numbers("dai") { css += ".dai\(n) { font-size: \(keywordSize(steps: n))rem; }\n" }
        for n in numbers("sho") { css += ".sho\(n) { font-size: \(keywordSize(steps: -n))rem; }\n" }
        for (name, rule) in namedRules where used.contains(name) { css += rule }
        return css
    }

    /// aozora.css sizes h3 at 125%, h4 `large` and h5 `medium`. aozora2html gives
    /// 同行 and 窓 headings the same classes on a `span`, so the size and the
    /// weight go on the class, where both forms take them.
    private static let headingRules: [(String, String)] = {
        let sizes: [(String, String)] = [("o", "1.25em"), ("naka", "1.125rem"), ("ko", "1rem")]
        return sizes.flatMap { size, value -> [(String, String)] in
            ["", "dogyo-", "mado-"].map { form -> (String, String) in
                let name = "\(form)\(size)-midashi"
                return (name, ".\(name) { font-size: \(value); font-weight: bold; }\n")
            }
        }
    }()

    /// The classes with a fixed rule, in the order they are written.
    private static let namedRules: [(String, String)] = [
        ("futoji", ".futoji { font-weight: bold; }\n"),
        ("shatai", ".shatai { font-style: italic; }\n"),
        ("gothic", ".gothic { font-family: sans-serif; }\n"),
        ("keigakomi", "div.keigakomi { border: 1px solid; padding-block-start: 0.5em; padding-block-end: 0.5em; "
            + "padding-inline-start: 1em; padding-inline-end: 0.5em; }\nspan.keigakomi { border: 1px solid; }\n"),
        ("caption", ".caption { font-size: 0.8125rem; font-weight: bold; }\n"),
        ("superscript", ".superscript { font-size: 0.8125rem; }\n"),
        ("subscript", ".subscript { font-size: 0.8125rem; }\n"),
        // 返り点 and 訓点送り仮名, half size beside the character before: lowered and raised, left
        // and right of a vertical line. Kanbun sets them under the character; CSS has no such place.
        ("kaeriten", ".kaeriten { font-size: 0.5em; vertical-align: sub; }\n"),
        ("okurigana", ".okurigana { font-size: 0.5em; vertical-align: super; }\n"),
        // 割り注, in one line at half size between the （） the parser keeps; CSS has no two-line form.
        ("warichu", ".warichu { font-size: 0.5em; }\n"),
        ("tcy", ".tcy { text-combine-upright: all; }\n"),
        // 左ルビ: under the text, and on the left of a vertical line.
        ("left", "ruby.left { -webkit-ruby-position: after; ruby-position: under; }\n"),
        ("over", "ruby.over { -webkit-ruby-position: before; ruby-position: over; }\n"),
    ] + emphasisRules

    /// 傍点 and 傍線, which are `em`, italic by default: aozora.css sets them upright.
    /// - 傍点 is `text-emphasis`, over the text and on the right of a vertical line;
    ///   左に傍点 (`_after`) under it and on the left.
    /// - 傍線 is an underline on the right of a vertical line, 左に傍線 (`overline_`)
    ///   one on the left. Horizontally both are under the text, where aozora2html
    ///   draws 左に傍線 over it: one stylesheet serves both writing modes, and keeps
    ///   the vertical sides right (Aozora plan, Task 8).
    ///
    /// Each property is also written with WebKit's prefix, which other EPUB readers
    /// built on WebKit may need.
    private static let emphasisRules: [(String, String)] = {
        func rule(_ name: String, _ declarations: [(String, String)], prefixed: Set<String>) -> (String, String) {
            let body = declarations.flatMap { property, value in
                (prefixed.contains(property) ? ["-webkit-\(property): \(value);"] : []) + ["\(property): \(value);"]
            }
            return (name, ".\(name) { font-style: normal; \(body.joined(separator: " ")) }\n")
        }
        let emphasis: Set<String> = ["text-emphasis-style", "text-emphasis-position"]
        let marks = AozoraEmphasisStyle.allCases.flatMap { style in
            [("", "over right"), ("_after", "under left")].map { suffix, position in
                rule(style.className + suffix, [("text-emphasis-style", style.emphasisStyle),
                                                ("text-emphasis-position", position)], prefixed: emphasis)
            }
        }
        let lines = AozoraSidelineStyle.allCases.flatMap { style in
            [("underline_", "right"), ("overline_", "left")].map { prefix, side in
                rule(prefix + style.classSuffix, [("text-decoration-line", "underline"),
                                                  ("text-decoration-style", style.decorationStyle),
                                                  ("text-underline-position", side)], prefixed: [])
            }
        }
        return marks + lines
    }()

    /// aozora2html's size for `steps` 段階: `large`, `x-large`, and `xx-large` for
    /// three or more, and `small` to `xx-small` down, in WebKit's proportions to
    /// `medium` (18, 24, 32 and 13, 10, 9 of 16).
    private static func keywordSize(steps: Int) -> String {
        switch steps {
        case 1: "1.125"
        case 2: "1.5"
        case 3...: "2"
        case -1: "0.8125"
        case -2: "0.625"
        default: "0.5625"
        }
    }

    /// The class lists of the elements in `xhtml`, as the writer writes them.
    private static func classLists(in xhtml: String) -> [[String]] {
        xhtml.components(separatedBy: "class=\"").dropFirst().map {
            $0.prefix { $0 != "\"" }.split(separator: " ").map(String.init)
        }
    }

    /// The number after `prefix` in a class name such as `jisage_2`.
    private static func number(_ name: String, _ prefix: String) -> Int? {
        name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil
    }

    /// The stylesheet's path from a chapter file (`OPS/text/…`).
    static let stylesheetHref = "../style/aozora.css"

    /// `images` maps a figure's source name to its path from the chapter file.
    static func document(for chapter: AozoraChapter, in document: AozoraDocument, images: [String: String]) -> String {
        let positions = Dictionary(uniqueKeysWithValues: document.blockSpans.enumerated().map { ($1, $0) })
        var body = ""
        var boxed = false
        for span in chapter.spans {
            let blockIndex = positions[span] ?? 0
            let block = block(span, in: document)
            // A run of 罫囲み blocks is one box, as aozora2html draws it.
            if block.isBoxed != boxed {
                body += block.isBoxed ? "<div class=\"keigakomi\">" : "</div>"
                boxed = block.isBoxed
            }
            body += write(block, blockIndex: blockIndex, images: images)
        }
        if boxed { body += "</div>" }
        let title = chapter.navigation.first?.title ?? document.header?.title ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">
            <head>
            <title>\(escaped(title))</title>
            <link rel="stylesheet" type="text/css" href="\(stylesheetHref)"/>
            </head>
            <body>\(body)</body>
            </html>

            """
    }

    static func block(_ span: AozoraBlockSpan, in document: AozoraDocument) -> AozoraBlock {
        switch span.section {
        case .header: return document.headerBlocks[span.index]
        case .body: return document.body[span.index]
        case .colophon: return document.colophon[span.index]
        }
    }

    // MARK: Blocks

    static func write(_ block: AozoraBlock, blockIndex: Int, images: [String: String]) -> String {
        var ordinal = 0
        switch block {
        case .paragraph(let inlines, let style):
            return "<p\(classAttribute(classes(style)))>"
                + write(inlines, blockIndex: blockIndex, ordinal: &ordinal, images: images)
                + "<br class=\"eol\"/></p>"
        case .heading(let level, let kind, let inlines, let style):
            let tag = level.tag
            let id = AozoraChapterPlanner.anchor(blockIndex: blockIndex)
            return "<\(tag)\(classAttribute([headingClass(level, kind)] + classes(style))) id=\"\(id)\">"
                + write(inlines, blockIndex: blockIndex, ordinal: &ordinal, images: images)
                + "<br class=\"eol\"/></\(tag)>"
        case .image(let source, let width, let height, let caption):
            return "<p class=\"figure\">"
                + figure(source: source, width: width, height: height, caption: caption,
                         blockIndex: blockIndex, ordinal: &ordinal, images: images)
                + "<br class=\"eol\"/></p>"
        case .pageBreak:
            return ""
        }
    }

    private static func classes(_ style: AozoraParagraphStyle) -> [String] {
        var result: [String] = []
        if style.indent > 0 { result.append("jisage_\(style.indent)") }
        if style.firstLineIndent != style.indent { result.append("first_\(style.firstLineIndent)") }
        if let end = style.endAlignment { result.append("chitsuki_\(end)") }
        if let limit = style.characterLimit { result.append("jizume_\(limit)") }
        if let size = sizeClass(style.sizeSteps) { result.append(size) }
        if style.isBoxed { result.append("keigakomi") }
        if style.isHorizontal { result.append("yokogumi") }
        if style.isCaption { result.append("caption") }
        return result
    }

    private static func classAttribute(_ classes: [String]) -> String {
        classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
    }

    private static func sizeClass(_ steps: Int) -> String? {
        steps > 0 ? "dai\(steps)" : steps < 0 ? "sho\(-steps)" : nil
    }

    private static func headingClass(_ level: AozoraHeadingLevel, _ kind: AozoraHeadingKind) -> String {
        let size = switch level {
        case .large: "o"
        case .medium: "naka"
        case .small: "ko"
        }
        return switch kind {
        case .normal: "\(size)-midashi"
        case .sameLine: "dogyo-\(size)-midashi"
        case .window: "mado-\(size)-midashi"
        }
    }

    // MARK: Inlines

    /// `rubySide` is the side a ruby takes unless it names its own: `ruby-position` is
    /// inherited, so inside a left ruby it is the left.
    private static func write(_ inlines: [AozoraInline], blockIndex: Int, ordinal: inout Int,
                              images: [String: String], rubySide: AozoraSide = .right) -> String {
        var out = ""
        for inline in inlines {
            out += write(inline, blockIndex: blockIndex, ordinal: &ordinal, images: images, rubySide: rubySide)
        }
        return out
    }

    private static func write(_ inline: AozoraInline, blockIndex: Int, ordinal: inout Int,
                              images: [String: String], rubySide: AozoraSide) -> String {
        func wrap(_ open: String, _ close: String, _ children: [AozoraInline], rubySide inner: AozoraSide? = nil) -> String {
            open + write(children, blockIndex: blockIndex, ordinal: &ordinal, images: images,
                         rubySide: inner ?? rubySide) + close
        }
        switch inline {
        case .text(let text):
            return escaped(text)
        case .ruby(let base, let reading, let side):
            // A ruby over nothing, such as a figure whose file is missing, is left out:
            // it annotates nothing, and BrowserAuto lays out no ruby without a base.
            guard shows(base, images: images) else { return wrap("", "", base) }
            // A word with readings on both sides is a ruby inside a ruby. Inside a left
            // one a right ruby names its side, or it would inherit the left.
            let open = side == .left ? "<ruby class=\"left\">" : rubySide == .left ? "<ruby class=\"over\">" : "<ruby>"
            return wrap(open, "<rt>\(escaped(reading))</rt></ruby>", base, rubySide: side)
        case .emphasis(let style, let side, let children):
            let name = style.className + (side == .left ? "_after" : "")
            return wrap("<em class=\"\(name)\">", "</em>", children)
        case .sideline(let style, let side, let children):
            let name = (side == .left ? "overline_" : "underline_") + style.classSuffix
            return wrap("<em class=\"\(name)\">", "</em>", children)
        case .bold(let children):
            return wrap("<span class=\"futoji\">", "</span>", children)
        case .italic(let children):
            return wrap("<span class=\"shatai\">", "</span>", children)
        case .gothic(let children):
            return wrap("<span class=\"gothic\">", "</span>", children)
        case .size(let steps, let children):
            guard let name = sizeClass(steps) else { return wrap("", "", children) }
            return wrap("<span class=\"\(name)\">", "</span>", children)
        case .tateChuYoko(let children):
            return wrap("<span class=\"tcy\">", "</span>", children)
        case .gaiji(let gaiji):
            if let resolved = gaiji.resolved { return escaped(resolved) }
            guard !gaiji.description.isEmpty else { return "※" }
            return "※<span class=\"notes\">（\(escaped(gaiji.description))）</span>"
        case .script(let kind, let children):
            switch kind {
            case .upper, .lineRight: return wrap("<sup class=\"superscript\">", "</sup>", children)
            case .lower, .lineLeft: return wrap("<sub class=\"subscript\">", "</sub>", children)
            }
        case .kaeriten(let text):
            return "<sub class=\"kaeriten\">\(escaped(text))</sub>"
        case .kuntenOkurigana(let text):
            return "<sup class=\"okurigana\">\(escaped(text))</sup>"
        case .warichu(let children):
            return wrap("<span class=\"warichu\">", "</span>", children)
        case .heading(let level, let kind, let children):
            ordinal += 1
            let id = AozoraChapterPlanner.anchor(blockIndex: blockIndex, ordinal: ordinal)
            return wrap("<span class=\"\(headingClass(level, kind))\" id=\"\(id)\">", "</span>", children)
        case .boxed(let children):
            return wrap("<span class=\"keigakomi\">", "</span>", children)
        case .horizontal(let children):
            return wrap("<span class=\"yokogumi\">", "</span>", children)
        case .caption(let children):
            return wrap("<span class=\"caption\">", "</span>", children)
        case .image(let source, let width, let height, let caption):
            return figure(source: source, width: width, height: height, caption: caption,
                          blockIndex: blockIndex, ordinal: &ordinal, images: images)
        case .lineBreak:
            return "<br/>"
        case .editorialNote, .unknownAnnotation:
            return ""
        }
    }

    /// Whether inlines show anything: text other than white space, as BrowserAuto
    /// judges a ruby base, or a figure the package holds.
    private static func shows(_ inlines: [AozoraInline], images: [String: String]) -> Bool {
        !inlines.displayedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || holdsFigure(inlines, images)
    }

    private static func holdsFigure(_ inlines: [AozoraInline], _ images: [String: String]) -> Bool {
        inlines.contains { inline in
            if case .image(let source, _, _, _) = inline, images[source] != nil { return true }
            return holdsFigure(inline.children, images)
        }
    }

    /// The figure, with its caption in `alt` and after it, as text. A figure whose
    /// file is missing leaves its caption only. The syntax tree does not record
    /// 写真, so every figure is an `illustration`.
    private static func figure(source: String, width: Int?, height: Int?, caption: [AozoraInline],
                               blockIndex: Int, ordinal: inout Int, images: [String: String]) -> String {
        let captionText = caption.isEmpty ? ""
            : "<span class=\"caption\">" + write(caption, blockIndex: blockIndex, ordinal: &ordinal, images: images) + "</span>"
        guard let path = images[source] else { return captionText }
        var attributes = "class=\"illustration\" src=\"\(escaped(path))\" alt=\"\(escaped(caption.displayedText))\""
        if let width { attributes += " width=\"\(width)\"" }
        if let height { attributes += " height=\"\(height)\"" }
        return "<img \(attributes)/>" + captionText
    }

    /// `&`, `<`, `>` and `"` escaped; U+3000 as a character reference, so the text
    /// does not depend on how either engine treats spaces between Han characters.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{3000}": out += "&#12288;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private extension AozoraBlock {
    var isBoxed: Bool {
        switch self {
        case .paragraph(_, let style), .heading(_, _, _, let style): style.isBoxed
        case .image, .pageBreak: false
        }
    }
}

private extension AozoraHeadingLevel {
    var tag: String {
        switch self {
        case .large: return "h3"
        case .medium: return "h4"
        case .small: return "h5"
        }
    }
}

private extension AozoraEmphasisStyle {
    /// aozora2html `command_table.yml`.
    var className: String {
        switch self {
        case .sesameDot: return "sesame_dot"
        case .whiteSesameDot: return "white_sesame_dot"
        case .blackCircle: return "black_circle"
        case .whiteCircle: return "white_circle"
        case .blackTriangle: return "black_up-pointing_triangle"
        case .whiteTriangle: return "white_up-pointing_triangle"
        case .bullseye: return "bullseye"
        case .fisheye: return "fisheye"
        case .saltire: return "saltire"
        }
    }

    /// The `text-emphasis-style` that draws it.
    var emphasisStyle: String {
        switch self {
        case .sesameDot: return "filled sesame"
        case .whiteSesameDot: return "open sesame"
        case .blackCircle: return "filled circle"
        case .whiteCircle: return "open circle"
        case .blackTriangle: return "filled triangle"
        case .whiteTriangle: return "open triangle"
        case .bullseye: return "filled double-circle"
        case .fisheye: return "open double-circle"
        case .saltire: return "\"×\""
        }
    }
}

private extension AozoraSidelineStyle {
    var classSuffix: String {
        switch self {
        case .solid: return "solid"
        case .double: return "double"
        case .chain: return "dotted"
        case .dashed: return "dashed"
        case .wave: return "wave"
        }
    }

    /// The `text-decoration-style` that draws it: 鎖線 as dots.
    var decorationStyle: String {
        switch self {
        case .solid: return "solid"
        case .double: return "double"
        case .chain: return "dotted"
        case .dashed: return "dashed"
        case .wave: return "wavy"
        }
    }
}
