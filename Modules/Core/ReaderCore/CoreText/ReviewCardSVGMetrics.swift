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
/// So: read the card's own dominant `font-size` and widen its *canvas* until, drawn across the
/// whole column, that text lands on the reader's body point size — the card stays the full-width
/// banner it is drawn as, and gains empty space beside its text instead. (Rasterizing it smaller
/// reaches the same text size but leaves a pill floating in the middle of an iPad column.)
/// Everything the source drew is drawn exactly as authored; only the canvas around it changes,
/// with full-bleed plates stretched and right-anchored chips moved to the new edge.
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

    /// The card's coordinate system, widened so that — rasterized across the whole column —
    /// its own text lands on `bodyPointSize`. Returns nil when nothing needs to change.
    ///
    /// Shrinking the raster instead would work out to the same text size, but it turns the card
    /// into a narrow pill floating in the middle of an iPad column. The card is a full-width
    /// banner, so the fix is to give it more room to the *side* of its text: the artwork stays
    /// exactly as the source drew it, only its canvas gets wider.
    ///
    /// `bodyPointSize <= 0` means the caller has no reader font to match (the EPUB browser-layout
    /// adapter), so the card keeps the column-width behaviour it always had.
    /// - Parameter path: which of the two routes into the reader this card took, for the one
    ///   diagnostic line both of them emit — an "the card is too big on iPad" report could not be
    ///   settled from a screenshot, and this says which route sized it and to what.
    static func reshapedForColumn(
        svg: String,
        bodyPointSize: CGFloat,
        columnWidth: CGFloat,
        path: String
    ) -> String? {
        guard let card = textCard(in: svg) else { return nil }
        guard bodyPointSize > 0, columnWidth > 0, card.textFraction > 0 else { return nil }
        // Rasterized at `columnWidth`, one coordinate unit is `columnWidth / coordinateWidth`
        // points — so this is the coordinate width at which the card's own text is body-sized.
        let targetWidth = card.dominantFontSize * columnWidth / bodyPointSize
        // Only ever widen. Narrowing would mean cropping the author's layout, and a card whose
        // text is already smaller than the prose (a phone column) reads fine as it is.
        guard targetWidth > card.coordinateWidth * 1.02 else { return nil }
        guard let height = coordinateHeight(in: svg), height > 0 else { return nil }
        guard let reshaped = widened(
            svg: svg,
            from: card.coordinateWidth,
            to: targetWidth,
            height: height
        ) else { return nil }

        AppLogger.render("⟐ reviewCard reshaped", context: [
            "path": path,
            "coordW": Int(card.coordinateWidth),
            "newCoordW": Int(targetWidth),
            "fontSize": Int(card.dominantFontSize),
            "body": Int(bodyPointSize),
            "column": Int(columnWidth),
            "cardHeightPt": Int(columnWidth * height / targetWidth),
        ])
        return reshaped
    }

    // MARK: - Widening

    /// How far from an edge a coordinate still counts as anchored to it. Sized off a real card:
    /// 企点's separator rule sits 44 units in from a 1000-unit edge (4.4%), and it has to read as
    /// full-bleed or the divider stops halfway across the widened card.
    private static let edgeTolerance: CGFloat = 0.08

    /// Rewrites the SVG's canvas to `newWidth`, moving what belongs to the right edge and
    /// stretching what spans the whole card. A horizontal three-slice: left-anchored geometry
    /// stays put, right-anchored geometry travels with the edge, full-bleed geometry grows.
    private static func widened(
        svg: String,
        from oldWidth: CGFloat,
        to newWidth: CGFloat,
        height: CGFloat
    ) -> String? {
        guard let rootRange = svg.range(
            of: rootTagPattern, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        let delta = newWidth - oldWidth
        let tolerance = oldWidth * edgeTolerance
        let middle = oldWidth / 2

        /// Where a coordinate lands on the widened canvas.
        func shifted(_ x: CGFloat) -> CGFloat {
            x >= middle ? x + delta : x
        }

        var output = ""
        var index = svg.startIndex
        // Rewrite tag by tag; text nodes (the comments themselves) are copied untouched.
        while let tagStart = svg[index...].firstIndex(of: "<") {
            output += svg[index..<tagStart]
            guard let tagEnd = svg[tagStart...].firstIndex(of: ">") else {
                output += svg[tagStart...]
                return output
            }
            let tag = String(svg[tagStart...tagEnd])
            output += rewrittenTag(
                tag,
                // Identified by position: a nested `<svg>` element is a child to be
                // moved, not the canvas to be resized.
                isRoot: tagStart == rootRange.lowerBound,
                oldWidth: oldWidth,
                newWidth: newWidth,
                height: height,
                delta: delta,
                tolerance: tolerance,
                middle: middle,
                shifted: shifted
            )
            index = svg.index(after: tagEnd)
        }
        output += svg[index...]
        return output
    }

    private static func rewrittenTag(
        _ tag: String,
        isRoot: Bool,
        oldWidth: CGFloat,
        newWidth: CGFloat,
        height: CGFloat,
        delta: CGFloat,
        tolerance: CGFloat,
        middle: CGFloat,
        shifted: (CGFloat) -> CGFloat
    ) -> String {
        let name = tagName(of: tag)

        if isRoot {
            var updated = replacingAttribute("viewBox", in: tag, with: "0 0 \(number(newWidth)) \(number(height))")
            updated = replacingAttribute("width", in: updated, with: number(newWidth))
            updated = replacingAttribute("height", in: updated, with: number(height))
            return updated
        }

        switch name {
        case "rect", "image", "foreignobject", "svg":
            let x = attribute("x", in: tag).flatMap(length) ?? 0
            guard let width = attribute("width", in: tag).flatMap(length) else { return tag }
            let touchesRightEdge = abs((x + width) - oldWidth) <= tolerance
            if touchesRightEdge && x < middle {
                // Background plate or separator rule: grows with the card.
                return replacingAttribute("width", in: tag, with: number(newWidth - x))
            }
            if x >= middle || touchesRightEdge {
                // A right-side chip (like pill, count badge): keeps its size, follows the edge.
                return replacingAttribute("x", in: tag, with: number(x + delta))
            }
            return tag

        case "text", "tspan":
            guard let x = attribute("x", in: tag).flatMap(length) else { return tag }
            // A title the author centred stays centred; everything else is edge-anchored.
            if attribute("text-anchor", in: tag)?.lowercased() == "middle",
               abs(x - middle) <= tolerance {
                return replacingAttribute("x", in: tag, with: number(newWidth / 2))
            }
            let moved = shifted(x)
            return moved == x ? tag : replacingAttribute("x", in: tag, with: number(moved))

        case "circle", "ellipse":
            guard let cx = attribute("cx", in: tag).flatMap(length) else { return tag }
            let moved = shifted(cx)
            return moved == cx ? tag : replacingAttribute("cx", in: tag, with: number(moved))

        case "line":
            var updated = tag
            for attributeName in ["x1", "x2"] {
                guard let value = attribute(attributeName, in: updated).flatMap(length) else { continue }
                let moved = abs(value - oldWidth) <= tolerance ? newWidth : shifted(value)
                if moved != value {
                    updated = replacingAttribute(attributeName, in: updated, with: number(moved))
                }
            }
            return updated

        default:
            // `<g transform="translate(x,y)">` wraps the icons these cards put on their right
            // side; the group's own offset is what anchors them.
            guard let transform = attribute("transform", in: tag),
                  let range = transform.range(
                    of: #"translate\s*\(\s*(-?[\d.]+)"#,
                    options: [.regularExpression, .caseInsensitive]
                  ) else { return tag }
            let prefix = String(transform[range])
            guard let openParen = prefix.firstIndex(of: "("),
                  let tx = length(String(prefix[prefix.index(after: openParen)...])) else { return tag }
            let moved = shifted(tx)
            guard moved != tx else { return tag }
            let updatedTransform = transform.replacingCharacters(
                in: range,
                with: "translate(\(number(moved))"
            )
            return replacingAttribute("transform", in: tag, with: updatedTransform)
        }
    }

    /// Coordinate height that pairs with `TextCard.coordinateWidth`.
    static func coordinateHeight(in svg: String) -> CGFloat? {
        guard let rootRange = svg.range(
            of: rootTagPattern, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let root = String(svg[rootRange])
        if let viewBox = attribute("viewBox", in: root) {
            let parts = viewBox
                .components(separatedBy: CharacterSet.whitespaces.union(.init(charactersIn: ",")))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4, parts[3] > 0 { return CGFloat(parts[3]) }
        }
        if let height = attribute("height", in: root), let value = length(height), value > 0 {
            return value
        }
        return nil
    }

    private static func tagName(of tag: String) -> String {
        let scalars = tag.dropFirst().drop { $0 == "/" }
        return String(scalars.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }).lowercased()
    }

    /// Trims the trailing `.0` so rewritten attributes read like authored ones.
    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }

    /// Replaces an attribute's value, or appends the attribute when the tag lacks it.
    private static func replacingAttribute(
        _ name: String,
        in tag: String,
        with value: String
    ) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*[\"\']([^\"\']*)[\"\']"
        if let range = tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return tag.replacingCharacters(in: range, with: "\(name)=\"\(value)\"")
        }
        guard let insertion = tag.lastIndex(where: { $0 != ">" && $0 != "/" && !$0.isWhitespace }) else {
            return tag
        }
        return tag.replacingCharacters(
            in: tag.index(after: insertion)..<tag.index(after: insertion),
            with: " \(name)=\"\(value)\""
        )
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
