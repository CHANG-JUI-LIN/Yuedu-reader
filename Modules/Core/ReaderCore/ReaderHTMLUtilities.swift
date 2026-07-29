import Foundation
import SwiftSoup

enum ReaderHTMLUtilities {
    /// Strips markup from a source fragment and returns plain display text.
    ///
    /// By default all whitespace (including newlines) is collapsed to single
    /// spaces — correct for titles, where a single line is wanted and the result
    /// is reused as a matching/dedup key. Pass `preservingLineBreaks: true` for
    /// multi-line fields such as book intros/summaries, so the "\n" separators the
    /// source emits (and `<br>`/`</p>` boundaries) survive as paragraph breaks
    /// instead of flattening into one run-on block.
    static func displayText(fromHTMLFragment text: String, preservingLineBreaks: Bool = false) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // Book-source summaries frequently contain named/numeric HTML entities
        // beyond the small common set below (for example `&lrm;`). Decode them
        // before stripping markup so encoded tags are normalized as well.
        if let decoded = try? Entities.unescape(result) {
            result = decoded
        }

        result = result.replacingOccurrences(
            of: #"(?i)&lt;\s*br\s*/?\s*&gt;"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)<\s*br\s*/?\s*>"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)</(?:p|div|li|h[1-6]|section|article|blockquote|dt|dd|tr)>"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&ensp;", " "),
            ("&emsp;", " "),
            ("&thinsp;", ""),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#34;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Directional formatting controls are invisible layout hints, not book
        // description content. Keep joiners used by emoji/scripts, removing only
        // the bidi controls commonly emitted as HTML entities by source rules.
        let bidiControls: Set<UInt32> = [
            0x061C, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
            0xFEFF,
        ]
        result = String(result.unicodeScalars.filter { !bidiControls.contains($0.value) })

        if preservingLineBreaks {
            // Keep newlines as line breaks; only collapse horizontal whitespace and
            // trim spaces hugging each break, so intros retain paragraph structure.
            return result
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{000B}", with: " ")
                .replacingOccurrences(of: "\u{000C}", with: " ")
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
            .replacingOccurrences(of: #"[ \t\f\v\r\n]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func paragraphs(fromPlainText text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{000B}", with: " ")
            .replacingOccurrences(of: #"[ \t\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let explicitParagraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard explicitParagraphs.count <= 1,
              let onlyParagraph = explicitParagraphs.first,
              onlyParagraph.count >= 420 else {
            return explicitParagraphs
        }

        return sentenceChunks(from: onlyParagraph)
    }

    /// Wraps newline-separated segments in `<p>` when the HTML has no block-level structure.
    ///
    /// Online sources frequently deliver chapter bodies as plain-text paragraphs joined by "\n"
    /// with only *inline* markup mixed in (links, 段評 bubble `<img>`s). Handed straight to
    /// SwiftSoup, the newlines collapse to whitespace and the whole chapter renders as a single
    /// run-on block. This restores paragraph breaks generically (not per-source): if the content
    /// already contains block tags (`<p>`/`<div>`/`<br>`/…) it is returned unchanged, except
    /// for literal source newlines inside a `<p>`, which are promoted to separate paragraphs.
    static func wrapNewlineParagraphsIfNeeded(_ html: String) -> String {
        let paragraphNormalized = splitNewlineSeparatedParagraphContents(in: html)
        guard !containsBlockLevelTag(paragraphNormalized) else { return paragraphNormalized }
        let segments = paragraphNormalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard segments.count > 1 else { return paragraphNormalized }
        return segments.map { "<p>\($0)</p>" }.joined(separator: "\n")
    }

    /// Source rules sometimes wrap an entire chapter in one `<p>` while retaining the original
    /// paragraphs as CR/LF text. HTML parsers correctly collapse those characters as whitespace,
    /// so turn them into real paragraph boundaries before parsing. Existing paragraph attributes
    /// are retained on every resulting paragraph.
    private static func splitNewlineSeparatedParagraphContents(in html: String) -> String {
        let hasLineBreak = html.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
        guard hasLineBreak else { return html }

        var result = ""
        var cursor = html.startIndex
        var didSplit = false

        while let openingPrefix = html.range(
            of: "<p",
            options: [.caseInsensitive],
            range: cursor..<html.endIndex
        ) {
            let afterP = openingPrefix.upperBound
            guard afterP == html.endIndex || html[afterP] == ">" || html[afterP].isWhitespace else {
                result += html[cursor..<afterP]
                cursor = afterP
                continue
            }
            guard let openingEnd = html[afterP...].firstIndex(of: ">"),
                  let closingRange = html.range(
                    of: "</p>",
                    options: [.caseInsensitive],
                    range: html.index(after: openingEnd)..<html.endIndex
                  )
            else {
                break
            }

            let innerStart = html.index(after: openingEnd)
            let inner = String(html[innerStart..<closingRange.lowerBound])
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let segments = inner
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            result += html[cursor..<openingPrefix.lowerBound]
            if segments.count > 1 {
                let openingTag = String(html[openingPrefix.lowerBound...openingEnd])
                result += segments
                    .map { "\(openingTag)\($0)</p>" }
                    .joined(separator: "\n")
                didSplit = true
            } else {
                result += html[openingPrefix.lowerBound..<closingRange.upperBound]
            }
            cursor = closingRange.upperBound
        }

        guard didSplit else { return html }
        result += html[cursor..<html.endIndex]
        return result
    }

    private static func containsBlockLevelTag(_ html: String) -> Bool {
        let lower = html.lowercased()
        let blockTags = [
            "<p", "<div", "<br", "<li", "<ul", "<ol", "<h1", "<h2", "<h3", "<h4", "<h5", "<h6",
            "<blockquote", "<section", "<article", "<table", "<figure", "<pre", "<dl", "<dd", "<dt",
            // A raw inline <svg> document may contain internal newlines — never split it into <p>.
            "<svg"
        ]
        return blockTags.contains { lower.contains($0) }
    }

    static func bodyParagraphs(fromPlainText text: String, excludingLeadingTitle title: String) -> [String] {
        let titleKey = normalizedTitleKey(title)
        guard !titleKey.isEmpty else { return paragraphs(fromPlainText: text) }

        return paragraphs(fromPlainText: text).enumerated().compactMap { index, paragraph in
            guard index < 6,
                  normalizedTitleKey(paragraph) == titleKey
            else {
                return paragraph
            }
            return nil
        }
    }

    static func isLikelyCollapsedChapterText(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 220 else { return false }

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count <= 1 else { return false }

        let sentenceBreaks = normalized.reduce(into: 0) { count, character in
            if "。！？!?".contains(character) {
                count += 1
            }
        }
        return sentenceBreaks >= 6
    }

    // MARK: - Paragraph review (段評) markers

    /// A tappable paragraph-review target, used to present the source's review web page.
    ///
    /// Most sources encode the review page as a URL we can derive up front. Some instead ship a
    /// jsLib call that builds the URL itself at tap time (同人小说网's `createSvg(bid,cid,pid,…)`
    /// signs it with the user's shared token) — those arrive with an empty `url` and a `sourceJS`
    /// expression for `LegadoReviewActionRunner` to run against `sourceURL`'s session.
    struct ReviewTarget: Identifiable, Hashable {
        let url: String
        let title: String
        let sourceJS: String
        let sourceURL: String

        init(url: String, title: String, sourceJS: String = "", sourceURL: String = "") {
            self.url = url
            self.title = title
            self.sourceJS = sourceJS
            self.sourceURL = sourceURL
        }

        /// True when the review page can only be obtained by running the source's own JS.
        var requiresSourceJS: Bool { url.isEmpty && !sourceJS.isEmpty }

        var id: String { url.isEmpty ? "\(sourceURL)#\(sourceJS)" : url }
    }

    /// Minimal source context needed to recover Legado image click-configs into tappable review links.
    struct LegadoReviewContext: Hashable {
        let sourceName: String
        let sourceURL: String
        let sourceVariableJSON: String?
        let runtimeVariables: [String: String]?

        init(
            sourceName: String,
            sourceURL: String,
            sourceVariableJSON: String? = nil,
            runtimeVariables: [String: String]? = nil
        ) {
            self.sourceName = sourceName
            self.sourceURL = sourceURL
            self.sourceVariableJSON = sourceVariableJSON
            self.runtimeVariables = runtimeVariables
        }

        func withRuntimeVariables(_ runtimeVariables: [String: String]?) -> LegadoReviewContext {
            LegadoReviewContext(
                sourceName: sourceName,
                sourceURL: sourceURL,
                sourceVariableJSON: sourceVariableJSON,
                runtimeVariables: runtimeVariables ?? self.runtimeVariables
            )
        }
    }

    /// Decoded payload of a `ydreview://` review anchor: comment count + review URL + title.
    /// `sourceJS`/`sourceURL` are set instead of `url` for bubbles whose review page is produced
    /// by the source's own JS — see `ReviewTarget`.
    struct ReviewMarker: Equatable {
        let count: String
        let url: String
        let title: String
        let sourceJS: String
        let sourceURL: String

        init(count: String, url: String, title: String, sourceJS: String = "", sourceURL: String = "") {
            self.count = count
            self.url = url
            self.title = title
            self.sourceJS = sourceJS
            self.sourceURL = sourceURL
        }
    }

    /// Structural counts used to trace paragraph-review duplication across the online pipeline.
    /// Targets deliberately exclude the review count and timestamp: two bubbles pointing at the
    /// same `(bookId, chapterId, paragraphId)` are semantically the same marker even when their
    /// source-generated SVG/action payloads differ.
    struct ReviewMarkupDiagnostics: Equatable {
        let markerCount: Int
        let rawReviewImageCount: Int
        let reviewAnchorCount: Int
        let commentTagCount: Int
        let duplicateInstanceCount: Int
        let duplicateTargets: [String]
        let targetSequence: [String]
    }

    /// Custom URL scheme used internally to carry a paragraph-review action through the
    /// existing link/attachment pipeline. Never reaches a real network request.
    static let reviewURLScheme = "ydreview"

    /// Produces a content-free diagnostic fingerprint for paragraph-review markup.
    ///
    /// The source output uses raw Legado image click configs, while later stages carry encoded
    /// `ydreview://` anchors. Reading both representations lets a single log schema identify the
    /// exact stage where a duplicate semantic target first appears without logging prose, tokens,
    /// SVG payloads, or full review URLs.
    static func reviewMarkupDiagnostics(in html: String) -> ReviewMarkupDiagnostics {
        var targetSequence: [String] = []
        var rawReviewImageCount = 0
        var reviewAnchorCount = 0

        if html.range(of: "<img", options: .caseInsensitive) != nil,
           let imageRegex = try? NSRegularExpression(
               pattern: #"<img\b[^>]*>"#,
               options: [.caseInsensitive]
           ) {
            let ns = html as NSString
            for match in imageRegex.matches(
                in: html,
                range: NSRange(location: 0, length: ns.length)
            ) {
                let tag = ns.substring(with: match.range)
                guard let config = legadoClickConfigMatch(in: tag) else { continue }
                let suffix = (tag as NSString).substring(with: config.range)
                guard let action = legadoClickAction(fromConfigSuffix: suffix) else { continue }
                rawReviewImageCount += 1
                if let key = reviewDiagnosticTargetKey(fromAction: action) {
                    targetSequence.append(key)
                }
            }
        }

        if html.range(of: "\(reviewURLScheme)://", options: .caseInsensitive) != nil,
           let hrefRegex = try? NSRegularExpression(
               pattern: #"href\s*=\s*["'](ydreview://[^"']+)["']"#,
               options: [.caseInsensitive]
           ) {
            let ns = html as NSString
            for match in hrefRegex.matches(
                in: html,
                range: NSRange(location: 0, length: ns.length)
            ) where match.numberOfRanges >= 2 {
                let href = ns.substring(with: match.range(at: 1))
                guard let marker = decodeReviewHref(href) else { continue }
                reviewAnchorCount += 1
                if let key = reviewDiagnosticTargetKey(from: marker) {
                    targetSequence.append(key)
                }
            }
        }

        let commentTagCount: Int
        if html.range(of: "<comment", options: .caseInsensitive) != nil,
           let commentRegex = try? NSRegularExpression(
               pattern: #"<comment\b[^>]*>"#,
               options: [.caseInsensitive]
           ) {
            let ns = html as NSString
            commentTagCount = commentRegex.numberOfMatches(
                in: html,
                range: NSRange(location: 0, length: ns.length)
            )
        } else {
            commentTagCount = 0
        }

        let counts = targetSequence.reduce(into: [String: Int]()) { result, key in
            result[key, default: 0] += 1
        }
        let duplicateTargets = counts
            .filter { $0.value > 1 }
            .map { "\($0.key)×\($0.value)" }
            .sorted()
        let duplicateInstanceCount = counts.values.reduce(0) {
            $0 + max(0, $1 - 1)
        }

        return ReviewMarkupDiagnostics(
            markerCount: rawReviewImageCount + reviewAnchorCount + commentTagCount,
            rawReviewImageCount: rawReviewImageCount,
            reviewAnchorCount: reviewAnchorCount,
            commentTagCount: commentTagCount,
            duplicateInstanceCount: duplicateInstanceCount,
            duplicateTargets: Array(duplicateTargets.prefix(16)),
            targetSequence: Array(targetSequence.prefix(32))
        )
    }

    /// Emits one stable `reviewFlow` event per pipeline boundary. The target source is logged even
    /// when the marker count is zero, because disappearance is itself the evidence we need.
    static func logReviewMarkupDiagnostics(
        stage: String,
        html: String,
        sourceName: String = "",
        context: [String: Any] = [:],
        category: (String, [String: Any]) -> Void = { message, context in
            AppLogger.parse(message, context: context)
        }
    ) {
        let diagnostics = reviewMarkupDiagnostics(in: html)
        let isTargetSource = sourceName.contains("同人小说网") || sourceName.contains("同人小說網")
        guard isTargetSource || diagnostics.markerCount > 0 else { return }

        var logContext = context
        logContext["stage"] = stage
        logContext["source"] = sourceName
        logContext["markers"] = diagnostics.markerCount
        logContext["rawImages"] = diagnostics.rawReviewImageCount
        logContext["anchors"] = diagnostics.reviewAnchorCount
        logContext["comments"] = diagnostics.commentTagCount
        logContext["duplicateInstances"] = diagnostics.duplicateInstanceCount
        logContext["duplicateTargets"] = diagnostics.duplicateTargets.isEmpty
            ? "-"
            : diagnostics.duplicateTargets.joined(separator: ",")
        logContext["targetSequence"] = diagnostics.targetSequence.isEmpty
            ? "-"
            : diagnostics.targetSequence.joined(separator: ",")
        category("⟐ reviewFlow", logContext)
    }

    /// Rewrites Legado iOS paragraph-review markers into plain anchors the renderer can carry.
    ///
    /// The `paraForiOS` jsLib emits, per paragraph:
    ///   `<comment count="12" onPress="java.showReadingBrowser('<absolute-url>','番茄段评')">`
    /// Relying on an obscure `<comment>` tag (and non-allowlisted `count`/`onPress` attributes)
    /// surviving SwiftSoup round-trips is fragile, so we convert each marker into:
    ///   `<a href="ydreview://r?d=<base64url(JSON{c,u,t})>" class="yd-review">12</a>`
    /// Anchors and their `href` are always preserved and `href` is in the builder allowlist.
    /// Idempotent: a string with no `<comment …>` markers is returned unchanged.
    static func rewriteReviewComments(_ html: String) -> String {
        guard html.range(of: "<comment", options: .caseInsensitive) != nil else { return html }
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<comment\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return html }

        let ns = html as NSString
        let matches = tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        var converted = 0
        var failed = 0
        var firstFailedTag = ""
        for match in matches {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let tag = ns.substring(with: range)
            if let anchor = anchorMarkup(forCommentTag: tag) {
                converted += 1
                result += anchor
            } else {
                failed += 1
                if firstFailedTag.isEmpty {
                    firstFailedTag = tag
                }
                result += tag
            }
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        AppLogger.parse("⟐ reviewRewrite comment", context: [
            "tags": matches.count,
            "converted": converted,
            "failed": failed,
            "outYdreview": result.components(separatedBy: "ydreview://").count - 1,
            "failedTag": String(Self.redactedReviewLogSnippet(firstFailedTag).prefix(180))
        ])
        return result
    }

    /// Cleans Legado-specific markup from online chapter HTML *before* it is handed to
    /// SwiftSoup, so the parser doesn't choke on it.
    ///
    /// Legado book sources embed clickable images (illustrations, comment bubbles) as
    /// `<img src="data:image/svg+xml;base64,<B64>,{"type":"img","style":"full"}">`. The
    /// trailing `,{json}` is a Legado convention — a click-config object appended to the URL.
    /// Its inner double-quotes prematurely close the `src` attribute, so an HTML parser
    /// swallows everything up to the next quote as attribute garbage and surfaces the
    /// following tags (`<usehtml>`, `<small>`, body text) as *literal text*. Stripping the
    /// suffix restores a clean data URI and un-breaks parsing of the rest of the chapter.
    ///
    /// Also unwraps `<usehtml>` markers (Legado's "render the inner content as HTML" hint),
    /// which would otherwise survive as unknown elements.
    static func sanitizeOnlineChapterMarkup(
        _ html: String,
        reviewContext: LegadoReviewContext? = nil
    ) -> String {
        var result = rewriteLegadoImageClickConfigs(html, reviewContext: reviewContext)

        // Strip `,{…}` click-config suffixes that sit at the very end of an attribute value
        // (immediately followed by a closing quote / tag-end / whitespace). Anchoring on the
        // trailing delimiter keeps prose like "foo,{bar} baz" inside body text untouched.
        if result.range(of: ",{") != nil,
           let regex = try? NSRegularExpression(
            pattern: #",\{(?:[^{}]|\{[^{}]*\})*\}(?=["'>\s])"#
           ) {
            let ns = result as NSString
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }

        // Unwrap <usehtml>…</usehtml> markers, keeping the inner HTML.
        if result.range(of: "usehtml", options: .caseInsensitive) != nil,
           let regex = try? NSRegularExpression(
            pattern: #"</?usehtml\b[^>]*>"#,
            options: [.caseInsensitive]
           ) {
            let ns = result as NSString
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }

        return result
    }

    /// Replaces long base64 `data:` URI payloads with short placeholder tokens so heavy
    /// whole-document processing runs on a few KB of structure instead of hundreds of KB.
    ///
    /// A 段評-heavy 起点 chapter is ~275KB of inline base64 SVG (96 bubbles); `SwiftSoup.parse`
    /// degrades badly on inputs that size and effectively hangs (`⟐ swiftSoup start` with no
    /// `done`). The payloads are opaque to structural parsing, so we lift them out, parse the
    /// slimmed HTML, then restore. Pair with `restoreDataURIPayloads` AFTER parsing.
    ///
    /// Tokens use `_` (never a base64 char) plus a counter and trailing `__`, so they can't appear
    /// inside any remaining base64, can't prefix-collide with each other, are plain ASCII (SwiftSoup
    /// never escapes them), and won't occur in book prose.
    static func extractDataURIPayloads(_ html: String) -> (slimmed: String, restore: [(token: String, payload: String)]) {
        guard html.range(of: ";base64,") != nil,
              let regex = try? NSRegularExpression(pattern: #";base64,([A-Za-z0-9+/=]{64,})"#)
        else { return (html, []) }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }

        var restore: [(token: String, payload: String)] = []
        var result = ""
        var cursor = 0
        for (i, match) in matches.enumerated() {
            let payloadRange = match.range(at: 1)
            result += ns.substring(with: NSRange(location: cursor, length: payloadRange.location - cursor))
            let token = "__YD_B64_\(i)__"
            restore.append((token: token, payload: ns.substring(with: payloadRange)))
            result += token
            cursor = payloadRange.location + payloadRange.length
        }
        result += ns.substring(from: cursor)
        return (result, restore)
    }

    /// Restores payloads lifted by `extractDataURIPayloads`. Order-independent: tokens never
    /// substring-collide, so a plain per-token replace is correct.
    static func restoreDataURIPayloads(_ html: String, restore: [(token: String, payload: String)]) -> String {
        guard !restore.isEmpty else { return html }
        var result = html
        for entry in restore {
            result = result.replacingOccurrences(of: entry.token, with: entry.payload)
        }
        return result
    }

    /// Character count of `content` with long base64 data-URI payloads excluded — its "prose"
    /// length. 段評-heavy chapters carry 100s of KB of legitimate inline base64 SVG bubbles (a 起点
    /// 大热章节 is 260KB+, almost all bubbles); that bulk must NOT count toward heuristics that flag
    /// over-long content as a multi-chapter merge, or the chapter gets endlessly re-fetched.
    static func lengthExcludingBase64Payloads(_ content: String) -> Int {
        let ns = content as NSString
        guard content.range(of: ";base64,") != nil,
              let regex = try? NSRegularExpression(pattern: #";base64,([A-Za-z0-9+/=]{64,})"#)
        else { return ns.length }
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        let payloadChars = matches.reduce(0) { $0 + $1.range(at: 1).length }
        return ns.length - payloadChars
    }

    /// Restores `extractDataURIPayloads` tokens directly inside a parsed SwiftSoup `Document` — used
    /// when the slimmed HTML was parsed (so SwiftSoup didn't choke on the base64) but downstream
    /// consumers read the DOM, not a re-serialized string. Only `src`/`href` attributes carrying a
    /// token are touched, and a quick map keys the lookup by token.
    static func restoreDataURIPayloads(in document: Document, restore: [(token: String, payload: String)]) {
        guard !restore.isEmpty else { return }
        let map = Dictionary(restore.map { ($0.token, $0.payload) }, uniquingKeysWith: { a, _ in a })
        let elements = (try? document.select("[src], [href]").array()) ?? []
        for element in elements {
            for attr in ["src", "href", "xlink:href"] {
                guard let value = try? element.attr(attr),
                      value.range(of: "__YD_B64_") != nil else { continue }
                var restored = value
                for (token, payload) in map where restored.contains(token) {
                    restored = restored.replacingOccurrences(of: token, with: payload)
                }
                _ = try? element.attr(attr, restored)
            }
        }
    }

    private static func anchorMarkup(forCommentTag tag: String) -> String? {
        guard let count = firstCapture(in: tag, pattern: #"count\s*=\s*"([^"]*)""#),
              let args = showReadingBrowserArgs(in: tag)
        else { return nil }
        let url = unescapeHTMLEntities(args.url)
        let title = unescapeHTMLEntities(args.title)
        guard !url.isEmpty else { return nil }
        guard let href = reviewHref(count: count, url: url, title: title) else { return nil }
        return "<a href=\"\(href)\" class=\"yd-review\">\(escapeHTML(count))</a>"
    }

    /// Decodes a `ydreview://` href back into its comment count, review URL, and title.
    static func decodeReviewHref(_ href: String) -> ReviewMarker? {
        guard href.hasPrefix("\(reviewURLScheme)://") else { return nil }
        guard let dRange = href.range(of: "d=") else { return nil }
        let encoded = String(href[dRange.upperBound...])
        guard let data = base64URLDecode(encoded),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        let url = obj["u"] ?? ""
        let sourceJS = obj["j"] ?? ""
        // A marker is meaningful with either a ready URL or a source-JS action to run.
        guard !url.isEmpty || !sourceJS.isEmpty else { return nil }
        return ReviewMarker(
            count: obj["c"] ?? "",
            url: url,
            title: obj["t"] ?? "",
            sourceJS: sourceJS,
            sourceURL: obj["s"] ?? ""
        )
    }

    /// Convenience wrapper producing a `ReviewTarget` for sheet presentation.
    static func reviewTarget(fromHref href: String) -> ReviewTarget? {
        guard let marker = decodeReviewHref(href) else { return nil }
        return ReviewTarget(
            url: marker.url,
            title: marker.title,
            sourceJS: marker.sourceJS,
            sourceURL: marker.sourceURL
        )
    }

    /// Title-level Qidian reviews use the sentinel paragraph ID `-1`. Recognizing the decoded
    /// target lets the chapter normalizer move only that leading bubble into the `<h1>` while
    /// leaving ordinary paragraph and chapter-card images in the body.
    static func isTitleReviewHref(_ href: String) -> Bool {
        guard let marker = decodeReviewHref(href),
              let components = URLComponents(string: marker.url)
        else { return false }
        return components.queryItems?.contains {
            $0.name.caseInsensitiveCompare("paragraphId") == .orderedSame && $0.value == "-1"
        } == true
    }

    /// One source paragraph paired with its optional paragraph-review anchor.
    /// `reviewHref` is the internal `ydreview://` href (decode it for count/title).
    struct ReviewParagraph: Equatable {
        let text: String
        let reviewHref: String?
    }

    /// Parses paragraph-review HTML into an ordered list of `(text, reviewHref)` pairs so the
    /// chapter can render through the normal text layout (indent / spacing / centered title)
    /// instead of re-rendering arbitrary source HTML. Each leaf block (`<div rs-native>` / `<p>`)
    /// becomes one paragraph; the `ydreview://` anchor inside it carries that paragraph's badge.
    ///
    /// Returns an empty array when the HTML has no parseable block structure, letting callers
    /// fall back to plain-text paragraphs.
    static func reviewParagraphs(
        fromHTML html: String,
        excludingLeadingTitle title: String
    ) -> [ReviewParagraph] {
        let rewritten = rewriteReviewComments(html)
        guard let document = try? SwiftSoup.parse(rewritten),
              let body = document.body() else { return [] }

        let container: Element = ((try? body.select("article#reader-content").array())?.first) ?? body
        let blocks = leafParagraphBlocks(in: container)
        guard !blocks.isEmpty else { return [] }

        let titleKey = normalizedTitleKey(title)
        var result: [ReviewParagraph] = []
        for block in blocks {
            // Read the review anchor before stripping it out of the text.
            let reviewHref = firstReviewHref(in: block)
            let text = paragraphText(strippingReviewAnchorsFrom: block)
            if text.isEmpty, reviewHref == nil { continue }
            // Drop a leading heading that merely repeats the chapter title (handled separately).
            if !titleKey.isEmpty, result.count < 6, reviewHref == nil,
               normalizedTitleKey(text) == titleKey {
                continue
            }
            result.append(ReviewParagraph(text: text, reviewHref: reviewHref))
        }
        return result
    }

    /// Block elements that contain no nested block descendant — i.e. the innermost paragraphs.
    private static func leafParagraphBlocks(in container: Element) -> [Element] {
        let blockSelector = "p, div, li, blockquote, h1, h2, h3, h4, h5, h6"
        let candidates = (try? container.select(blockSelector).array()) ?? []
        return candidates.filter { element in
            // SwiftSoup's `select` includes the element itself, so a leaf is a block whose
            // matches are only itself (no other block descendant).
            let nested = (try? element.select(blockSelector).array()) ?? []
            return !nested.contains { $0 !== element }
        }
    }

    private static func firstReviewHref(in element: Element) -> String? {
        let anchors = (try? element.select("a[href]").array()) ?? []
        for anchor in anchors {
            let href = (try? anchor.attr("href")) ?? ""
            if href.hasPrefix("\(reviewURLScheme)://"), decodeReviewHref(href) != nil {
                return href
            }
        }
        return nil
    }

    /// Plain text of a block with its `ydreview://` badge anchors removed (so the count digits
    /// don't leak into the paragraph text). Mutates `element`; callers pass a throwaway parse tree.
    private static func paragraphText(strippingReviewAnchorsFrom element: Element) -> String {
        let anchors = (try? element.select("a[href]").array()) ?? []
        for anchor in anchors {
            let href = (try? anchor.attr("href")) ?? ""
            if href.hasPrefix("\(reviewURLScheme)://") {
                try? anchor.remove()
            }
        }
        return displayText(fromHTMLFragment: (try? element.html()) ?? "")
    }

    private static func showReadingBrowserArgs(in tag: String) -> (url: String, title: String)? {
        // Legado forks use several equivalent browser entry points for paragraph
        // reviews. 书山 v5.33 emits `startBrowser` on iOS and `startBrowserDp`
        // under its QingRead branch; older sources use `showReadingBrowser` or
        // `showCmt`. They all carry the same (url, optional title) payload.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:showReadingBrowser|showCmt|startBrowser(?:Dp)?)\(\s*'([^']*)'(?:\s*,\s*'([^']*)')?\s*\)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = tag as NSString
        guard let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2
        else { return nil }
        let title = (m.numberOfRanges >= 3 && m.range(at: 2).location != NSNotFound)
            ? ns.substring(with: m.range(at: 2))
            : ""
        return (ns.substring(with: m.range(at: 1)), title)
    }

    private static func rewriteLegadoImageClickConfigs(
        _ html: String,
        reviewContext: LegadoReviewContext?
    ) -> String {
        guard html.range(of: "<img", options: .caseInsensitive) != nil,
              html.range(of: ",{") != nil,
              let tagRegex = try? NSRegularExpression(
                pattern: #"<img\b[^>]*>"#,
                options: [.caseInsensitive]
              )
        else { return html }

        let ns = html as NSString
        let matches = tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        var reviewImages = 0
        var cleanedOnly = 0
        for match in matches {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let tag = ns.substring(with: range)
            let rewritten = rewriteLegadoImageTag(tag, reviewContext: reviewContext)
            if rewritten.range(of: "yd-review-image", options: .caseInsensitive) != nil {
                reviewImages += 1
            } else if rewritten != tag {
                cleanedOnly += 1
            }
            result += rewritten
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        if reviewImages > 0 || cleanedOnly > 0 {
            AppLogger.parse("⟐ reviewRewrite image", context: [
                "source": reviewContext?.sourceName ?? "",
                "imgTags": matches.count,
                "reviewImages": reviewImages,
                "cleanedOnly": cleanedOnly,
                "outYdreview": result.components(separatedBy: "ydreview://").count - 1
            ])
        }
        return result
    }

    private static func rewriteLegadoImageTag(
        _ tag: String,
        reviewContext: LegadoReviewContext?
    ) -> String {
        guard let configMatch = legadoClickConfigMatch(in: tag) else { return tag }
        let ns = tag as NSString
        let suffix = ns.substring(with: configMatch.range)
        var cleanedTag = tag
        if let range = Range(configMatch.range, in: cleanedTag) {
            cleanedTag.removeSubrange(range)
        }

        // Honor the click-config `style:"text"` directive: render the bubble inline at text size
        // (a small icon at the line end) instead of the SVG's intrinsic 180×144. We carry it as a
        // marker attribute the renderer reads — the suffix itself must be stripped so SwiftSoup's
        // `src` parsing doesn't choke on its inner quotes.
        if legadoClickStyle(fromConfigSuffix: suffix)?.lowercased() == "text" {
            cleanedTag = markImageAsTextSized(cleanedTag)
        }

        guard let action = legadoClickAction(fromConfigSuffix: suffix),
              let target = reviewTarget(
                forLegadoAction: action,
                context: reviewContext,
                // Only a genuine click directive may be handed back to the source runtime on tap.
                // `js` is in `legadoClickAction`'s key list because some sources put the review
                // call there, but it is also Legado's *render* option (`UrlOption.js`, which
                // produces the image URL) — running that on tap would just redraw the bubble.
                allowsSourceJSFallback: legadoConfigHasClickDirective(suffix)
                    || usesShushanCommentRuntime(reviewContext)
              ),
              let href = reviewHref(
                count: "",
                url: target.url,
                title: target.title,
                sourceJS: target.sourceJS,
                sourceURL: target.sourceURL
              )
        else {
            return cleanedTag
        }

        return "<a href=\"\(href)\" class=\"yd-review-image\">\(cleanedTag)</a>"
    }

    /// Extracts the `style` field from a Legado `,{json}` click-config suffix (e.g. "text" / "FULL").
    private static func legadoClickStyle(fromConfigSuffix suffix: String) -> String? {
        guard let object = legadoClickConfigObject(fromConfigSuffix: suffix),
              let value = object["style"] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses a Legado `,{json}` click-config suffix into a dictionary, tolerating the
    /// single-quoted keys/values some sources emit. 起點/企點 段評 bubbles use strict JSON
    /// (`{"js":"showCmt('u' )","style":"text"}`), but the 本章说 config wraps `endclick`'s
    /// double-quoted `js` value in single-quoted siblings
    /// (`{'style':'FULL','type':'qd',"js":"showCmt('u','本章说' )"}`), which is invalid strict
    /// JSON — so the tap was silently dropped. GSON (Legado on Android) accepts the lenient
    /// form; we try strict JSON first, then normalize single-quoted tokens and retry.
    static func legadoClickConfigObject(fromConfigSuffix suffix: String) -> [String: Any]? {
        var json = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix(",") { json.removeFirst() }
        json = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let data = normalizeSingleQuotedJSON(json).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Rewrites a JS-object-literal-ish string into strict JSON by converting single quotes that
    /// *delimit* a token into double quotes. Quotes inside an already double-quoted string are left
    /// untouched (so `showCmt('u','本章说' )` survives intact), and a stray double quote inside a
    /// converted single-quoted token is escaped.
    private static func normalizeSingleQuotedJSON(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count + 8)
        var inDouble = false
        var inSingle = false
        var prevBackslash = false
        for ch in input {
            if inDouble {
                out.append(ch)
                if ch == "\"" && !prevBackslash { inDouble = false }
                prevBackslash = (ch == "\\" && !prevBackslash)
            } else if inSingle {
                if ch == "'" && !prevBackslash {
                    inSingle = false
                    out.append("\"")
                    prevBackslash = false
                } else if ch == "\"" {
                    out.append("\\\"")
                    prevBackslash = false
                } else {
                    out.append(ch)
                    prevBackslash = (ch == "\\" && !prevBackslash)
                }
            } else if ch == "\"" {
                inDouble = true
                out.append(ch)
                prevBackslash = false
            } else if ch == "'" {
                inSingle = true
                out.append("\"")
                prevBackslash = false
            } else {
                out.append(ch)
                prevBackslash = false
            }
        }
        return out
    }

    /// Inserts a `data-yd-imgstyle="text"` marker as the first attribute of an `<img>` tag so the
    /// renderer sizes it to the surrounding text height. Idempotent.
    private static func markImageAsTextSized(_ tag: String) -> String {
        guard tag.range(of: "data-yd-imgstyle", options: .caseInsensitive) == nil,
              let r = tag.range(of: "<img", options: .caseInsensitive)
        else { return tag }
        var result = tag
        result.replaceSubrange(r, with: "<img data-yd-imgstyle=\"text\"")
        return result
    }

    private static func legadoClickConfigMatch(in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(
            pattern: #",\{(?:[^{}]|\{[^{}]*\})*\}(?=["'>\s])"#
        ) else { return nil }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
    }

    private static func legadoClickAction(fromConfigSuffix suffix: String) -> String? {
        guard let object = legadoClickConfigObject(fromConfigSuffix: suffix) else { return nil }
        for key in ["click", "js", "action"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Whether a `,{json}` click-config carries an explicit click directive (as opposed to only
    /// the `js` render option).
    private static func legadoConfigHasClickDirective(_ suffix: String) -> Bool {
        guard let object = legadoClickConfigObject(fromConfigSuffix: suffix) else { return false }
        return ["click", "action"].contains {
            ((object[$0] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private static func reviewTarget(
        forLegadoAction action: String,
        context: LegadoReviewContext?,
        allowsSourceJSFallback: Bool = false
    ) -> ReviewTarget? {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if let args = legadoFunctionArgs(named: "showCmt", in: trimmed)
            ?? legadoFunctionArgs(named: "androidshowCmt", in: trimmed) {
            // Aggregated sources can emit `showCmt(url, source, ...)`: arg[0] is already the
            // comment-page URL. Handle URL-shaped args before the numeric Qidian signature.
            if let url = absoluteReviewURL(from: args.first) {
                let sources = args.count >= 2 ? cleanLegadoArgument(args[1]) : ""
                return ReviewTarget(url: url, title: sources.isEmpty ? "段評" : "\(sources)段評")
            }
            // 书山 uses the same numeric `showCmt(bid,cid,para,date)` spelling as
            // Qidian, but its jsLib builds `/idea_comment` with the current 番茄
            // session. Static Qidian URL derivation loses both endpoint and login;
            // run this source-owned action in its existing session instead.
            if allowsSourceJSFallback,
               usesShushanCommentRuntime(context),
               let context,
               args.count >= 3,
               isIntegerLegadoArgument(args[0]),
               isIntegerLegadoArgument(args[1]),
               isIntegerLegadoArgument(args[2]) {
                let bookId = cleanLegadoArgument(args[0])
                let chapterId = cleanLegadoArgument(args[1])
                let paragraphId = cleanLegadoArgument(args[2])
                // Shushan's showCmt first-tap guard deliberately returns before
                // opening anything. Invoke its URL builder/browser functions
                // directly so one native bubble tap has one deterministic result,
                // while the source still supplies the live 番茄 session.
                let directAction = """
                startCommentBrowser.call(this,buildCommentUrl.call(this,'fq','\(bookId)','\(chapterId)','\(paragraphId)'),'番茄段评')
                """
                return ReviewTarget(
                    url: "",
                    title: "番茄段評",
                    sourceJS: directAction,
                    sourceURL: context.sourceURL
                )
            }
            // 起點: showCmt(bookId, chapterId, paragraphId, …) → build the qidian review URL.
            if args.count >= 3,
               isIntegerLegadoArgument(args[0]),
               isIntegerLegadoArgument(args[1]),
               isIntegerLegadoArgument(args[2]) {
                return qidianReviewTarget(
                    kind: .paragraph,
                    bookId: args[0],
                    chapterId: args[1],
                    paragraphId: args[2],
                    context: context
                )
            }
            // 企點: paragraph bubbles emit a single-argument `showCmt('<url>')`. The argument is the
            // comment-page URL, often a relative path the jsLib resolves against `sb`
            // (`https://sb.shazi.tk`). Resolve it the same way so the bubble becomes tappable.
            if args.count == 1 {
                var url = cleanLegadoArgument(args[0])
                if !(url.hasPrefix("http://") || url.hasPrefix("https://")),
                   let decoded = url.removingPercentEncoding,
                   decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
                    url = decoded
                }
                if !(url.hasPrefix("http://") || url.hasPrefix("https://")), usesShaziQidianEndpoint(context) {
                    url = "https://sb.shazi.tk" + (url.hasPrefix("/") ? url : "/" + url)
                }
                guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
                return ReviewTarget(url: url, title: "段評")
            }
        }

        if let args = legadoFunctionArgs(named: "showChapterComments", in: trimmed)
            ?? legadoFunctionArgs(named: "androidshowChapterComments", in: trimmed) {
            if let url = absoluteReviewURL(from: args.first) {
                let sources = args.count >= 2 ? cleanLegadoArgument(args[1]) : ""
                return ReviewTarget(url: url, title: sources.isEmpty ? "本章討論" : "\(sources)本章討論")
            }
            if args.count >= 2,
               isIntegerLegadoArgument(args[0]),
               isIntegerLegadoArgument(args[1]) {
                return qidianReviewTarget(
                    kind: .chapter,
                    bookId: args[0],
                    chapterId: args[1],
                    paragraphId: nil,
                    context: context
                )
            }
        }

        // Legado never special-cases the click action: it evaluates the click-config JS in the
        // source's own runtime and lets the source decide what to open (`java.showBrowser`). The
        // named handlers above only exist because those URLs can be derived statically, which is
        // cheaper. Everything else is still a real, tappable review — 同人小说网's 段評 bubbles are
        // `createSvg(bid,cid,pid,count,nano)`, a jsLib call that signs its own URL with the user's
        // shared token, so nothing here could reconstruct it. Returning nil dropped all 67 bubbles
        // per chapter: not tappable, and — because the 氣泡設定 entry is gated on the chapter
        // carrying review links — the bubble settings screen never appeared either.
        if allowsSourceJSFallback, let context, isSourceFunctionCall(trimmed) {
            return ReviewTarget(url: "", title: "段評", sourceJS: trimmed, sourceURL: context.sourceURL)
        }

        return nil
    }

    private static func usesShushanCommentRuntime(_ context: LegadoReviewContext?) -> Bool {
        guard let name = context?.sourceName else { return false }
        return name.contains("书山") || name.contains("書山")
    }

    /// Whether an action is a bare source-function call (`name(args…)`) we can hand back to the
    /// source's runtime. Keeps arbitrary click-config junk — URLs, statements, empty strings —
    /// from being sent to `eval`-adjacent evaluation.
    private static func isSourceFunctionCall(_ action: String) -> Bool {
        guard action.count <= 512, !action.contains("\n"), action.hasSuffix(")") else { return false }
        return action.range(
            of: #"^[A-Za-z_$][A-Za-z0-9_$.]*\s*\(.*\)$"#,
            options: .regularExpression
        ) != nil
    }

    private enum QidianReviewKind {
        case paragraph
        case chapter
    }

    private static func qidianReviewTarget(
        kind: QidianReviewKind,
        bookId: String,
        chapterId: String,
        paragraphId: String?,
        context: LegadoReviewContext?
    ) -> ReviewTarget? {
        let cleanBookId = cleanLegadoArgument(bookId)
        let cleanChapterId = cleanLegadoArgument(chapterId)
        let cleanParagraphId = paragraphId.map(cleanLegadoArgument)
        guard !cleanBookId.isEmpty, !cleanChapterId.isEmpty else { return nil }

        if usesShaziQidianEndpoint(context) {
            let path = kind == .paragraph ? "/comments" : "/chapterComments"
            let url = buildURL(
                base: "https://sb.shazi.tk",
                path: path,
                queryItems: [
                    URLQueryItem(name: "bookId", value: cleanBookId),
                    URLQueryItem(name: "chapterId", value: cleanChapterId)
                ] + (kind == .paragraph ? [
                    URLQueryItem(name: "paragraphId", value: cleanParagraphId ?? "")
                ] : [])
            )
            logQidianReviewTarget(
                endpoint: "shazi",
                kind: kind,
                context: context,
                url: url,
                appendedToken: false
            )
            return ReviewTarget(
                url: url,
                title: kind == .paragraph ? "起點段評" : "本章討論"
            )
        }

        // For proxy Qidian servers (shenmoxs.top, qd.doubi.tk, etc.),
        // use their own /comments endpoint instead of the dead api-x.shrtxs.cn.
        if let sourceURL = context?.sourceURL,
           !sourceURL.isEmpty,
           !sourceURL.contains("m.qidian.com") {
            let path = kind == .paragraph ? "/comments" : "/chapterComments"
            var items = [
                URLQueryItem(name: "bookId", value: cleanBookId),
                URLQueryItem(name: "chapterId", value: cleanChapterId)
            ]
            if kind == .paragraph {
                items.append(URLQueryItem(name: "paragraphId", value: cleanParagraphId ?? ""))
            }
            let url = buildURL(base: sourceURL, path: path, queryItems: items)
            logQidianReviewTarget(
                endpoint: "sourceURL",
                kind: kind,
                context: context,
                url: url,
                appendedToken: false
            )
            return ReviewTarget(
                url: url,
                title: kind == .paragraph ? "起點段評" : "本章討論"
            )
        }

        var items = [
            URLQueryItem(name: "bookId", value: cleanBookId),
            URLQueryItem(name: "chapterId", value: cleanChapterId)
        ]
        if kind == .paragraph {
            items.append(URLQueryItem(name: "paragraphId", value: cleanParagraphId ?? ""))
        }
        let token = sourceVariableValue("token", context: context)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        let url = buildURL(base: "https://api-x.shrtxs.cn/qidth", path: "/", queryItems: items)
        logQidianReviewTarget(
            endpoint: "api-x",
            kind: kind,
            context: context,
            url: url,
            appendedToken: token?.isEmpty == false
        )
        return ReviewTarget(
            url: url,
            title: kind == .paragraph ? "起點段評" : "本章討論"
        )
    }

    private static func logQidianReviewTarget(
        endpoint: String,
        kind: QidianReviewKind,
        context: LegadoReviewContext?,
        url: String,
        appendedToken: Bool
    ) {
        let summary = sourceVariableLogSummary(context: context)
        AppLogger.parse("⟐ qidianReviewTarget", context: [
            "endpoint": endpoint,
            "kind": kind == .paragraph ? "paragraph" : "chapter",
            "source": context?.sourceName ?? "",
            "sourceURL": String((context?.sourceURL ?? "").prefix(120)),
            "appendedToken": appendedToken,
            "hasTokenInURL": url.range(of: "token=", options: .caseInsensitive) != nil,
            "url": redactedReviewLogSnippet(url),
            "sourceVariableJSONLen": summary.sourceVariableJSONLen,
            "sourceVariableKeys": summary.sourceVariableKeys.joined(separator: ","),
            "sourceVariableTokenLen": summary.sourceVariableTokenLen,
            "runtimeKeys": summary.runtimeKeys.joined(separator: ","),
            "runtimeTokenLen": summary.runtimeTokenLen,
            "sourceVariableHead": summary.sourceVariableHead
        ])
    }

    private static func sourceVariableLogSummary(
        context: LegadoReviewContext?
    ) -> (
        sourceVariableJSONLen: Int,
        sourceVariableKeys: [String],
        sourceVariableTokenLen: Int,
        runtimeKeys: [String],
        runtimeTokenLen: Int,
        sourceVariableHead: String
    ) {
        let sourceVariableJSON = context?.sourceVariableJSON ?? ""
        let runtimeVariables = context?.runtimeVariables ?? [:]
        var keys: [String] = []
        var tokenLen = 0
        if let data = sourceVariableJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            keys = object.keys.sorted()
            if let token = object["token"] {
                tokenLen = "\(token)".count
            }
        }
        return (
            sourceVariableJSONLen: sourceVariableJSON.count,
            sourceVariableKeys: keys,
            sourceVariableTokenLen: tokenLen,
            runtimeKeys: runtimeVariables.keys.sorted(),
            runtimeTokenLen: runtimeVariables["token"]?.count ?? 0,
            sourceVariableHead: String(redactedReviewLogSnippet(sourceVariableJSON).prefix(180))
        )
    }

    private static func usesShaziQidianEndpoint(_ context: LegadoReviewContext?) -> Bool {
        guard let context else { return false }
        return context.sourceName.contains("企點")
            || context.sourceName.contains("企点")
            || context.sourceURL.contains("m.qidian.com")
    }

    private static func legadoFunctionArgs(named name: String, in action: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(name)\s*\(([\s\S]*)\)\s*;?\s*$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = action as NSString
        guard let match = regex.firstMatch(in: action, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let argsText = ns.substring(with: match.range(at: 1))
        return splitLegadoArguments(argsText)
    }

    private static func splitLegadoArguments(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for ch in text {
            if isEscaped {
                current.append(ch)
                isEscaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                current.append(ch)
                if ch == activeQuote { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == "," {
                args.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(ch)
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { args.append(tail) }
        return args
    }

    private static func cleanLegadoArgument(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           let first = trimmed.first,
           let last = trimmed.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func absoluteReviewURL(from value: String?) -> String? {
        guard let value else { return nil }
        var url = cleanLegadoArgument(value)
        if !(url.hasPrefix("http://") || url.hasPrefix("https://")),
           let decoded = url.removingPercentEncoding,
           decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
            url = decoded
        }
        return (url.hasPrefix("http://") || url.hasPrefix("https://")) ? url : nil
    }

    private static func isIntegerLegadoArgument(_ value: String) -> Bool {
        let cleaned = cleanLegadoArgument(value)
        guard !cleaned.isEmpty else { return false }
        let digits = cleaned.first == "-" || cleaned.first == "+"
            ? cleaned.dropFirst()
            : cleaned[...]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func sourceVariableValue(
        _ key: String,
        context: LegadoReviewContext?
    ) -> String? {
        guard let json = context?.sourceVariableJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key]
        else { return nil }
        if let string = value as? String { return string }
        return "\(value)"
    }

    private static func buildURL(base: String, path: String, queryItems: [URLQueryItem]) -> String {
        let cleanBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: cleanBase + path) else {
            let query = queryItems
                .map { "\($0.name)=\($0.value ?? "")" }
                .joined(separator: "&")
            return cleanBase + path + (query.isEmpty ? "" : "?\(query)")
        }
        components.queryItems = queryItems.filter { ($0.value ?? "").isEmpty == false }
        return components.string ?? cleanBase + path
    }

    private static func reviewHref(
        count: String,
        url: String,
        title: String,
        sourceJS: String = "",
        sourceURL: String = ""
    ) -> String? {
        guard !url.isEmpty || !sourceJS.isEmpty else { return nil }
        var payload: [String: String] = ["c": count, "u": url, "t": title]
        if !sourceJS.isEmpty {
            payload["j"] = sourceJS
            payload["s"] = sourceURL
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = base64URLEncode(data)
        else { return nil }
        return "\(reviewURLScheme)://r?d=\(encoded)"
    }

    private static func reviewDiagnosticTargetKey(from marker: ReviewMarker) -> String? {
        if let key = reviewDiagnosticTargetKey(fromAction: marker.sourceJS) {
            return key
        }
        guard let components = URLComponents(string: marker.url) else { return nil }
        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            guard let value = item.value, !value.isEmpty else { return }
            result[item.name.lowercased()] = value
        }
        let bookID = query["bookid"] ?? query["book_id"] ?? query["bid"]
        let chapterID = query["chapterid"] ?? query["chapter_id"] ?? query["cid"]
        let paragraphID = query["paragraphid"] ?? query["paragraph_id"] ?? query["pid"]
        guard let bookID, let chapterID, let paragraphID else { return nil }
        return "\(bookID)/\(chapterID)/\(paragraphID)"
    }

    private static func reviewDiagnosticTargetKey(fromAction action: String) -> String? {
        for name in ["showCmt", "androidshowCmt", "createSvg"] {
            guard let args = legadoFunctionArgs(named: name, in: action),
                  args.count >= 3,
                  isIntegerLegadoArgument(args[0]),
                  isIntegerLegadoArgument(args[1]),
                  isIntegerLegadoArgument(args[2])
            else { continue }
            return [
                cleanLegadoArgument(args[0]),
                cleanLegadoArgument(args[1]),
                cleanLegadoArgument(args[2]),
            ].joined(separator: "/")
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func unescapeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
    }

    private static func redactedReviewLogSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?i)(token=)[^'&"\s)]+"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)("token"\s*:\s*")[^"]+""#,
                with: "$1<redacted>\"",
                options: .regularExpression
            )
    }

    private static func base64URLEncode(_ data: Data) -> String? {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }

    static func normalizedChapterHTML(
        title: String,
        paragraphs: [String],
        language: String = "zh-Hant"
    ) -> String {
        let trimmedTitle = displayText(fromHTMLFragment: title)
        let escapedTitle = escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading =
            trimmedTitle.isEmpty
            ? ""
            : "<h1>\(escapeHTML(trimmedTitle))</h1>\n"
        let body = paragraphs.enumerated()
            .map { _, paragraph in
                "<p>\(escapeHTML(paragraph))</p>"
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escapedTitle)</title>
        </head>
        <body>
        <article id="reader-content">
        \(heading)\(body)
        </article>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }

    private static func normalizedTitleKey(_ text: String) -> String {
        displayText(fromHTMLFragment: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    private static func sentenceChunks(from text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let strongBreaks = Set("。！？!?；;")
        let weakBreaks = Set("，,、")

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
        }

        for character in text {
            current.append(character)
            if strongBreaks.contains(character), current.count >= 180 {
                flush()
            } else if weakBreaks.contains(character), current.count >= 260 {
                flush()
            } else if current.count >= 360 {
                flush()
            }
        }

        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Duplicate Chapter Title

    /// Legado `ContentProcessor.getContent` 去除重复标题.
    ///
    /// Sources routinely repeat the chapter title as the first line of the content, so a reader
    /// that renders its own title heading shows it twice. Legado strips one leading occurrence
    /// with `^(\s|\p{P}|<bookName>)*<title> *\n?`; this is the same rule minus the book-name
    /// branch (the book name is not plumbed down to the chapter-render layer — add it here if a
    /// source turns up that prefixes the title with `書名` rather than punctuation, which the
    /// `\p{P}` branch already covers).
    ///
    /// Only the *leading* occurrence goes: a title that legitimately recurs mid-chapter stays.
    static func stripLeadingDuplicateTitle(_ text: String, title: String) -> String {
        guard let regex = duplicateTitlePrefixRegex(for: title) else { return text }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0,
              match.range.length > 0,
              match.range.length < ns.length   // never swallow the whole chapter
        else { return text }
        return ns.substring(from: match.range.length)
    }

    /// True when `candidate` is the chapter title and nothing else — used to drop the source's own
    /// `<h1>第1章 …</h1>` from an HTML chapter body, where a prefix regex cannot reach it.
    /// Whitespace is collapsed and surrounding punctuation ignored (`《第1章》` counts as a match),
    /// but the text must be the *whole* title: a paragraph merely starting with it is left alone.
    static func isDuplicateChapterTitle(_ candidate: String, title: String) -> Bool {
        let normalizedTitle = titleComparisonKey(title)
        guard !normalizedTitle.isEmpty else { return false }
        return titleComparisonKey(candidate) == normalizedTitle
    }

    private static func titleComparisonKey(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// `^(\s|\p{P})*<title> *\n?`, with the title's own whitespace runs relaxed to `\s*` so
    /// "第1章  天资" still matches a content copy spelled "第1章 天资" (Legado does the same via
    /// `escapeRegex().replace(spaceRegex, "\\s*")`).
    ///
    /// One addition over Legado: trailing punctuation is consumed too, but only when the line ends
    /// right after it — otherwise `《第1章 …》` would leave a stray `》` behind (Legado's leading
    /// `\p{P}*` eats the opening bracket and nothing eats the closing one). The lookahead keeps
    /// prose safe: in `第1章 …，她愣住了。` the `，` is followed by text, so only the title goes.
    private static func duplicateTitlePrefixRegex(for title: String) -> NSRegularExpression? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let relaxedTitle = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        guard !relaxedTitle.isEmpty else { return nil }
        let pattern = "^(?:\\s|\\p{P})*"
            + relaxedTitle
            + "(?:[ \\t]*\\p{P}+[ \\t]*(?=\\n|$))?[ \\t]*\\n?"
        return try? NSRegularExpression(pattern: pattern)
    }
}
