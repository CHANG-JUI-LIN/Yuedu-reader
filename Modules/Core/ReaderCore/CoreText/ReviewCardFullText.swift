import Foundation

/// A comment a source cut short for its own card (`txt.slice(0, 18) + "..."`), made whole again
/// from the response the source built the card from.
///
/// Sources size their review cards for a line or two, so they cut the comment before drawing
/// it and the full text never reaches the chapter. It did reach the bridge: the content rule
/// fetched it as JSON (起点's `/api/godcomments`, 知秋's `/novel/comment/v2/bubbles`, 聚合段评's
/// `reviewlist4m`). A cut comment is matched to the one string in those responses that it
/// begins, and the card carries that text on its root (`data-yd-full-comments`), so a reader's
/// own template (`ReviewCardTemplate`) lays the whole comment out and ends it with `…` only where
/// its own lines run out. The source's own drawing of the card is left as the source drew it.
///
/// A cut comment stays cut when no response string continues it, or more than one does: the
/// text came from somewhere the device never sees (聚合段评's server cuts its cards before
/// sending them), or the source rewrote it beyond what `sourceTransform` repeats.
enum ReviewCardFullText {
    /// The root attribute a card's restored comments travel in, as a JSON array of strings.
    static let attribute = "data-yd-full-comments"

    /// How sources end a comment they cut: 起点读书qm `...`, 知秋 `⋯`, 聚合段评 `…`.
    private static let cutMarks = ["……", "...", "…", "⋯"]

    /// The fewest characters a cut comment must keep for its beginning to name one comment.
    private static let minimumPrefix = 6

    /// `html` with every SVG review card whose comments the source cut carrying their full
    /// text. `responses` are the bodies the content rule fetched; `sourceTransform` repeats what
    /// the source did to a comment before drawing it (its face-code replacer), one output per
    /// input, and runs only when a card was cut.
    static func restoringCutComments(
        in html: String,
        responses: [String],
        sourceTransform: ([String]) -> [String]
    ) -> String {
        guard !responses.isEmpty, html.contains(dataURIPrefix),
              let regex = try? NSRegularExpression(pattern: dataURIPattern) else { return html }
        let ns = html as NSString
        var cutCards: [(payload: NSRange, svg: String, cut: [String])] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let payload = match.range(at: 1)
            guard let data = Data(base64Encoded: ns.substring(with: payload)),
                  let svg = String(data: data, encoding: .utf8),
                  // Most cards here are 段評 bubbles; only a cut comment carries a mark.
                  cutMarks.contains(where: { svg.contains($0) }),
                  !svg.contains(attribute),
                  let card = ReviewCardContent.extract(from: svg) else { continue }
            let cut = card.comments.map(\.content).filter { cutPrefix(of: $0) != nil }
            if !cut.isEmpty { cutCards.append((payload, svg, cut)) }
        }
        guard !cutCards.isEmpty else { return html }

        let strings = responseStrings(responses)
        let transformed = sourceTransform(strings)
        let candidates = transformed.count == strings.count ? transformed : strings
        let result = NSMutableString(string: html)
        var restored = 0
        for card in cutCards.reversed() {
            let fullTexts = card.cut.compactMap { fullText(of: $0, among: candidates) }
            guard !fullTexts.isEmpty, let annotated = annotated(card.svg, with: fullTexts) else { continue }
            result.replaceCharacters(in: card.payload, with: Data(annotated.utf8).base64EncodedString())
            restored += fullTexts.count
        }
        AppLogger.parse("⟐ reviewCard fullText", context: [
            "cutCards": cutCards.count,
            "cutComments": cutCards.reduce(0) { $0 + $1.cut.count },
            "restored": restored,
            "candidates": candidates.count,
        ])
        return result as String
    }

    /// The comment before the source's mark, or nil when the source did not cut it.
    static func cutPrefix(of content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = cutMarks.first(where: { trimmed.hasSuffix($0) }) else { return nil }
        var prefix = String(trimmed.dropLast(mark.count))
        // `slice` counts UTF-16 units: it can halve an emoji (left as U+FFFD) or an escaped
        // `&amp;`, neither of which the full comment contains.
        while prefix.unicodeScalars.last == "\u{FFFD}" {
            prefix.unicodeScalars.removeLast()
        }
        if let entity = prefix.range(of: #"&#?[A-Za-z0-9]{0,8}$"#, options: .regularExpression) {
            prefix.removeSubrange(entity)
        }
        return prefix
    }

    /// The one candidate the cut `content` begins, as the card should show it; nil when the
    /// source did not cut it, too little is left to tell, or no candidate or several do.
    static func fullText(of content: String, among candidates: [String]) -> String? {
        guard let prefix = cutPrefix(of: content) else { return nil }
        let key = matchKey(prefix)
        guard key.count >= minimumPrefix else { return nil }
        var found: (key: [Unicode.Scalar], text: String)?
        for candidate in candidates {
            let text = displayText(candidate)
            let candidateKey = matchKey(text)
            guard candidateKey.count > key.count, candidateKey.starts(with: key) else { continue }
            if let found, found.key != candidateKey { return nil }
            found = (candidateKey, text)
        }
        return found?.text
    }

    // MARK: - Private

    private static let dataURIPrefix = "data:image/svg+xml;base64,"
    private static let dataURIPattern = #"data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)"#

    /// Every string in the JSON responses long enough to be a comment, once each.
    private static func responseStrings(_ responses: [String]) -> [String] {
        var seen = Set<String>()
        var strings: [String] = []
        func collect(_ value: Any) {
            switch value {
            case let text as String:
                if (minimumPrefix...4000).contains(text.count), seen.insert(text).inserted {
                    strings.append(text)
                }
            case let array as [Any]:
                array.forEach(collect)
            case let object as [String: Any]:
                object.values.forEach(collect)
            default:
                break
            }
        }
        for body in responses {
            // A body that is not JSON holds no comment strings; nothing is lost by skipping it.
            guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) else {
                continue
            }
            collect(object)
        }
        return strings
    }

    /// A response string as a card line shows it: markup dropped, whitespace collapsed.
    private static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What two texts are compared by: their scalars without whitespace, since sources wrap and
    /// collapse a comment's spaces as they draw it.
    private static func matchKey(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// `svg` with `fullTexts` on its root.
    private static func annotated(_ svg: String, with fullTexts: [String]) -> String? {
        guard let root = svg.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
              let json = try? JSONSerialization.data(withJSONObject: fullTexts),
              let list = String(data: json, encoding: .utf8) else { return nil }
        let value = list
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        var rootTag = String(svg[root])
        let closing = rootTag.hasSuffix("/>") ? 2 : 1
        rootTag.insert(contentsOf: " \(attribute)=\"\(value)\"", at: rootTag.index(rootTag.endIndex, offsetBy: -closing))
        var result = svg
        result.replaceSubrange(root, with: rootTag)
        return result
    }
}
