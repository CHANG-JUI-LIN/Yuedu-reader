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
    /// Simplified Chinese or Japanese, as zh-Hant is the app's development language.
    static var interfaceStyle: CJKTypographyStyle {
        CJKTypographyStyle.declared(Bundle.main.preferredLocalizations.first) ?? .traditional
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
