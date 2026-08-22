import CoreGraphics
import Foundation

/// Sizing for the *text cards* a Legado book source ships as SVG instead of HTML — 起点-family
/// 神评论 / 本章说 / 作者说.
///
/// The card is prose, but its text is positioned in viewBox units, so whichever width we
/// rasterize it at *is* its text size. Rasterizing at the reading column therefore makes one
/// and the same card read at ~13pt in an iPhone column and ~38pt in an iPad landscape column:
/// the card stops matching the paragraphs it sits between, and rotating the iPad changes its
/// text size while the prose stays put. (企点's card is authored `viewBox="0 0 1000 456"` with
/// `font-size="38"`, i.e. 3.8% of its own width — calibrated for a ~360pt phone column.)
///
/// So: read the card's own dominant `font-size` and pick the width that lands it on the
/// reader's body point size. The card then reads the same on every device and follows the
/// 字級 setting, while its authored layout is rendered exactly as the source drew it.
///
/// Only cards are affected: an SVG has to be wide, text-carrying and picture-free to qualify,
/// so illustrations, 段評 count bubbles and icons keep the size they had.
enum ReviewCardSVGMetrics {

    /// The card's own text scale, read out of the SVG.
    struct TextCard: Equatable {
        /// Width of the card's coordinate system (its viewBox width, or its declared width).
        let coordinateWidth: CGFloat
        /// `font-size` of the run carrying most of the card's characters — its body text.
        let dominantFontSize: CGFloat

        /// Share of the card's width one point of its body text takes up.
        var textFraction: CGFloat { dominantFontSize / coordinateWidth }
    }

    /// Narrower than this and the card is unreadable however small the reader's font is.
    private static let minimumCardWidth: CGFloat = 260
    /// Below this many coordinate units an SVG is an icon or a count bubble, not a card.
    private static let minimumCoordinateWidth: CGFloat = 480
    /// A card's body text is a few percent of its width. Outside this band the SVG is using
    /// its coordinate system for something else and must keep its authored size.
    private static let plausibleTextFractions: ClosedRange<CGFloat> = 0.008...0.15

    /// Reads `svg` as a source review card, or returns nil when it isn't one.
    static func textCard(in svg: String) -> TextCard? {
        // A card that embeds a bitmap (avatar photo, cover thumbnail) is sized by that picture,
        // not by its text — leave it alone.
        guard svg.range(of: "<image", options: .caseInsensitive) == nil else { return nil }
        guard let coordinateWidth = coordinateWidth(in: svg),
              coordinateWidth >= minimumCoordinateWidth else { return nil }

        let runs = textRuns(in: svg)
        // One run is a label or a badge; a card has a heading plus its comment lines.
        guard runs.count >= 2 else { return nil }

        // The run with the most characters is the card's body text — the part the reader
        // actually reads, and the part that has to match the prose around it.
        guard let dominant = runs.max(by: { lhs, rhs in
            lhs.characterCount == rhs.characterCount
                ? lhs.fontSize < rhs.fontSize
                : lhs.characterCount < rhs.characterCount
        }) else { return nil }

        let card = TextCard(coordinateWidth: coordinateWidth, dominantFontSize: dominant.fontSize)
        guard plausibleTextFractions.contains(card.textFraction) else { return nil }
        return card
    }

    /// Width to rasterize `card` at so its body text lands on `bodyPointSize`.
    ///
    /// `bodyPointSize <= 0` means the caller has no reader font to match (the EPUB browser-layout
    /// adapter), so the card keeps the column-width behaviour it always had.
    static func preferredWidth(
        for card: TextCard,
        bodyPointSize: CGFloat,
        columnWidth: CGFloat
    ) -> CGFloat {
        guard bodyPointSize > 0, columnWidth > 0, card.textFraction > 0 else { return columnWidth }
        let matchingReaderText = bodyPointSize / card.textFraction
        // Never wider than the column it sits in, and never squeezed below legibility.
        return min(columnWidth, max(matchingReaderText, min(columnWidth, minimumCardWidth)))
    }

    // MARK: - Parsing

    private struct TextRun {
        let fontSize: CGFloat
        let characterCount: Int
    }

    private static let rootTagPattern = #"<svg\b[^>]*>"#
    private static let textElementPattern = #"<text\b([^>]*)>(.*?)</text>"#

    /// viewBox width wins over the declared width: it is the coordinate system the `<text>`
    /// positions and font sizes are expressed in.
    private static func coordinateWidth(in svg: String) -> CGFloat? {
        guard let rootRange = svg.range(of: rootTagPattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let root = String(svg[rootRange])
        if let viewBox = attribute("viewBox", in: root) {
            let parts = viewBox
                .components(separatedBy: CharacterSet.whitespaces.union(.init(charactersIn: ",")))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4, parts[2] > 0 { return CGFloat(parts[2]) }
        }
        if let width = attribute("width", in: root), let value = length(width), value > 0 {
            return value
        }
        return nil
    }

    private static func textRuns(in svg: String) -> [TextRun] {
        guard let regex = try? NSRegularExpression(
            pattern: textElementPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let ns = svg as NSString
        return regex
            .matches(in: svg, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> TextRun? in
                guard match.numberOfRanges >= 3 else { return nil }
                let attributes = ns.substring(with: match.range(at: 1))
                guard let fontSize = fontSize(inAttributes: attributes), fontSize > 0 else { return nil }
                let content = ns.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return TextRun(fontSize: fontSize, characterCount: content.count)
            }
    }

    /// `font-size` as an attribute, or out of a `style="…"` declaration — sources write both.
    private static func fontSize(inAttributes attributes: String) -> CGFloat? {
        if let raw = attribute("font-size", in: attributes), let value = length(raw) {
            return value
        }
        guard let style = attribute("style", in: attributes),
              let range = style.range(
                of: #"font-size\s*:\s*([^;]+)"#,
                options: [.regularExpression, .caseInsensitive]
              ) else { return nil }
        let declaration = String(style[range])
        guard let colon = declaration.firstIndex(of: ":") else { return nil }
        return length(String(declaration[declaration.index(after: colon)...]))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*[\"']([^\"']*)[\"']",
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Numeric length, tolerating the `px`/`pt` suffixes sources sometimes attach.
    private static func length(_ raw: String) -> CGFloat? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for unit in ["px", "pt"] where trimmed.hasSuffix(unit) {
            trimmed = String(trimmed.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let value = Double(trimmed) else { return nil }
        return CGFloat(value)
    }
}
