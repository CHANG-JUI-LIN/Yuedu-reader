import Foundation

/// Writes one planned chapter as an XHTML document that BrowserAuto and the
/// legacy builder read as the same text (docs/aozora/epub-text-contract.md):
/// every block ends with `<br class="eol"/>`, which the stylesheet makes a block,
/// a line break inside a block is `<br/>`, headings are h3–h5, and U+3000 is
/// written as a character reference. Class names follow aozora2html
/// (`lib/aozora2html.rb` and `yml/command_table.yml` at 9ca5395), so the
/// stylesheet reads like 青空文庫's own; Phase 1b styles only a few of them.
enum AozoraXHTMLWriter {
    /// Size only, no colour, so reader themes still apply.
    static let stylesheet = """
        br.eol { display: block; }
        p { margin: 0; }
        .notes { font-size: 0.8em; }

        """

    /// The stylesheet's path from a chapter file (`OPS/text/…`).
    static let stylesheetHref = "../style/aozora.css"

    /// `images` maps a figure's source name to its path from the chapter file.
    static func document(for chapter: AozoraChapter, in document: AozoraDocument, images: [String: String]) -> String {
        let positions = Dictionary(uniqueKeysWithValues: document.blockSpans.enumerated().map { ($1, $0) })
        var body = ""
        for span in chapter.spans {
            let blockIndex = positions[span] ?? 0
            body += write(block(span, in: document), blockIndex: blockIndex, images: images)
        }
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

    private static func write(_ inlines: [AozoraInline], blockIndex: Int, ordinal: inout Int,
                              images: [String: String]) -> String {
        var out = ""
        for inline in inlines {
            out += write(inline, blockIndex: blockIndex, ordinal: &ordinal, images: images)
        }
        return out
    }

    private static func write(_ inline: AozoraInline, blockIndex: Int, ordinal: inout Int,
                              images: [String: String]) -> String {
        func wrap(_ open: String, _ close: String, _ children: [AozoraInline]) -> String {
            open + write(children, blockIndex: blockIndex, ordinal: &ordinal, images: images) + close
        }
        switch inline {
        case .text(let text):
            return escaped(text)
        case .ruby(let base, let reading, let side):
            // A ruby over nothing, such as a figure whose file is missing, is left out:
            // it annotates nothing, and BrowserAuto lays out no ruby without a base.
            guard shows(base, images: images) else { return wrap("", "", base) }
            return wrap(side == .left ? "<ruby class=\"left\">" : "<ruby>", "<rt>\(escaped(reading))</rt></ruby>", base)
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
}
