import CryptoKit
import Foundation
import SwiftSoup

struct ChapterRequestSpec {
    var url: String
    var method: String
    var body: String?
    var headers: [String: String]
    var referer: String?
    var useWebView: Bool
    var charset: String?
    var webViewDelayMs: Int = 0
}

struct ChapterParsePayload {
    var content: String
    var title: String
    var sourceMatched: Bool
    var isPay: Bool
    var runtimeVariables: [String: String]? = nil
}

struct ChapterPaginatedResult {
    var payload: ChapterParsePayload
    var rawHTMLPages: [String]
}

struct ChapterBuildResult {
    let package: ChapterPackage
    let rawHTML: String?
    let normalizedHTML: String
}

struct ChapterFetcher {
    static let shared = ChapterFetcher()

    /// How deep an online chapter's body may nest before `buildRenderableNormalizedHTML` flattens
    /// it (`ReaderHTMLUtilities.limitNestingDepth`). Real chapter markup stays within about a
    /// dozen levels (`div > table > tr > td > p > span > a > img`); deeper is the unclosed-tag
    /// pathology behind Crashlytics 66f63f61, not authored structure.
    ///
    /// Blink allows 512, but its frames are small. Here the binding consumer is the reader's
    /// `HTMLStyledASTRenderableNodeConverter`, which recurses once per level holding style values
    /// by value on the main thread (1MB on device): `ElementNode.asRenderableNode` reserves ~40KB
    /// per level in a Debug build (otool on the Debug-iphonesimulator object, 2026-10-18), against
    /// ~464 bytes for SwiftSoup's `outerHtmlFast`. Release frame sizes have not been measured; 32
    /// is chosen as ~3× real markup depth, not derived from them. A Debug build on a device can
    /// still overflow the converter near this depth — that is the converter's frame size, not
    /// something a lower limit here could fix without flattening authored markup.
    static let maxBodyNestingDepth = 32

    func validateResolvedContent(_ content: String) throws {
        if let message = SourceAPIErrorLog.chapterErrorEnvelopeMessage(content) {
            throw FetchError.sourceAPIError(message)
        }
    }

    func buildNormalizedHTML(title: String, content: String, titleReviewHTML: String? = nil) -> String {
        return ReaderHTMLUtilities.normalizedChapterHTML(
            title: title,
            paragraphs: ReaderHTMLUtilities.paragraphs(fromPlainText: content),
            titleReviewHTML: titleReviewHTML
        )
    }

    func buildRenderableNormalizedHTML(
        title: String,
        plainTextContent: String,
        rawHTMLContent: String?,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext? = nil
    ) async -> String {
        ReaderHTMLUtilities.logReviewMarkupDiagnostics(
            stage: "fetcherInput",
            html: rawHTMLContent ?? "",
            sourceName: reviewContext?.sourceName ?? "",
            context: ["title": title]
        )
        // Images whose real URL is produced by the source's own JS (Legado `UrlOption.js`) have to
        // be resolved HERE, while the session that just parsed this chapter still holds the
        // per-image state the source set during parsing — see `LegadoImageSourceResolver`.
        let raw = await LegadoImageSourceResolver.resolveDeferredSources(
            in: rawHTMLContent ?? "",
            reviewContext: reviewContext
        )
        ReaderHTMLUtilities.logReviewMarkupDiagnostics(
            stage: "deferredImageResolved",
            html: raw,
            sourceName: reviewContext?.sourceName ?? "",
            context: ["title": title]
        )
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksHTML = !rawTrimmed.isEmpty && Self.containsLikelyHTMLTags(raw)
        AppLogger.parse("⟐ buildRenderableNormalizedHTML", context: [
            "title": title,
            "branch": looksHTML ? "HTML(SwiftSoup)" : "PLAIN(escaped)",
            "rawLen": rawTrimmed.count,
            "plainLen": plainTextContent.count,
            "hasImg": raw.containsMarker("<img"),
            "hasDataImg": raw.containsMarker("data:image"),
            "hasUsehtml": raw.containsMarker("usehtml", ignoringCase: true),
            "rawComment": Self.countOccurrences(of: "<comment", in: raw, caseInsensitive: true),
            "rawShowCmt": Self.countOccurrences(of: "showCmt", in: raw, caseInsensitive: true),
            "rawAndroidShowCmt": Self.countOccurrences(of: "androidshowCmt", in: raw, caseInsensitive: true),
            "rawYdreview": Self.countOccurrences(of: "ydreview://", in: raw, caseInsensitive: true),
            "plainYdreview": Self.countOccurrences(of: "ydreview://", in: plainTextContent, caseInsensitive: true),
            "rawHead": String(rawTrimmed.prefix(240))
        ])
        // 去除重复标题 (Legado `ContentProcessor.getContent`): the reader renders `title` as its own
        // heading, so the source's own copy of it must not render again. Resolved here because this
        // is the one place that holds both the effective title and the body — and it has to happen
        // twice, once per representation: a leading-text strip for the plain branch, and an element
        // drop for the HTML branch, where the copy sits inside markup (`<h1>第1章 …</h1>`) that a
        // prefix regex cannot see.
        let (titleTextPart, titleBubbleHTML) = Self.splitTitleBubble(title, reviewContext: reviewContext)
        let trimmedTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: titleTextPart)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard looksHTML else {
            // A source can return plain prose while its title still carries a review
            // image. Keep that image as markup; escaping the unsplit title exposes
            // the data URI and click configuration as reading text.
            return buildNormalizedHTML(
                title: trimmedTitle,
                content: ReaderHTMLUtilities.stripLeadingDuplicateTitle(
                    plainTextContent,
                    title: trimmedTitle
                ),
                titleReviewHTML: titleBubbleHTML
            )
        }
        let originalRawHTML = raw

        // Clean Legado data-URI click-config suffixes (`,{json}`) and unwrap <usehtml> first,
        // otherwise the unbalanced quotes inside the suffix break SwiftSoup's attribute parsing
        // and the rest of the chapter leaks out as literal text.
        let cleanedRawHTML = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            originalRawHTML,
            reviewContext: reviewContext
        )
        ReaderHTMLUtilities.logReviewMarkupDiagnostics(
            stage: "sanitized",
            html: cleanedRawHTML,
            sourceName: reviewContext?.sourceName ?? "",
            context: ["title": title]
        )

        // ⟐ sanitizeClickConfig — show whether the `,{json}` click-config suffix is actually
        // stripped at fetch time. rawCommas vs cleanCommas: if cleanCommas > 0 the suffix
        // SURVIVED → SwiftSoup will break on it. `sample` shows the surviving suffix + the
        // char right after it (reveals why the strip regex's lookahead missed it).
        AppLogger.parse("⟐ sanitizeClickConfig", context: [
            "title": title,
            "rawCommas": Self.countOccurrences(of: ",{", in: originalRawHTML),
            "cleanCommas": Self.countOccurrences(of: ",{", in: cleanedRawHTML),
            "rawImg": Self.countOccurrences(of: "<img", in: originalRawHTML, caseInsensitive: true),
            "cleanImg": Self.countOccurrences(of: "<img", in: cleanedRawHTML, caseInsensitive: true),
            "rawSample": Self.clickConfigSample(in: originalRawHTML),
            "cleanSample": Self.clickConfigSample(in: cleanedRawHTML)
        ])

        // Rewrite Legado iOS paragraph-review markers into anchors before parsing, so the
        // markers survive the SwiftSoup round-trip regardless of how <comment> is handled.
        // Then, if the content is newline-separated plain-text paragraphs with only inline runs
        // (no block tags) — e.g. 段評-injected content joins paragraphs with "\n" + inline bubble
        // <img>s — wrap each line in <p> so SwiftSoup doesn't collapse the breaks into one block.
        let rawHTMLContent = ReaderHTMLUtilities.wrapNewlineParagraphsIfNeeded(
            ReaderHTMLUtilities.rewriteReviewComments(cleanedRawHTML)
        )
        AppLogger.parse("⟐ reviewHTML rewrite", context: [
            "title": title,
            "cleanLen": cleanedRawHTML.count,
            "outLen": rawHTMLContent.count,
            "cleanComment": Self.countOccurrences(of: "<comment", in: cleanedRawHTML, caseInsensitive: true),
            "outComment": Self.countOccurrences(of: "<comment", in: rawHTMLContent, caseInsensitive: true),
            "outYdreview": Self.countOccurrences(of: "ydreview://", in: rawHTMLContent, caseInsensitive: true),
            "reviewImage": Self.countOccurrences(of: "yd-review-image", in: rawHTMLContent, caseInsensitive: true),
            "clickConfig": Self.countOccurrences(of: ",{", in: originalRawHTML),
            "outHead": String(rawHTMLContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        ])

        // SwiftSoup.parse is CPU-intensive synchronous work AND degrades to a hang on the ~275KB
        // of inline base64 SVG a 段評-heavy 起点 chapter carries (96 bubbles). The base64 payloads
        // are opaque to structural parsing, so lift them out, parse the slimmed (~few-KB) HTML,
        // then restore — keeps SwiftSoup's cleaning behavior without feeding it the bloat.
        // Run in a detached task to avoid blocking the cooperative thread pool.
        let (slimmedHTML, payloadRestore) = ReaderHTMLUtilities.extractDataURIPayloads(rawHTMLContent)
        let parsedBody = await Task.detached(priority: .userInitiated) {
            () -> (
                html: String,
                titleBubble: String?,
                reviewRepair: ParagraphReviewStructureRepair,
                promotedParagraphs: Int
            ) in
            let document: Document
            do {
                document = try SwiftSoup.parse(slimmedHTML)
            } catch {
                AppLogger.parse("⟐ chapterHTML parseFailed", context: [
                    "title": title,
                    "error": String(describing: error),
                ])
                return ("", nil, ParagraphReviewStructureRepair(), 0)
            }
            guard let body = document.body() else {
                AppLogger.parse("⟐ chapterHTML noBody", context: ["title": title])
                return ("", nil, ParagraphReviewStructureRepair(), 0)
            }
            // First, before anything walks or serializes the tree: source markup that never
            // closes an inline element nests one level per paragraph, and serializing that
            // (`body.html()` below) overflowed this cooperative-pool thread's stack — Crashlytics
            // 66f63f61. The reader's converter recurses per level too, so bounding the tree here
            // is what keeps every later consumer of this chapter's HTML inside its stack.
            do {
                let flattened = try ReaderHTMLUtilities.limitNestingDepth(
                    in: body,
                    maxDepth: Self.maxBodyNestingDepth
                )
                if flattened > 0 {
                    AppLogger.parse("⟐ chapterHTML nestingLimited", context: [
                        "title": title,
                        "subtrees": flattened,
                        "maxDepth": Self.maxBodyNestingDepth,
                    ])
                }
            } catch {
                // Degradation, not a retry: a half-flattened tree may still be too deep to
                // serialize, so the chapter falls back to the plain-text rendering below, the only
                // output that cannot overflow. Guards SwiftSoup throwing mid-rebuild (its
                // `Validate` checks on reparenting), which no input is known to trigger. Delete
                // together with `limitNestingDepth` if SwiftSoup's serializer and the reader's
                // converter stop recursing per level.
                AppLogger.parse("⟐ chapterHTML nestingLimitFailed", context: [
                    "title": title,
                    "error": String(describing: error),
                ])
                return ("", nil, ParagraphReviewStructureRepair(), 0)
            }
            // `<iframe>` stays: the reader shows it as an inline video (a media file) or a
            // tap-to-load page (user's choice, 2026-10-10). Stripping it here, in the render
            // path, used to delete embedded players from web chapters outright.
            do {
                try body.select("script,noscript,object,embed").remove()
            } catch {
                AppLogger.parse("⟐ chapterHTML scriptStripFailed", context: [
                    "title": title,
                    "error": String(describing: error),
                ])
            }
            let titleBubble = Self.detachLeadingTitleReviewImage(from: body)
            Self.detachLeadingDuplicateTitle(from: body, title: trimmedTitle)
            // `<br>`-separated prose becomes real paragraphs here, on the parsed tree, so the
            // decision is per containing block instead of per chapter — one stray `<div>`/`<h2>`/
            // notice `<p>` used to cancel it for the whole chapter, leaving every paragraph after
            // the first flush against the margin. Runs before the review repair so a 段評 bubble
            // ends up inside the paragraph it belongs to.
            let promotedParagraphs = ReaderHTMLUtilities.promoteBreakSeparatedParagraphs(in: body)
            let reviewRepair = SourcePerfTrace.span("chapter.reviewRepair") {
                Self.reattachStandaloneParagraphReviews(in: body)
            }
            do {
                let html = try body.html().trimmingCharacters(in: .whitespacesAndNewlines)
                return (html, titleBubble, reviewRepair, promotedParagraphs)
            } catch {
                AppLogger.parse("⟐ chapterHTML serializeFailed", context: [
                    "title": title,
                    "error": String(describing: error),
                ])
                return ("", titleBubble, reviewRepair, promotedParagraphs)
            }
        }.value
        let bodyHTML = ReaderHTMLUtilities.restoreDataURIPayloads(parsedBody.html, restore: payloadRestore)
        let leadingTitleBubbleHTML = parsedBody.titleBubble.map {
            ReaderHTMLUtilities.restoreDataURIPayloads($0, restore: payloadRestore)
        }
        if parsedBody.promotedParagraphs > 0 {
            // ⟐ brPromotion — how many paragraphs a `<br>`-separated chapter was split into.
            // A chapter reported as "no indent / paragraphs run together" that logs nothing here
            // never reached promotion (check `⟐ buildRenderableNormalizedHTML` branch first).
            AppLogger.parse("⟐ brPromotion", context: [
                "title": title,
                "paragraphs": parsedBody.promotedParagraphs,
                "source": reviewContext?.sourceName ?? "",
            ])
        }
        if parsedBody.reviewRepair.scanned > 0 {
            AppLogger.parse("⟐ reviewFlow", context: [
                "stage": "structureRepair",
                "source": reviewContext?.sourceName ?? "",
                "scanned": parsedBody.reviewRepair.scanned,
                "alreadyInline": parsedBody.reviewRepair.alreadyInline,
                "movedBare": parsedBody.reviewRepair.movedBareAnchors,
                "movedBlock": parsedBody.reviewRepair.movedImageOnlyBlocks,
                "skipped": parsedBody.reviewRepair.skipped,
                "title": title,
            ])
        }
        ReaderHTMLUtilities.logReviewMarkupDiagnostics(
            stage: "swiftSoupBody",
            html: bodyHTML + (leadingTitleBubbleHTML ?? ""),
            sourceName: reviewContext?.sourceName ?? "",
            context: ["title": title]
        )

        guard !bodyHTML.isEmpty || leadingTitleBubbleHTML != nil else {
            return buildNormalizedHTML(
                title: trimmedTitle,
                content: ReaderHTMLUtilities.stripLeadingDuplicateTitle(
                    plainTextContent,
                    title: trimmedTitle
                ),
                titleReviewHTML: titleBubbleHTML
            )
        }

        // A chapter title may carry a 本章说 comment bubble appended as a bare `data:image/...` URI
        // (起點: `titleRow = title + Bubble`). `splitTitleBubble` above peeled the text off; the
        // bubble is rendered as the source's image (text-sized, like body 段評), not literal text.
        let resolvedTitleBubbleHTML = titleBubbleHTML ?? leadingTitleBubbleHTML
        let escapedTitle = ReaderHTMLUtilities.escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading = (trimmedTitle.isEmpty && resolvedTitleBubbleHTML == nil)
            ? ""
            : "<h1>\(ReaderHTMLUtilities.escapeHTML(trimmedTitle))\(resolvedTitleBubbleHTML ?? "")</h1>\n"

        let normalizedHTML = """
        <!DOCTYPE html>
        <html lang="zh-Hant">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escapedTitle)</title>
        </head>
        <body>
        <article id="reader-content">
        \(heading)\(bodyHTML)
        </article>
        </body>
        </html>
        """
        ReaderHTMLUtilities.logReviewMarkupDiagnostics(
            stage: "normalizedOutput",
            html: normalizedHTML,
            sourceName: reviewContext?.sourceName ?? "",
            context: ["title": title]
        )
        return normalizedHTML
    }

    /// Splits a chapter title into its text part and an optional comment-bubble `<img>` HTML.
    /// 起點 appends a 本章说 bubble to the title as a bare `data:image/...,{clickconfig}` URI; we
    /// wrap that into an `<img>` and run it through the same sanitizer as body bubbles (strips the
    /// click-config suffix, adds the review anchor + text-size marker). Returns `(title, nil)` when
    /// no bubble is present.
    private static func splitTitleBubble(
        _ title: String,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext?
    ) -> (text: String, bubbleHTML: String?) {
        guard let r = title.range(of: "data:image") else { return (title, nil) }
        let textPart = String(title[..<r.lowerBound])
        let bubbleURI = String(title[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bubbleURI.isEmpty else { return (textPart, nil) }
        let sanitized = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            "<img src=\"\(bubbleURI)\">",
            reviewContext: reviewContext
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (textPart, sanitized.isEmpty ? nil : sanitized)
    }

    /// Removes a leading image-only title-review block from the chapter body and returns its
    /// tappable anchor markup. Qidian represents title reviews as paragraph `-1`; placing that
    /// attachment inside the generated `<h1>` makes it inherit the title font/baseline instead of
    /// entering the standalone body-image centering path.
    private static func detachLeadingTitleReviewImage(from body: Element) -> String? {
        guard let firstElement = body.children().array().first else { return nil }
        let anchors = (try? firstElement.select("a.yd-review-image[href]").array()) ?? []
        let images = (try? firstElement.select("img").array()) ?? []
        guard anchors.count == 1,
              images.count == 1,
              ((try? firstElement.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              let href = try? anchors[0].attr("href"),
              ReaderHTMLUtilities.isTitleReviewHref(href),
              let anchorHTML = try? anchors[0].outerHtml()
        else { return nil }

        try? firstElement.remove()
        return anchorHTML
    }

    private struct ParagraphReviewStructureRepair: Sendable {
        var scanned = 0
        var alreadyInline = 0
        var movedBareAnchors = 0
        var movedImageOnlyBlocks = 0
        var skipped = 0
    }

    /// Some Legado sources append a text-sized paragraph-review image after the prose block's
    /// closing tag (`<p>正文</p><a class=yd-review-image>…</a>`). SwiftSoup preserves that
    /// structure, so CoreText correctly gives the anchor an anonymous paragraph of its own.
    /// Reattach only those text-sized review anchors to the immediately preceding leaf prose
    /// block. FULL review cards, author cards, title reviews, and ordinary images stay untouched.
    private static func reattachStandaloneParagraphReviews(
        in body: Element
    ) -> ParagraphReviewStructureRepair {
        var result = ParagraphReviewStructureRepair()
        // `a.yd-review-image[href]` by tag, then class and attribute: the same elements in the
        // same document order, but `select` builds SwiftSoup's class index over the whole tree
        // first, which cost 15× the document's parse (149 ms vs 10 ms for 275 bubbles, Debug).
        let anchors = ((try? body.getElementsByTag("a").array()) ?? []).filter {
            $0.hasClass("yd-review-image") && $0.hasAttr("href")
        }
        let blockTags: Set<String> = [
            "p", "div", "li", "blockquote",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "section", "article",
        ]

        // Every SwiftSoup sibling query below walks the whole parent's child list, and in a
        // 段評 chapter that parent is <body> with every prose <p> and bubble as its children:
        // asked once per bubble, the repair was quadratic in the chapter (MetricKit
        // cpu-exception d32f7c57; 1572 KB of 段評 HTML took 17.9 s in Debug, all of it here).
        //
        // The answer is memoised per element. It cannot go stale: the loop only ever moves an
        // `<a>` (not a block) or removes an empty wrapper block whose block sibling `previous`
        // stays in the same parent, so no parent gains its first or loses its last block child.
        var directBlockChild: [ObjectIdentifier: Bool] = [:]
        func hasDirectBlockChild(_ element: Element) -> Bool {
            let key = ObjectIdentifier(element)
            if let known = directBlockChild[key] { return known }
            let found = element.children().array().contains {
                blockTags.contains($0.tagName().lowercased())
            }
            directBlockChild[key] = found
            return found
        }

        // `Element.previousElementSibling()` rebuilds the parent's element list to find its own
        // index. `previousSibling()` reads the node's sibling index directly, so walking back over
        // text and comment nodes reaches the same element without that scan.
        func previousElementSibling(_ element: Element) -> Element? {
            var node = element.previousSibling()
            while let current = node {
                if let previous = current as? Element { return previous }
                node = current.previousSibling()
            }
            return nil
        }

        func trimmedText(_ element: Element) -> String {
            ((try? element.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for anchor in anchors {
            let textSizedImages = (
                try? anchor.select("img[data-yd-imgstyle=text]").array()
            ) ?? []
            guard textSizedImages.count == 1,
                  ((try? anchor.select("img").array()) ?? []).count == 1,
                  let href = try? anchor.attr("href"),
                  !ReaderHTMLUtilities.isTitleReviewHref(href),
                  let parent = anchor.parent()
            else {
                continue
            }
            result.scanned += 1

            let parentTag = parent.tagName().lowercased()
            let candidate: Element
            let emptyWrapperToRemove: Element?

            if hasDirectBlockChild(parent) {
                // The anchor is a loose inline child of body/article/a block wrapper, after <p>.
                candidate = anchor
                emptyWrapperToRemove = nil
            } else if blockTags.contains(parentTag), trimmedText(parent).isEmpty {
                // SwiftSoup/source normalization wrapped the loose anchor in its own empty <p>.
                candidate = parent
                emptyWrapperToRemove = parent
            } else if !trimmedText(parent).isEmpty {
                result.alreadyInline += 1
                continue
            } else {
                result.skipped += 1
                continue
            }

            guard let previous = previousElementSibling(candidate),
                  blockTags.contains(previous.tagName().lowercased()),
                  !hasDirectBlockChild(previous),
                  !trimmedText(previous).isEmpty
            else {
                result.skipped += 1
                continue
            }

            do {
                try previous.appendChild(anchor)
                if let emptyWrapperToRemove {
                    try emptyWrapperToRemove.remove()
                    result.movedImageOnlyBlocks += 1
                } else {
                    result.movedBareAnchors += 1
                }
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    /// HTML-side half of 去除重复标题: drops a leading element whose entire text is the chapter
    /// title (番茄酱 emits `<h1 class="chapterTitle1">第1章 …</h1>` ahead of the prose). The
    /// plain-text half is `ReaderHTMLUtilities.stripLeadingDuplicateTitle`.
    ///
    /// Deliberately conservative: the element must carry no image (an image-bearing block is
    /// content, and title-review bubbles are already handled by `detachLeadingTitleReviewImage`),
    /// and something must remain after the removal so a one-element chapter is never emptied.
    @discardableResult
    private static func detachLeadingDuplicateTitle(from body: Element, title: String) -> Bool {
        let children = body.children().array()
        guard children.count > 1, let first = children.first else { return false }
        guard ((try? first.select("img").array()) ?? []).isEmpty else { return false }
        guard let text = try? first.text(),
              ReaderHTMLUtilities.isDuplicateChapterTitle(text, title: title)
        else { return false }
        try? first.remove()
        return true
    }

    private static func containsLikelyHTMLTags(_ text: String) -> Bool {
        if text.containsMarker("<img") || text.containsMarker("<p") || text.containsMarker("<div")
            || text.containsMarker("<span") {
            return true
        }
        guard let regex = try? NSRegularExpression(pattern: "<[a-zA-Z][^>]*>") else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Returns the first `,{…}` click-config suffix plus ~60 chars of trailing context (base64
    /// collapsed), so a device log shows the exact suffix shape and the char that follows it.
    private static func clickConfigSample(in text: String) -> String {
        guard let r = text.rangeOfMarker(",{") else { return "(none)" }
        // back up ~12 chars to show the tail of the data URI, then take a window forward.
        let startIdx = text.index(r.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        let endIdx = text.index(r.lowerBound, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
        let window = String(text[startIdx..<endIdx])
        return window.replacingOccurrences(
            of: #"base64,[A-Za-z0-9+/=]+"#, with: "base64,…", options: .regularExpression
        )
    }

    private static func countOccurrences(
        of needle: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> Int {
        guard !needle.isEmpty, !text.isEmpty else { return 0 }
        return text.countMarkers(needle, ignoringCase: caseInsensitive)
    }

    func parseChapterRequest(_ raw: String) -> ChapterRequestSpec {
        LegadoRequestParser.parseChapterRequest(raw)
    }

    func merge(_ current: ChapterParsePayload, _ next: ChapterParsePayload) -> ChapterParsePayload {
        var merged = current
        if merged.title.isEmpty { merged.title = next.title }
        merged.sourceMatched = merged.sourceMatched && next.sourceMatched
        merged.isPay = merged.isPay || next.isPay
        if let nextRuntime = next.runtimeVariables, !nextRuntime.isEmpty {
            merged.runtimeVariables = nextRuntime
        }
        if !next.content.isEmpty {
            merged.content = merged.content.isEmpty ? next.content : merged.content + "\n" + next.content
        }
        return merged
    }

    func fetchPaginatedContent(
        initialHTML: String,
        initialURL: URL,
        initialBaseURL: String,
        maxPages: Int = 10,
        parsePage: @escaping @Sendable (String, String) async throws -> ChapterParsePayload,
        extractNextURLs: @escaping @Sendable (String, String) async -> [String],
        fetchNextPageHTML: @escaping @Sendable (URL) async throws -> String
    ) async throws -> ChapterPaginatedResult {
        var parsed = try await parsePage(initialHTML, initialURL.absoluteString)
        var rawHTMLPages: [String] = [initialHTML]
        var pendingURLs = await extractNextURLs(initialHTML, initialBaseURL)
        var pageCount = 0
        var visitedNextPages = Set<String>([initialURL.absoluteString])

        while !pendingURLs.isEmpty && pageCount < maxPages {
            let nextURL = pendingURLs.removeFirst()
            if visitedNextPages.contains(nextURL) { continue }
            visitedNextPages.insert(nextURL)
            guard let nextPageURL = URL(string: nextURL) else { continue }
            let nextHTML = try await fetchNextPageHTML(nextPageURL)
            rawHTMLPages.append(nextHTML)
            let nextParsed = try await parsePage(nextHTML, nextURL)
            parsed = merge(parsed, nextParsed)
            let nextBatch = await extractNextURLs(nextHTML, nextURL)
            for candidate in nextBatch where !visitedNextPages.contains(candidate) && !pendingURLs.contains(candidate) {
                pendingURLs.append(candidate)
            }
            pageCount += 1
        }

        return ChapterPaginatedResult(payload: parsed, rawHTMLPages: rawHTMLPages)
    }

    func buildChapterPackage(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String,
        tocTitle: String,
        initialHTML: String,
        initialURL: URL,
        initialBaseURL: String,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext? = nil,
        parsePage: @escaping @Sendable (String, String) async throws -> ChapterParsePayload,
        extractNextURLs: @escaping @Sendable (String, String) async -> [String],
        fetchNextPageHTML: @escaping @Sendable (URL) async throws -> String
    ) async throws -> ChapterBuildResult {
        let parseStart = CFAbsoluteTimeGetCurrent()
        ReaderTelemetry.shared.log(
            "chapter_parse_start",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "sourceURL": String(sourceURL.prefix(120)),
            ]
        )

        let paginated = try await fetchPaginatedContent(
            initialHTML: initialHTML,
            initialURL: initialURL,
            initialBaseURL: initialBaseURL,
            parsePage: parsePage,
            extractNextURLs: extractNextURLs,
            fetchNextPageHTML: fetchNextPageHTML
        )
        let parsed = paginated.payload
        let content = await SourcePerfTrace.spanAsync("chapter.resolve", "\(parsed.content.utf8.count)B") {
            await resolveContent(parsed: parsed)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FetchError.emptyContent
        }
        try validateResolvedContent(content)
        let canonicalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = canonicalTitle.isEmpty ? tocTitle : canonicalTitle
        let effectiveReviewContext = reviewContext?.withRuntimeVariables(parsed.runtimeVariables)
        let normalizedHTML = await SourcePerfTrace.spanAsync("chapter.normalizedHTML", "\(parsed.content.utf8.count)B") {
            await buildRenderableNormalizedHTML(
                title: effectiveTitle,
                plainTextContent: content,
                rawHTMLContent: parsed.content,
                reviewContext: effectiveReviewContext
            )
        }
        let rawHTML = paginated.rawHTMLPages.joined(separator: "\n<!-- staged-page-break -->\n")
        let checksum = SHA256.hash(data: Data(content.utf8)).compactMap {
            String(format: "%02x", $0)
        }.joined()
        let savedAt = Date()

        ReaderTelemetry.shared.log(
            "chapter_parse_end",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "durationMs": "\(Int((CFAbsoluteTimeGetCurrent() - parseStart) * 1000))",
                "rawPageCount": "\(paginated.rawHTMLPages.count)",
                "contentLength": "\(content.count)",
                "sourceMatched": parsed.sourceMatched ? "true" : "false",
            ]
        )

        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            canonicalTitle: canonicalTitle.isEmpty ? nil : canonicalTitle,
            content: content,
            contentChecksum: checksum,
            rawHTMLFilename: "\(chapterIndex).raw.html",
            normalizedHTMLFilename: "\(chapterIndex).normalized.xhtml",
            savedAt: savedAt,
            state: .cached,
            failureReason: nil
        )
        ReaderTelemetry.shared.log(
            "chapter_package_ready",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "title": String(package.renderTitle.prefix(80)),
                "contentLength": "\(content.count)",
            ]
        )
        return ChapterBuildResult(package: package, rawHTML: rawHTML, normalizedHTML: normalizedHTML)
    }

    func resolveContent(parsed: ChapterParsePayload) async -> String {
        let chapterTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = Self.sanitizeResolvedContent(parsed.content, title: chapterTitle)

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isPay {
            content = "[付費章節]"
        }

        content = Self.normalizeLegadoContent(content)

        // The source's own `ruleContent.replaceRegex` is NOT applied here. It runs at parse time
        // (`ModernParserBridge.parseChapterResult`, matching Legado's `BookContent.analyzeContent`),
        // which is the only place the rule engine can expand `{{chapter.title}}` templates — and the
        // only place whose result also reaches the HTML render branch, since that branch renders
        // `parsed.content`, not this plain-text copy. Applying it a second time here would be a
        // second implementation of the same concern operating on a different representation.

        content = Self.sanitizeResolvedContent(content, title: chapterTitle)

        // The user's global replace rules are NOT applied here either: the cache keeps the
        // source's text and the reader applies them at display time
        // (`OnlineProviderAttributedStringBuilder.applyReplaceRules`), as legado's
        // `ContentProcessor` does. Baking them in here applied them twice to plain-text
        // chapters and kept an edited rule from reaching chapters already cached. Manga
        // pages and audio URLs are safe from text-cleanup rules for the same reason: the
        // reader's rules only ever see laid-out prose.

        let finalNormalizedTitle = chapterTitle
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let finalNormalizedContent = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        if finalNormalizedContent.isEmpty {
            return ""
        }
        if !finalNormalizedTitle.isEmpty && finalNormalizedContent == finalNormalizedTitle {
            return ""
        }
        return content
    }

    private static func normalizeLegadoContent(_ text: String) -> String {
        // Runs three times per chapter on a document a 段評 source makes hundreds of KB; the
        // carriage-return replaces are a full copy each, so only pay for them when there is one.
        var output = text.containsMarker("\r")
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : text
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return "" }
        if Self.containsContentMediaTag(output) {
            return Self.preserveMediaBearingHTML(output)
        }
        if output.containsMarker("<") {
            // SwiftSoup follows HTML whitespace rules: literal CR/LF inside one block element is
            // ordinary whitespace. Promote source line breaks before extracting text so Legado
            // rules that return one `<p>` containing many paragraphs do not become one long line.
            output = output.replacingOccurrences(of: "\n", with: "<br>")
            output = Self.stripHtmlToText(output)
        } else {
            output = Self.decodeBasicHTMLEntities(output)
            if Self.containsContentMediaTag(output) {
                return Self.preserveMediaBearingHTML(output)
            }
        }
        while output.containsMarker("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Content that is not text: an image, a video, an audio or an `<iframe>` page. A chapter
    /// made of nothing else is still a chapter — 起点读书qm（行內影片）'s 彩蛋 is its player page
    /// alone — so these keep their markup instead of being stripped to an empty string.
    private static func containsContentMediaTag(_ text: String) -> Bool {
        text.range(
            of: #"<\s*(?:img|image|video|audio|iframe)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// `<iframe>` stays, as it does in the render path: the reader shows it as a video or an
    /// in-place page (`ReaderWebEmbed`).
    private static func preserveMediaBearingHTML(_ html: String) -> String {
        var output = html.replacingOccurrences(of: "\u{00A0}", with: " ")
        // Each case-insensitive replace walks the whole document; only pay for the ones present.
        for (entity, replacement) in [("&nbsp;", " "), ("&ensp;", " "), ("&emsp;", " "), ("&thinsp;", "")]
        where output.containsMarker(entity, ignoringCase: true) {
            output = output.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        output = output.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|object|embed)\b[^>]*>.*?</\1\s*>"#,
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|object|embed)\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        while output.containsMarker("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBasicHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&ensp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&emsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&thinsp;", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
    }

    private static func sanitizeResolvedContent(_ text: String?, title: String) -> String {
        let normalized = Self.normalizeLegadoContent(text ?? "")
        guard !normalized.isEmpty else { return "" }
        if Self.looksLikeRejectedChapterPage(normalized, title: title) {
            return ""
        }
        return normalized
    }

    private static func looksLikeRejectedChapterPage(_ text: String, title: String) -> Bool {
        let compact = text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let compactTitle = title
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        // MetricKit build 112 sampled most offline reconciliation CPU in repeated
        // Foundation substring searches here. Normalize once, then search UTF-8 bytes:
        // these fixed markers need canonical equivalence, not a new Unicode search
        // and String bridge for every marker. Keep the full body and all conjunctions.
        let bytes = Data(compact.precomposedStringWithCanonicalMapping.utf8)
        func contains(_ marker: String) -> Bool {
            bytes.range(of: Data(marker.utf8)) != nil
        }

        let isIISRuntimeError =
            (
                contains("应用程序中的服务器错误")
                    || contains("應用程式中的伺服器錯誤")
                    || contains("servererrorin'/'application")
                    || contains("servererrorin/application")
            )
            && (
                contains("运行时错误")
                    || contains("運行時錯誤")
                    || contains("runtimeerror")
                    || contains("web.config")
                    || contains("defaultredirect")
            )

        if isIISRuntimeError {
            return true
        }

        let isReadModeHint =
            contains("如遇到章节错误")
            && (
                contains("关闭浏览器的阅读/畅读/小说模式")
                    || contains("關閉瀏覽器的閱讀/暢讀/小說模式")
                    || (
                        contains("阅读/畅读/小说模式")
                            || contains("閱讀/暢讀/小說模式")
                    )
            )
            && (
                contains("关闭广告屏蔽过滤功能")
                    || contains("關閉廣告屏蔽過濾功能")
            )

        if isReadModeHint {
            return true
        }

        // Strict mode: only reject pages with precise Cloudflare challenge signatures
        let isCloudflareChallenge =
            contains("checkingyourbrowserbeforeaccessing")
            || contains("verifyyouarehuman")
            || contains("cf-browser-verification")
            || (contains("attentionrequired") && contains("cf-ray"))

        // "cloudflare" alone is insufficient; require additional verification keywords
        let hasCloudflareMention = contains("cloudflare")
        let hasChallengeKeyword =
            contains("人机验证") || contains("人機驗證")
            || contains("checkyourbrowser") || contains("ddos")

        let isHumanVerification =
            isCloudflareChallenge
            || (hasCloudflareMention && hasChallengeKeyword)
            || (contains("访问异常") && contains("验证"))
            || (contains("訪問異常") && contains("驗證"))

        if isHumanVerification {
            return true
        }

        if !compactTitle.isEmpty && compact == compactTitle {
            return true
        }

        return false
    }

    func isRejectedChapterContent(_ text: String, title: String) -> Bool {
        Self.looksLikeRejectedChapterPage(text, title: title)
    }

    func extractWebContentSinglePage(html: String, pageURL: String) async -> String {
        let parserContent = WebNovelParser.extractContent(html: html, pageURL: pageURL)
        let parserContentIsCollapsed = ReaderHTMLUtilities.isLikelyCollapsedChapterText(parserContent)
        if parserContent.count >= 120,
           !parserContentIsCollapsed {
            return parserContent
        }

        let localHTMLContent = Self.extractLocalHTMLContent(html: html, pageURL: pageURL)
        if parserContentIsCollapsed, localHTMLContent.count >= 80 {
            return localHTMLContent
        }

        let articleTask = Task { @MainActor in
            try? await WebViewFetcher.shared.extractArticle(html: html, baseURL: pageURL)
        }
        let article = await articleTask.value
        if let text = article,
           text.count >= 200,
           !ReaderHTMLUtilities.isLikelyCollapsedChapterText(text) {
            return text
        }

        if localHTMLContent.count >= 80 {
            return localHTMLContent
        }

        return localHTMLContent.isEmpty ? html.strippedHTML : localHTMLContent
    }

    /// The longest known content container's text, for a page whose source has no usable
    /// content rule; the whole page's text when no container holds 80 characters.
    static func extractLocalHTMLContent(html: String, pageURL: String) -> String {
        var winner = "none"
        return SourcePerfTrace.span("chapter.localSelectors", "bytes=\(html.utf8.count) best=\(winner)", thresholdMs: 5) {
            extractLocalHTMLContent(html: html, pageURL: pageURL, winner: &winner)
        }
    }

    static let knownContentSelectors = [
        "#chaptercontent", "#chapter-content", "#chapterContent",
        ".chapter-content", ".read-content", "#readcontent",
        ".txtnav", "#htmlContent", ".BookText", "#BookText",
        "#content", ".content", "#read_content", ".read_content",
        ".readArea", ".novel-text", "#novelcontent",
        "#bookContent", "#articleBody", ".article-body",
        "#read", ".txt", "#txt", ".article", "#article",
        ".novel_content", "#novel_content", ".chapter_content",
        "article",
    ]

    private static func extractLocalHTMLContent(html: String, pageURL: String, winner: inout String) -> String {
        // One parse for every selector. Each used to go through
        // `RuleEngine.extractValue(fromHTML:)`, which parses the whole page again: 29 parses,
        // 1036 ms for a 51 KB Narou episode and 7.9 s at 16× its body (Debug simulator, 2026-10-20).
        // Qualified: SwiftSoup exports a `parseHTML` of its own.
        let document = yuedu_app.parseHTML(html)
        var bestSelector = ""
        for selector in knownContentSelectors {
            let selectorHTML = knownSelectorHTML(selector, in: document, pageURL: pageURL)
            // A selector that matches nothing has no text to compare.
            guard !selectorHTML.isEmpty else { continue }
            let trimmed = Self.stripHtmlToText(selectorHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > bestSelector.count {
                bestSelector = trimmed
                winner = selector
            }
        }
        if bestSelector.count >= 80 {
            return bestSelector
        }

        winner = "page"
        let fallback = Self.stripHtmlToText(html).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    /// `RuleEngine.extractValue(fromHTML: page, rule: selector + "@html")` on a page already
    /// parsed with `parseHTML`: the same route (a bare tag name such as `article` is a Legado
    /// JSOUP Default rule, the rest are CSS), the outer HTML of the first match, and, for a CSS
    /// rule that matches, the same parse event in the source debugger (a miss logs none there).
    static func knownSelectorHTML(_ selector: String, in document: HTMLNode, pageURL: String) -> String {
        let rule = selector + "@html"
        if RuleEngine.isJsoupDefaultRule(selector) {
            return RuleEngine.extractValueByJsoupDefault(from: document, rule: rule, baseURL: pageURL)
        }
        let value = RuleEngine.extractValue(from: document, rule: rule, baseURL: pageURL)
        if !value.isEmpty {
            WebCrawlerDebugger.logParse(rule: rule, matchCount: 1, url: pageURL)
        }
        return value
    }

    func extractNextPageURL(html: String, currentURL: String, baseURL: String) -> String {
        NextPageLinkExtractor.extractNextPageURL(
            html: html,
            currentURL: currentURL,
            baseURL: baseURL,
            resolveURL: { href, base in
                RuleEngine.resolveURL(href, base: base)
            }
        )
    }

    static func stripHtmlToText(_ html: String) -> String {
        stripHtmlToTextUsingSwiftSoup(html) ?? ""
    }

    private static func stripHtmlToTextUsingSwiftSoup(_ html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html), let body = document.body() else {
            return nil
        }

        _ = try? document.select("script,style,noscript,iframe,object,embed").remove()

        let lineBreakMarker = "__YUEDU_LINE_BREAK__"
        let lineBreakSelectors =
            "br,p,div,li,blockquote,section,article,dt,dd,figcaption,pre,header,footer,tr,h1,h2,h3,h4,h5,h6"
        if let nodes = try? document.select(lineBreakSelectors).array() {
            for node in nodes {
                _ = try? node.appendText(lineBreakMarker)
            }
        }

        var text = (try? body.text()) ?? (try? document.text()) ?? ""
        text = text.replacingOccurrences(of: lineBreakMarker, with: "\n")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cleanChapterContent(_ text: String) -> String {
        ChapterContentCleaner.cleanChapterContent(text, htmlToText: Self.stripHtmlToText)
    }
}
