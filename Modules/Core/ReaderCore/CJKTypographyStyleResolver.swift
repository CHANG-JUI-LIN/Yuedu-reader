import Foundation
import YueduCoreTextTypography

/// Decides how a book's CJK text is set: where punctuation sits, how much of it
/// squeezes, which fonts draw Han and kana. Both engines and every legacy text path
/// ask here, so a book is set one way throughout.
///
/// The text's own script decides, not the language the book declares: converters
/// label Traditional text `zh-cn` (the reported 紅樓夢 does). See
/// docs/superpowers/plans/2026-10-06-vertical-typography.md, decision 2.
final class CJKTypographyStyleResolver: @unchecked Sendable {
    static let shared = CJKTypographyStyleResolver()

    private let lock = NSLock()
    /// Per book and 繁簡轉換: the style the first text that showed its script decided.
    private var decided: [String: CJKTypographyStyle] = [:]

    /// The style for `text`, which is what the reader will show, after 繁簡轉換.
    ///
    /// A book keeps the style its first decisive text gave it, so a title page or a
    /// chapter title that shows no script is set like the rest of the book. Text of a
    /// book not yet decided, or of no book, decides for itself; when it cannot, the
    /// declared language does, then the interface language.
    func style(
        for text: String,
        book: UUID?,
        conversion: TextConversion,
        declaredLanguage: String?
    ) -> CJKTypographyStyle {
        let key = book.map { "\($0.uuidString)|\(conversion.rawValue)" }
        if let key, let style = lock.withLock({ decided[key] }) {
            return style
        }
        if let style = CJKTypographyStyle.detect(in: text) {
            if let key {
                let isNew = lock.withLock { () -> Bool in
                    guard decided[key] == nil else { return false }
                    decided[key] = style
                    return true
                }
                if isNew {
                    AppLogger.render("[CJKTypography] book style decided by its text",
                        context: ["book": key, "style": style.rawValue])
                }
            }
            return style
        }
        return CJKTypographyStyle.declared(declaredLanguage) ?? Self.interfaceStyle
    }

    /// The style the interface language implies; Traditional unless the interface is
    /// Simplified Chinese, Japanese or Korean, as zh-Hant is the app's development language.
    static var interfaceStyle: CJKTypographyStyle {
        CJKTypographyStyle.declared(Bundle.main.preferredLocalizations.first) ?? .traditional
    }

    /// The readable text of the nodes the legacy engine renders, enough of it to tell
    /// its script. Ruby readings are left out, as `textSample(fromHTML:)` leaves them.
    static func textSample(from nodes: [RenderableNode]) -> String {
        var sample = ""
        var length = 0
        // A TXT chapter is one text node; take only what detection reads.
        func append(_ text: some StringProtocol) {
            let piece = text.prefix(max(0, CJKTypographyStyle.sampleLength - length))
            sample += piece
            length += piece.utf16.count
        }
        func collect(_ node: RenderableNode) {
            guard length < CJKTypographyStyle.sampleLength else { return }
            switch node {
            case .text(let text):
                append(text)
            case .paragraph(let children, _), .heading(let children, _, _), .blockquote(let children),
                 .listItem(let children, _), .block(_, let children, _), .unsupportedInteractive(_, _, let children, _):
                // A block ends a sentence for detection, as a line break does.
                children.forEach(collect)
                append("\n")
            case .inline(_, let children, _), .anchor(_, let children), .ruby(let children, _, _):
                children.forEach(collect)
            case .anchorTarget(_, let child):
                collect(child)
            case .rawHTML(let html):
                append(textSample(fromHTML: html))
            case .lineBreak:
                append("\n")
            case .horizontalRule, .image, .mathML, .table, .media, .commentBadge, .pageBreak:
                break
            }
        }
        nodes.forEach(collect)
        return String(sample.prefix(CJKTypographyStyle.sampleLength))
    }

    /// The readable text of a chapter's XHTML, enough of it to tell its script: the
    /// head, styles, scripts and ruby readings are dropped, then every tag.
    static func textSample(fromHTML html: String) -> String {
        // A chapter can run to megabytes; its first stretch holds plenty of sentences.
        var text = String(html.prefix(CJKTypographyStyle.sampleLength * 10))
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#,
                        #"(?is)<script\b.*?</script>"#, #"(?is)<rt\b.*?</rt>"#, #"(?is)<rp\b.*?</rp>"#,
                        #"<[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return String(text.prefix(CJKTypographyStyle.sampleLength))
    }
}
