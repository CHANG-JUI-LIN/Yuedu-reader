import Foundation
import UIKit

struct MarkdownAttributedStringBuilder: AttributedStringBuilding {
    private let sections: [MarkdownSection]

    init(markdown: String, fallbackTitle: String) {
        self.sections = MarkdownSectionParser.sections(from: markdown, fallbackTitle: fallbackTitle)
    }

    var chapterCount: Int { sections.count }

    var unifiedChapters: [UnifiedChapter] {
        sections.enumerated().map { index, section in
            let bodyNodes = MarkdownRenderableNodeConverter.convertBody(section.body)
            let paragraphs = MarkdownRenderableNodeConverter.plainParagraphs(from: bodyNodes)
            return UnifiedChapter(
                index: index,
                title: section.title,
                paragraphs: paragraphs,
                sourceHref: String(index)
            )
        }
    }

    func chapterTitle(at index: Int) -> String {
        guard sections.indices.contains(index) else { return "" }
        return sections[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard sections.indices.contains(index) else { return nil }
        return String(index)
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard sections.indices.contains(index) else { return 0 }
        let section = sections[index]
        return section.body.lengthOfBytes(using: .utf8)
    }

    func chapterIndex(for href: String) -> Int? {
        guard let index = Int(href), sections.indices.contains(index) else { return nil }
        return index
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        _ = themeBackgroundColor
        guard sections.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let nodes = MarkdownRenderableNodeConverter.convert(section: sections[index])
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(from: settings, textColor: themeTextColor)
        )

        return AttributedChapterBuildResult(
            attributedString: await renderer.render(nodes),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

enum MarkdownRenderableNodeConverter {
    static func convert(section: MarkdownSection) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        if !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let headingStyle = RenderStyle(
                bold: true,
                textAlign: .center,
                paragraphSpacingAfter: 24
            )
            nodes.append(
                .heading(
                    [.text(section.title)],
                    level: max(1, min(section.headingLevel ?? 1, 6)),
                    style: headingStyle
                )
            )
        }

        nodes.append(contentsOf: convertBody(section.body))
        return nodes
    }

    static func convertBody(_ body: String) -> [RenderableNode] {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var nodes: [RenderableNode] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        func flushParagraph() {
            let text = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                nodes.append(.paragraph(MarkdownInlineParser.parse(text), style: .body))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            let text = quoteLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                nodes.append(.blockquote([.paragraph(MarkdownInlineParser.parse(text), style: .body)]))
            }
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let text = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                nodes.append(
                    .block(
                        tag: "pre",
                        children: [.text(text)],
                        style: RenderStyle(marginLeft: 12)
                    )
                )
            }
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                if isInsideCodeFence {
                    flushCode()
                    isInsideCodeFence = false
                } else {
                    isInsideCodeFence = true
                }
                continue
            }

            if isInsideCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if let quoteText = blockquoteContent(from: trimmed) {
                flushParagraph()
                quoteLines.append(quoteText)
                continue
            }

            if let heading = headingContent(from: trimmed) {
                flushParagraph()
                flushQuote()
                nodes.append(.heading(MarkdownInlineParser.parse(heading.text), level: heading.level, style: .none))
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                flushQuote()
                nodes.append(.horizontalRule())
                continue
            }

            flushQuote()

            if let listText = unorderedListContent(from: trimmed) {
                flushParagraph()
                nodes.append(.listItem(MarkdownInlineParser.parse(listText), bullet: "•"))
                continue
            }

            if let ordered = orderedListContent(from: trimmed) {
                flushParagraph()
                nodes.append(.listItem(MarkdownInlineParser.parse(ordered.text), bullet: ordered.marker))
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        flushQuote()
        if isInsideCodeFence {
            flushCode()
        }

        return nodes
    }

    static func plainParagraphs(from nodes: [RenderableNode]) -> [String] {
        nodes.compactMap { node in
            let text = topLevelText(for: node).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func topLevelText(for node: RenderableNode) -> String {
        switch node {
        case .paragraph(let children, _):
            return flatten(children)
        case .heading(let children, _, _):
            return flatten(children)
        case .blockquote(let children):
            return flatten(children)
        case .listItem(let children, let bullet):
            let body = flatten(children)
            return body.isEmpty ? "" : "\(bullet) \(body)"
        case .block(_, let children, _):
            return flatten(children)
        case .text(let text):
            return text
        case .lineBreak, .horizontalRule(_), .pageBreak:
            return ""
        case .inline(_, let children, _):
            return flatten(children)
        case .anchor(_, let children):
            return flatten(children)
        case .anchorTarget(_, let child):
            return topLevelText(for: child)
        case .image(_, let alt, _):
            return alt
        case .rawHTML(let html):
            return html
        }
    }

    private static func flatten(_ nodes: [RenderableNode]) -> String {
        nodes.map(topLevelText(for:)).joined()
    }

    private static func headingContent(from trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard level > 0, level <= 6 else { return nil }
        let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    private static func blockquoteContent(from trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func unorderedListContent(from trimmed: String) -> String? {
        guard let first = trimmed.first, ["-", "*", "+"].contains(first) else { return nil }
        let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func orderedListContent(from trimmed: String) -> (marker: String, text: String)? {
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
            cursor = trimmed.index(after: cursor)
        }
        guard cursor > trimmed.startIndex,
              cursor < trimmed.endIndex,
              trimmed[cursor] == "."
        else {
            return nil
        }

        let marker = String(trimmed[..<cursor]) + "."
        var textStart = trimmed.index(after: cursor)
        while textStart < trimmed.endIndex, trimmed[textStart].isWhitespace {
            textStart = trimmed.index(after: textStart)
        }
        guard textStart < trimmed.endIndex else { return nil }
        let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (marker, text)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }
}

private enum MarkdownInlineParser {
    static func parse(_ text: String) -> [RenderableNode] {
        guard !text.isEmpty else { return [] }

        var nodes: [RenderableNode] = []
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            nodes.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let remaining = text[index...]

            if remaining.hasPrefix("["),
               let closeBracket = remaining.firstIndex(of: "]") {
                let afterBracket = text.index(after: closeBracket)
                if afterBracket < text.endIndex,
                   text[afterBracket] == "(",
                   let closeParen = text[afterBracket...].firstIndex(of: ")") {
                    flushBuffer()
                    let labelStart = text.index(after: index)
                    let urlStart = text.index(after: afterBracket)
                    let label = String(text[labelStart..<closeBracket])
                    let href = String(text[urlStart..<closeParen])
                    nodes.append(.anchor(href: href, children: parse(label)))
                    index = text.index(after: closeParen)
                    continue
                }
            }

            if remaining.hasPrefix("**") {
                let contentStart = text.index(index, offsetBy: 2)
                if contentStart < text.endIndex,
                   let closingRange = text[contentStart...].range(of: "**") {
                    flushBuffer()
                    let inner = String(text[contentStart..<closingRange.lowerBound])
                    nodes.append(
                        .inline(
                            tag: "strong",
                            children: parse(inner),
                            style: RenderStyle(bold: true)
                        )
                    )
                    index = closingRange.upperBound
                    continue
                }
            }

            if remaining.hasPrefix("*") {
                let contentStart = text.index(after: index)
                if contentStart < text.endIndex,
                   let closingIndex = text[contentStart...].firstIndex(of: "*") {
                    flushBuffer()
                    let inner = String(text[contentStart..<closingIndex])
                    nodes.append(
                        .inline(
                            tag: "em",
                            children: parse(inner),
                            style: RenderStyle(italic: true)
                        )
                    )
                    index = text.index(after: closingIndex)
                    continue
                }
            }

            if remaining.hasPrefix("`") {
                let contentStart = text.index(after: index)
                if contentStart < text.endIndex,
                   let closingIndex = text[contentStart...].firstIndex(of: "`") {
                    flushBuffer()
                    let inner = String(text[contentStart..<closingIndex])
                    nodes.append(.text(inner))
                    index = text.index(after: closingIndex)
                    continue
                }
            }

            buffer.append(text[index])
            index = text.index(after: index)
        }

        flushBuffer()
        return nodes.isEmpty ? [.text(text)] : nodes
    }
}
