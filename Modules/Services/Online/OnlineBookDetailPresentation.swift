import Foundation

/// Bounds source-controlled metadata before a SwiftUI detail hierarchy sees it.
///
/// Imported rules can return an entire HTML document as a book introduction.
/// Limit both the raw normalization input and the final display value so iOS 17
/// never has to measure an unbounded `Text` inside the detail `ScrollView`.
enum OnlineBookDetailPresentationPolicy {
    static let maximumRawIntroCharacters = 32_000
    static let maximumIntroCharacters = 4_000

    @inline(never)
    static func sanitizeIntro(_ rawIntro: String, indentParagraphs: Bool = true) -> String {
        let rawPrefix = rawIntro.prefix(maximumRawIntroCharacters + 1)
        let rawWasTruncated = rawPrefix.count > maximumRawIntroCharacters
        let boundedRaw = String(rawPrefix.prefix(maximumRawIntroCharacters))
        // Legado's prefix modes keep their markup for the detail page to render;
        // the raw bound above still applies to them.
        if BookIntroContent.usesPrefixMode(boundedRaw) {
            return boundedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let formatted = LegadoHTMLFormatter.format(boundedRaw)
        // Rule-based novels use Legado's paragraph indentation. OPDS metadata is
        // ordinary catalog text; it shares sanitization/bounds without that style.
        let cleaned = indentParagraphs
            ? LegadoHTMLFormatter.indentingEveryParagraph(formatted)
            : formatted.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        guard !cleaned.isEmpty else { return "" }

        let displayPrefix = cleaned.prefix(maximumIntroCharacters + 1)
        let displayWasTruncated = displayPrefix.count > maximumIntroCharacters
        let boundedDisplay = String(displayPrefix.prefix(maximumIntroCharacters))
        if rawWasTruncated || displayWasTruncated {
            return boundedDisplay + "…"
        }
        return boundedDisplay
    }

    static func sanitized(_ book: OnlineBook) -> OnlineBook {
        var result = book
        let normalizedName = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.caseInsensitiveCompare("undefined") == .orderedSame
            || normalizedName.caseInsensitiveCompare("null") == .orderedSame
        {
            // Missing JSON fields can cross a source-JS rule boundary as these
            // literal sentinel strings. Treat them as absent so the detail view
            // keeps the valid search-result title instead of displaying the sentinel.
            result.name = ""
        }
        result.intro = sanitizeIntro(book.intro)
        return result
    }
}
