import Foundation

/// Resolves Legado `<img>` sources whose real URL only exists once the source's own JS runs.
///
/// Legado's `AnalyzeUrl` treats the `,{json}` suffix on any rule URL as *URL options*, and one of
/// those options is `js`, **whose return value replaces the URL**
/// (`option.getJs()?.let { url = evalJS(it, url).toString() }`). Sources exploit this to ship an
/// image whose bytes are generated on the device instead of downloaded. 同人小说网's 段評 bubbles
/// are exactly that:
///
/// ```html
/// <img src="data:image/svg+xml;base64,,{"style":"TEXT","type":"qdzw",
///      "click":"createSvg(bid,cid,pid,count,nano)","js":"createSvg(bid,cid,pid,count,nano)"}">
/// ```
///
/// The base64 payload is **deliberately empty** — `createSvg()` in the source's jsLib builds the
/// count bubble and returns `data:image/svg+xml;base64,<real payload>`. Our chapter sanitizer
/// strips the `,{json}` suffix (it has to: its inner quotes break SwiftSoup's attribute parsing),
/// which threw the `js` away with it, so all 67 bubbles in a chapter resolved to an empty data URI:
/// nothing drawn, but every `<img>` still claimed a line box — the "段評開了之後排版全亂" report.
///
/// Resolution happens **at chapter-fetch time, in the session that just parsed the content**, not
/// lazily at image-load time, and that timing is load-bearing: `createSvg()` double-duties as the
/// tap handler and decides which job it is by a memory flag its own `getComments()` set moments
/// earlier. Called later (from a disk-cached chapter, say) the flag would be gone and every bubble
/// would try to *open the review page* instead of drawing itself.
enum LegadoImageSourceResolver {

    /// Cheap reject for the overwhelming majority of chapters: an empty base64 payload
    /// immediately followed by an option block is the only shape this resolves.
    private static let deferredSourceMarker = ";base64,,{"

    /// `<img …>` up to the first `>` — the click-config JSON never contains one.
    private static let imageTagPattern = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    /// Captures an `<img>` src that is a data URI with an **empty** payload followed by a
    /// `,{json}` option block: group 1 = everything up to and including the opening quote,
    /// group 2 = the stub URL, group 3 = the option block. The stub is what `js` replaces.
    private static let deferredSourcePattern = try! NSRegularExpression(
        pattern: #"(?i)(src\s*=\s*")(data:[^"]*?;base64,)(,\{(?:[^{}]|\{[^{}]*\})*\})"#
    )

    /// Chapter-pipeline entry point: resolves against the session of the source named by
    /// `reviewContext`. Both online chapter routes (Legado-runtime and classic) hand the review
    /// context down, so keying off it keeps one resolution point instead of one per route.
    /// Returns `html` untouched when there is nothing to resolve — checked before the source
    /// lookup, so ordinary chapters cost one substring search.
    static func resolveDeferredSources(
        in html: String,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext?
    ) -> String {
        guard html.range(of: deferredSourceMarker) != nil,
              let reviewContext,
              let source = BookSourceStore.shared.sources.first(
                where: { $0.bookSourceUrl == reviewContext.sourceURL }
              )
        else { return html }
        return resolveDeferredSources(in: html, session: BookSourceSession.session(for: source))
    }

    /// Rewrites every deferred `<img>` source in `html` to the URL its `js` option produces.
    /// Returns `html` untouched when the source uses no deferred images (the common case).
    static func resolveDeferredSources(in html: String, session: BookSourceSession) -> String {
        let matches = deferredImages(in: html)
        guard !matches.isEmpty else { return html }

        let sourceName = session.source.bookSourceName
        let decodeRule = session.source.ruleContent.imageDecode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Render, then `ruleContent.imageDecode` — Legado's post-decode hook, which sources use to
        // flip their own per-image state. 同人小说网 clears the memory flag that makes `createSvg()`
        // *draw* the bubble, so the next call — the user tapping it — *opens the review page*
        // instead. Skip it and a freshly fetched chapter's bubbles are inert until the flag ages out
        // of the LRU cache. Both steps share one critical section because between them the source
        // is in a transient state another parse must not observe.
        let produced = session.withBridge { bridge -> [String] in
            let values = evaluate(
                expressions: matches.map(\.js), bridge: bridge, sourceName: sourceName
            )
            guard !decodeRule.isEmpty else { return values }
            for image in matches {
                bridge.runImageDecodeHook(src: image.originalSrc, ruleJs: decodeRule)
            }
            return values
        }

        var resolvedCount = 0
        var result = ""
        var cursor = 0
        let ns = html as NSString
        for (match, value) in zip(matches, produced) {
            result += ns.substring(with: NSRange(location: cursor, length: match.stubRange.location - cursor))
            // A blank/failed evaluation leaves the stub in place: the bubble stays invisible, but
            // the chapter text is unharmed and the failure is in the log below.
            result += value.isEmpty ? match.stub : value
            if !value.isEmpty { resolvedCount += 1 }
            cursor = match.stubRange.location + match.stubRange.length
        }
        result += ns.substring(from: cursor)

        AppLogger.parse("⟐ deferredImageSrc", context: [
            "source": sourceName,
            "images": matches.count,
            "resolved": resolvedCount,
            "decodeHook": decodeRule.isEmpty ? "none" : "ran",
            "firstJS": String(matches[0].js.prefix(80)),
            "firstOut": String((produced.first ?? "").prefix(48))
        ])
        return result
    }

    // MARK: - Deferred image discovery

    private struct DeferredImage {
        /// Range of the stub URL inside the original HTML (what the `js` result replaces).
        let stubRange: NSRange
        let stub: String
        /// The full original `src` value, options included — what the source's `imageDecode`
        /// rule regex-matches to recover its own `createSvg(…)` arguments.
        let originalSrc: String
        let js: String
    }

    private static func deferredImages(in html: String) -> [DeferredImage] {
        guard html.range(of: deferredSourceMarker) != nil else { return [] }
        let ns = html as NSString
        var found: [DeferredImage] = []
        for tagMatch in imageTagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: tagMatch.range)
            let tagNS = tag as NSString
            guard let m = deferredSourcePattern.firstMatch(
                in: tag, range: NSRange(location: 0, length: tagNS.length)
            ), m.numberOfRanges >= 4 else { continue }

            let stub = tagNS.substring(with: m.range(at: 2))
            let options = tagNS.substring(with: m.range(at: 3))
            guard let js = LegadoClickConfig.jsExpression(inOptionSuffix: options) else { continue }

            found.append(DeferredImage(
                stubRange: NSRange(
                    location: tagMatch.range.location + m.range(at: 2).location,
                    length: m.range(at: 2).length
                ),
                stub: stub,
                originalSrc: stub + options,
                js: js
            ))
        }
        return found
    }

    // MARK: - Evaluation

    /// Evaluates every expression in **one** JS round trip. A 段評 chapter carries dozens of
    /// bubbles; crossing into JavaScriptCore once per bubble would pay the marshalling cost 67×
    /// for what is a string build and a base64 encode. Each call keeps its own try/catch so one
    /// bad bubble cannot take the chapter's other bubbles down with it.
    private static func evaluate(
        expressions: [String],
        bridge: ModernParserBridge,
        sourceName: String
    ) -> [String] {
        let calls = expressions
            .map { "try { __yd.push({ v: String(\($0)) }) } catch (e) { __yd.push({ e: String(e) }) }" }
            .joined(separator: "\n")
        let program = """
        (function () {
          var __yd = [];
          \(calls)
          return JSON.stringify(__yd);
        })()
        """

        let raw = bridge.evaluateSourceScript(program)
        guard let raw,
              let data = raw.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
              entries.count == expressions.count
        else {
            AppLogger.parse("⟐ deferredImageSrc failed", context: [
                "source": sourceName,
                "expressions": expressions.count,
                "rawHead": String((raw ?? "nil").prefix(200))
            ])
            return Array(repeating: "", count: expressions.count)
        }

        return entries.enumerated().map { index, entry in
            if let value = entry["v"] { return value }
            AppLogger.parse("⟐ deferredImageSrc js error", context: [
                "source": sourceName,
                "index": index,
                "expression": String(expressions[index].prefix(120)),
                "error": entry["e"] ?? ""
            ])
            return ""
        }
    }

}

/// Shared reader for the `,{json}` click-config Legado appends to an image URL. The block is
/// GSON-lenient (single-quoted keys appear in the wild), so parsing goes through the same
/// normalizer the chapter sanitizer uses.
enum LegadoClickConfig {
    /// The `js` field — the expression whose return value replaces the image URL.
    static func jsExpression(inOptionSuffix suffix: String) -> String? {
        guard let object = ReaderHTMLUtilities.legadoClickConfigObject(fromConfigSuffix: suffix),
              let js = object["js"] as? String
        else { return nil }
        let trimmed = js.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
