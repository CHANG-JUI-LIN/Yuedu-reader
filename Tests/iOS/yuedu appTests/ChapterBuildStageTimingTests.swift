import Foundation
import SwiftSoup
import Testing
@testable import yuedu_app

/// MetricKit cpu-exception d32f7c57 (≤2.0.7): the chapter build's CPU. Times every in-task stage of
/// `ChapterFetcher.buildChapterPackage` on the Narou episode fixture at 1× and 4× its body, so a
/// stage whose cost grows faster than its input shows up as a ratio, and pins what the 段評 repair
/// does to each bubble layout so a faster repair cannot quietly move a bubble. No network.
///
/// The timings are reported, not asserted (Debug build: compare ratios, not milliseconds). Measured
/// 2026-10-20 before the repair was made linear, at 1×/4×/16×: 段評 normalized HTML took 444 / 2294 /
/// 17901 ms (16× the input, 40× the time) and every other stage grew 7–18×.
@MainActor
@Suite("Chapter build stage timing", .serialized)
struct ChapterBuildStageTimingTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Narou")
    nonisolated private static let pageURL = "https://ncode.syosetu.com/n9669bk/1/"
    private static let review = ReaderHTMLUtilities.LegadoReviewContext(sourceName: "timing", sourceURL: "https://timing.test")

    private struct Inputs {
        let page: String
        let paragraphs: [String]

        func body(_ scale: Int) -> String {
            Array(repeating: paragraphs.joined(separator: "\n"), count: scale).joined(separator: "\n")
        }

        /// A 段評 source's body: every paragraph followed by its comment-bubble image.
        func reviewBody(_ scale: Int) -> String {
            let rows = paragraphs.enumerated().map { index, paragraph in "\(paragraph)\(bubble(index))" }
            return Array(repeating: rows.joined(separator: "\n"), count: scale).joined(separator: "\n")
        }

        /// The whole episode page with its body scaled, for the heuristic (no content rule) path.
        func fullPage(_ scale: Int) -> String {
            page.replacingOccurrences(of: paragraphs.joined(separator: "\n"), with: body(scale))
        }
    }

    /// A 起点-style text-sized bubble: an SVG data URI carrying its Legado click config.
    nonisolated private static func bubble(_ index: Int) -> String {
        let svg = ##"<svg width="850" height="850" xmlns="http://www.w3.org/2000/svg"><rect width="850" height="850" rx="180" fill="#A9A9A9"/><text x="425" y="425">2</text></svg>"##
        let click = #"{"style":"text","type":"qd","click":"showCmt(123, 456, \#(index), 999, 'ios', '改版')"}"#
        return "<img src=\"data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString()),\(click)\">"
    }

    private func loadInputs() throws -> Inputs {
        let page = try String(contentsOf: Self.fixtures.appendingPathComponent("narou-episode.html"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"<p id="L\d+">.*?</p>"#)
        let ns = page as NSString
        let paragraphs = regex.matches(in: page, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        try #require(paragraphs.count > 200)
        try #require(page.contains(paragraphs.joined(separator: "\n")), "fullPage() scales the contiguous body")
        return Inputs(page: page, paragraphs: paragraphs)
    }

    /// Median of `runs` wall-clock timings, in milliseconds.
    private func time(runs: Int = 3, _ work: () async throws -> Void) async rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await work()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }

    private func normalizedReviewHTML(_ raw: String) async -> String {
        let plain = await ChapterFetcher.shared.resolveContent(
            parsed: ChapterParsePayload(content: raw, title: "t", sourceMatched: true, isPay: false)
        )
        return await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "t", plainTextContent: plain, rawHTMLContent: raw, reviewContext: Self.review
        )
    }

    // MARK: - 段評 repair placement

    private struct Placement: Equatable, CustomStringConvertible {
        var inProse = 0
        var inEmptyParagraph = 0
        var elsewhere: [String: Int] = [:]
        var description: String { "inProse=\(inProse) inEmptyParagraph=\(inEmptyParagraph) elsewhere=\(elsewhere)" }
    }

    /// Where each review bubble sits in the normalized chapter: inside a prose paragraph (where
    /// `reattachStandaloneParagraphReviews` puts the ones it repairs), in a paragraph of its own,
    /// or loose in another element.
    private func placement(of html: String) throws -> Placement {
        // Held for the loop: SwiftSoup's `parent()` is weak, so a temporary document's
        // elements lose their parents as soon as it is released.
        let document = try SwiftSoup.parse(html)
        let anchors = try document.getElementsByTag("a").array().filter { $0.hasClass("yd-review-image") }
        var result = Placement()
        for anchor in anchors {
            guard let parent = anchor.parent() else { continue }
            if parent.tagName() == "p" {
                if try parent.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.inEmptyParagraph += 1
                } else {
                    result.inProse += 1
                }
            } else {
                result.elsewhere[parent.tagName(), default: 0] += 1
            }
        }
        return result
    }

    /// Expected placements were read from the repair as it was before it was made linear
    /// (2026-10-20); its output, with each review link's JSON keys sorted, was byte-identical
    /// before and after on every case here. The fixture's blank `<p><br></p>` lines are why
    /// some bubbles stay loose: the repair leaves a bubble whose previous paragraph has no text.
    @Test("the 段評 repair places every bubble layout as before", arguments: [
        "review", "wrapped", "consecutive", "inline", "nested", "leading", "misc",
    ])
    func reviewRepairPlacement(_ layout: String) async throws {
        let inputs = try loadInputs()
        let bubble = Self.bubble
        let prose = inputs.paragraphs.prefix(40).map {
            $0.replacingOccurrences(of: #"<p id="L\d+">"#, with: "<p>", options: .regularExpression)
        }
        let raw: String
        let expected: Placement
        switch layout {
        case "review":
            raw = inputs.reviewBody(1)
            expected = Placement(inProse: 205, elsewhere: ["article": 70])
        case "wrapped": // bubble in its own empty <p>, after a prose <p>
            raw = prose.enumerated().map { "\($1)<p>\(bubble($0))</p>" }.joined(separator: "\n")
            expected = Placement(inProse: 32, inEmptyParagraph: 8)
        case "consecutive": // two bubbles in a row after one paragraph
            raw = prose.enumerated().map { "\($1)\(bubble($0))\(bubble($0 + 1000))" }.joined(separator: "\n")
            expected = Placement(inProse: 64, elsewhere: ["article": 16])
        case "inline": // bubble already inside its paragraph
            raw = prose.enumerated().map { $1.replacingOccurrences(of: "</p>", with: "\(bubble($0))</p>") }.joined(separator: "\n")
            expected = Placement(inProse: 40)
        case "nested": // inside a wrapping <div>; every third after a <div> holding a block
            raw = "<div>" + prose.enumerated().map { index, line in
                index % 3 == 0 ? "<div>\(line)</div>\(bubble(index))" : "\(line)\(bubble(index))"
            }.joined(separator: "\n") + "</div>"
            expected = Placement(inProse: 20, elsewhere: ["div": 20])
        case "leading": // a bubble first; text and comment nodes between siblings
            raw = bubble(0) + prose.enumerated().map { "\($1)\n<!-- c -->\n text \(bubble($0))" }.joined(separator: "\n")
            expected = Placement(inProse: 32, elsewhere: ["article": 9])
        default: // after a heading, an empty paragraph, a <br>, and plain prose
            raw = prose.enumerated().map { index, line in
                switch index % 4 {
                case 0: return "<h3>小見出し</h3>\(bubble(index))"
                case 1: return "<p> </p>\(bubble(index))"
                case 2: return "\(line)<br>\(bubble(index))"
                default: return "\(line)\(bubble(index))"
                }
            }.joined(separator: "\n")
            expected = Placement(inProse: 15, inEmptyParagraph: 15, elsewhere: ["h3": 10])
        }

        let normalizedHTML = await normalizedReviewHTML(raw)
        let found = try placement(of: normalizedHTML)
        #expect(found == expected, "\(layout): \(found)")
    }

    // MARK: - Stage timings

    private func report(_ stage: String, _ timings: [(Int, Double, Int)]) {
        let cells = timings.map { scale, ms, chars in
            "\(scale)x=\(String(format: "%.1f", ms))ms(\(chars / 1024)KB)"
        }.joined(separator: " ")
        let growth = timings.count > 1 && timings[0].1 > 0
            ? String(format: " %dx/1x=%.1f", timings[timings.count - 1].0, timings[timings.count - 1].1 / timings[0].1) : ""
        print("CARD5-TIMING \(stage): \(cells)\(growth)")
    }

    @Test("every in-task stage of a chapter build, at two body sizes")
    func stageTimings() async throws {
        let inputs = try loadInputs()
        let fetcher = ChapterFetcher.shared
        let title = "第1話 プロローグ"
        var stages: [(String, [(Int, Double, Int)])] = [
            "resolveContent(html)", "resolveContent(段評)", "normalizedHTML(html)", "normalizedHTML(段評)",
            "extractWebContentSinglePage(page)", "buildChapterPackage(1 page)", "buildChapterPackage(4 pages)",
            "replaceRules attributed (display)",
        ].map { ($0, []) }
        func add(_ index: Int, _ scale: Int, _ ms: Double, _ size: Int) { stages[index].1.append((scale, ms, size)) }
        let rules = Self.replaceRules()

        for scale in [1, 4] {
            let body = inputs.body(scale)
            let reviewBody = inputs.reviewBody(scale)
            let page = inputs.fullPage(scale)
            let payload = ChapterParsePayload(content: body, title: title, sourceMatched: true, isPay: false)
            let reviewPayload = ChapterParsePayload(content: reviewBody, title: title, sourceMatched: true, isPay: false)

            var plain = ""
            add(0, scale, await time { plain = await fetcher.resolveContent(parsed: payload) }, body.utf8.count)
            #expect(!plain.isEmpty)
            var reviewPlain = ""
            add(1, scale, await time { reviewPlain = await fetcher.resolveContent(parsed: reviewPayload) }, reviewBody.utf8.count)
            add(2, scale, await time {
                _ = await fetcher.buildRenderableNormalizedHTML(title: title, plainTextContent: plain, rawHTMLContent: body)
            }, body.utf8.count)
            add(3, scale, await time {
                _ = await fetcher.buildRenderableNormalizedHTML(
                    title: title, plainTextContent: reviewPlain, rawHTMLContent: reviewBody, reviewContext: Self.review
                )
            }, reviewBody.utf8.count)
            add(4, scale, await time {
                _ = await fetcher.extractWebContentSinglePage(html: page, pageURL: Self.pageURL)
            }, page.utf8.count)
            add(5, scale, try await time {
                _ = try await fetcher.buildChapterPackage(
                    bookId: UUID(), chapterIndex: 0, sourceURL: Self.pageURL, tocTitle: title,
                    initialHTML: page, initialURL: URL(string: Self.pageURL)!, initialBaseURL: Self.pageURL,
                    parsePage: { _, _ in payload },
                    extractNextURLs: { _, _ in [] },
                    fetchNextPageHTML: { _ in page }
                )
            }, body.utf8.count)
            add(6, scale, try await time {
                _ = try await fetcher.buildChapterPackage(
                    bookId: UUID(), chapterIndex: 0, sourceURL: Self.pageURL, tocTitle: title,
                    initialHTML: page, initialURL: URL(string: Self.pageURL)!, initialBaseURL: Self.pageURL,
                    parsePage: { _, _ in payload },
                    extractNextURLs: { _, base in
                        let next = (Int(base.split(separator: "p").last ?? "") ?? 0) + 1
                        return next < 4 ? ["\(Self.pageURL)p\(next)"] : []
                    },
                    fetchNextPageHTML: { _ in page }
                )
            }, body.utf8.count * 4)
            add(7, scale, await time {
                ReplaceRuleEngine.apply(rules, to: NSMutableAttributedString(string: plain), from: 0)
            }, plain.utf8.count)
        }
        for (stage, timings) in stages { report(stage, timings) }
    }

    /// A user's ad-filter set: the leading-whitespace rule plus thirty site-signature rules,
    /// half regex and half literal, most of which match nothing — the common case.
    private static func replaceRules() -> [ReplaceRule] {
        var rules = [ReplaceRule(name: "timing.leading", pattern: "^[\\u3000\\s]+")]
        for index in 0..<15 {
            rules.append(ReplaceRule(name: "timing.re\(index)", pattern: "(?:www|m)\\.site\(index)\\.(?:com|net)[^\\n]*"))
            rules.append(ReplaceRule(name: "timing.lit\(index)", pattern: "請收藏本站\(index)", isRegex: false))
        }
        rules.append(ReplaceRule(name: "timing.common", pattern: "俺", replacement: "おれ", isRegex: false))
        return rules
    }
}
