import Foundation
import YueduCoreText

/// 套用書本間距 off, for the EPUB engine that cascades CSS: a last author stylesheet whose
/// `!important` declarations put the reader's 行距, 段距 and 段首縮排 over the book's own.
///
/// The legacy engine does the same on its node tree (`NodeAttributedStringRenderer
/// .withoutBookSpacing`); the two carry one rule:
/// - every element takes the reader's line height;
/// - a `<p>` loses its vertical margins, so only the reader's 段距 separates paragraphs;
/// - a `<p>` takes the reader's 段首縮排.
///
/// Until 2026-11-21 the switch reached only the legacy engine, so on the engine every
/// EPUB opens with it moved nothing.
enum ReaderBookSpacingStyleSheet {
    /// Nil while the book's own spacing is honoured.
    static func css(for settings: ReaderRenderSettings) -> String? {
        guard !settings.usesBookSpacing else { return nil }
        let lineHeight = number(max(1, settings.lineHeightMultiple))
        let indent = number(settings.firstLineIndentEm)
        return """
        * { line-height: \(lineHeight) !important; }
        p { margin-top: 0 !important; margin-bottom: 0 !important; text-indent: \(indent)em !important; }
        """
    }

    /// `input` with the reader's sheet after every sheet of the book's.
    static func applying(to input: CSSFrontendInput, settings: ReaderRenderSettings) -> CSSFrontendInput {
        guard let css = css(for: settings) else { return input }
        let lastOrder = input.stylesheets.map(\.sourceOrder).max() ?? -1
        let lastCompatibilityOrder = input.stylesheets.compactMap(\.currentCompatibilityOrder).max() ?? -1
        let sheet = AuthorStylesheet(
            source: .inline(nodeOrdinal: Int.max),
            text: css,
            sourceOrder: lastOrder + 1,
            currentCompatibilityOrder: lastCompatibilityOrder + 1,
            currentCompatibilityOnly: false,
            media: nil,
            isAlternate: false
        )
        return CSSFrontendInput(html: input.html, stylesheets: input.stylesheets + [sheet],
                                diagnostics: input.diagnostics)
    }

    /// Locale-independent, so a decimal comma never reaches the CSS.
    private static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
