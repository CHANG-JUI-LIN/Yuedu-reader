@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Feedback #249 (3.0.2 (156)): once a module's 段評 arrived, the line with its bubble stood a
/// little further from the line above. A module's bubble is spliced onto a paragraph the
/// chapter builder already set in the reader's font; it must claim that paragraph's line as a
/// 來源配置's own bubble, drawn inside the paragraph, does.
@Suite("a module's 段評 bubble keeps its line's spacing", .serialized)
@MainActor
struct ModuleBubbleLineSpacingTests {
    private let page = CGSize(width: 393, height: 852)
    private let insets = UIEdgeInsets(top: 70, left: 22, bottom: 50, right: 22)

    /// Reader fonts unlike the system font's metrics, as an imported font is.
    private static let fonts = ["HiraMinProN-W3", "Georgia", "Baskerville", "Didot"]

    private var sourceMarker: String {
        ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="12" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
    }

    /// A module's bubble moves its line as a 來源配置's own bubble on the same paragraph does —
    /// the same font, size, line height and bubble size: not at all when it fits the line, as
    /// much above as below when it is taller (feedback #249: −1pt and 4.6pt in Hiragino Mincho). On
    /// every route a chapter's paragraphs come from: HTML, HTML whose CSS sizes its text, and
    /// plain text (which has no bubbles of its own).
    @Test("a module's bubble sits on its line as a source's own does, in any reader font")
    func moduleBubbleMatchesSourceBubble() async throws {
        let settings = GlobalSettings.shared
        let saved = (settings.selectedReaderFontPostScript, settings.commentBubbleFollowsSourceSVG, settings.commentBubbleScale)
        defer {
            settings.selectedReaderFontPostScript = saved.0
            settings.commentBubbleFollowsSourceSVG = saved.1
            settings.commentBubbleScale = saved.2
        }
        settings.commentBubbleFollowsSourceSVG = false
        var failures: [String] = []
        var grown = 0
        var measuredFonts = 0
        var setInReaderFont: Set<String> = []
        for name in [""] + Self.fonts {
            guard name.isEmpty || UIFont(name: name, size: 18) != nil else { continue }
            settings.selectedReaderFontPostScript = name
            // A full stop the CJK pass raises in its em box, a curly quote it may set in another
            // face, and none: the text's own raise alone.
            for ending in ["。", "。”", ""] {
                let text = String(repeating: "字", count: 51) + ending
                for scale in [1.0, 1.5, 2.0] {
                    settings.commentBubbleScale = scale
                    for fontSize: CGFloat in [18, 22] {
                        for lineHeightMultiple: CGFloat in [1.3, 1.8] {
                            let renderSettings = ReaderRenderSettings(
                                theme: "test", textColor: .black, backgroundColor: .white,
                                fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, lineSpacing: 0, paragraphSpacing: 10,
                                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                                contentInsets: insets, writingMode: .horizontal)
                            for route in Route.allCases {
                                let setup = "\(route) \(name.isEmpty ? "system" : name) \(ending) \(fontSize)pt × \(lineHeightMultiple) ×\(scale)"
                                // The chapter without a bubble, and with a module's on its second paragraph.
                                let plain = route.body(text, marker: nil)
                                let built = try await build(body: plain, settings: renderSettings).attributedString
                                if !name.isEmpty {
                                    let han = (built.string as NSString).range(of: "字").location
                                    let font = built.attribute(.font, at: han, effectiveRange: nil) as? UIFont
                                    // A Latin face gives its Han characters to the CJK fallback; the
                                    // paragraph is still in it, and its punctuation and metrics are.
                                    if font?.fontName == name { setInReaderFont.insert(name) }
                                }
                                let display = try await moduleDisplay(body: plain, settings: renderSettings)
                                let module = try #require(measure(display, against: built), "\(setup): no module bubble line")
                                if module.claim.drawHeight > module.lineHeight { grown += 1 }
                                var moved = [("module", module)]

                                // A 來源配置's own bubble, drawn in the paragraph, where a source can have one.
                                if let sourcedBody = route.sourced(text, marker: sourceMarker) {
                                    let sourced = try await build(body: sourcedBody, settings: renderSettings).attributedString
                                    let source = try #require(measure(sourced, against: built), "\(setup): no source bubble line")
                                    moved.append(("source", source))
                                    if module.claim.drawHeight <= module.lineHeight,
                                       abs(module.above - source.above) > 0.5 || abs(module.below - source.below) > 0.5 {
                                        failures.append("\(setup): the module's bubble moved its line \(module.above)pt from the line above "
                                                        + "and \(-module.below)pt from the one below; a source's own, \(source.above)pt and \(-source.below)pt")
                                    }
                                }
                                // Either bubble: a line it fits keeps its place; a line it is taller
                                // than grows as much above as below (origins are whole points, so
                                // within 1pt), by at least as much as the bubble is taller.
                                for (label, step) in moved {
                                    if step.claim.drawHeight <= step.lineHeight {
                                        if abs(step.above) > 0.5 || abs(step.below) > 0.5 {
                                            failures.append("\(setup): a \(label) bubble that fits moved its line \(step.above)pt above, \(step.below)pt below")
                                        }
                                    } else if abs(step.above - step.below) > 1
                                                || step.above + step.below < step.claim.drawHeight - step.lineHeight - 0.5 {
                                        failures.append("\(setup): a \(label) bubble \(step.claim.drawHeight)pt tall grew its \(step.lineHeight)pt line "
                                                        + "\(step.above)pt above and \(step.below)pt below")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !name.isEmpty { measuredFonts += 1 }
        }
        #expect(measuredFonts > 0 && !setInReaderFont.isEmpty,
                "no reader font other than the system's set the chapter's text: the test no longer reaches the case")
        #expect(grown > 0, "no module bubble was taller than its line: the test no longer reaches `ReviewBubbleLineFit`")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The chapter with a module's bubble on its second paragraph, as the reader's document
    /// store makes it.
    private func moduleDisplay(body: ChapterRenderBody, settings: ReaderRenderSettings) async throws -> NSAttributedString {
        let store = ChapterDocumentStore(builder: OnlineProviderAttributedStringBuilder(
            provider: ModuleBubbleChapterProvider(body: body), renderSize: page))
        let source = SecondParagraphBubble()
        store.decorationSource = source
        let document = try await store.document(for: ChapterDocumentRequest(
            spineIndex: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white))
        try #require(source.asked, "the store never asked for the chapter's comments")
        return document.attributedString
    }

    /// Where a chapter's paragraphs come from.
    private enum Route: String, CaseIterable, CustomStringConvertible {
        case html, sizedHTML, plainText
        var description: String { rawValue }

        /// Four paragraphs of `text`, `marker` at the end of the second.
        func body(_ text: String, marker: String?) -> ChapterRenderBody {
            let second = text + (marker ?? "")
            switch self {
            case .html: return .html("<p>\(text)</p><p>\(second)</p><p>\(text)</p><p>\(text)</p>")
            case .sizedHTML:
                let p = #"<p style="font-size: 1.25em">"#
                return .html("\(p)\(text)</p>\(p)\(second)</p>\(p)\(text)</p>\(p)\(text)</p>")
            case .plainText: return .plainText([text, second, text, text].joined(separator: "\n"))
            }
        }

        func sourced(_ text: String, marker: String) -> ChapterRenderBody? {
            self == .plainText ? nil : body(text, marker: marker)
        }
    }

    private struct Claim: Equatable, CustomStringConvertible {
        var ascent: CGFloat, descent: CGFloat, drawHeight: CGFloat, baselineOffset: CGFloat
        var description: String { "ascent \(ascent) descent \(descent) height \(drawHeight) raised \(baselineOffset)" }
    }

    /// What the bubble in `attributed` claims, and how far it moved its line: the steps from
    /// the line above to the bubble's line and from it to the next paragraph's first, less the
    /// same steps in `plain`, the same chapter without the bubble.
    private func measure(_ attributed: NSAttributedString, against plain: NSAttributedString)
        -> (above: CGFloat, below: CGFloat, lineStep: CGFloat, lineHeight: CGFloat, claim: Claim)? {
        let bubble = (attributed.string as NSString).range(of: "\u{FFFC}").location
        guard bubble != NSNotFound,
              let delegate = attributed.attribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                                                  at: bubble, effectiveRange: nil) else { return nil }
        let info = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(delegate as! CTRunDelegate)).takeUnretainedValue()
        let raised = (attributed.attribute(.baselineOffset, at: bubble, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        func rounded(_ value: CGFloat) -> CGFloat { (value * 100).rounded() / 100 }
        let claim = Claim(ascent: rounded(info.ascent), descent: rounded(info.descent),
                          drawHeight: rounded(info.drawHeight), baselineOffset: rounded(raised))
        let laid = lines(of: attributed), bare = lines(of: plain)
        guard let line = laid.lines.firstIndex(where: {
            let range = CTLineGetStringRange($0)
            return bubble >= range.location && bubble < range.location + range.length
        }), line > 0, line + 1 < laid.lines.count, laid.lines.count == bare.lines.count else { return nil }
        let o = laid.origins, p = bare.origins
        return ((o[line - 1].y - o[line].y) - (p[line - 1].y - p[line].y),
                (o[line].y - o[line + 1].y) - (p[line].y - p[line + 1].y),
                p[line - 1].y - p[line].y,
                (plain.attribute(.paragraphStyle, at: min(bubble, plain.length - 1), effectiveRange: nil) as? NSParagraphStyle)?
                    .maximumLineHeight ?? 0,
                claim)
    }

    private func lines(of attributed: NSAttributedString) -> (lines: [CTLine], origins: [CGPoint]) {
        let width = page.width - insets.left - insets.right
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let tall = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), tall, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return (lines, origins)
    }

    private func build(body: ChapterRenderBody, settings: ReaderRenderSettings) async throws -> AttributedChapterBuildResult {
        let builder = OnlineProviderAttributedStringBuilder(provider: ModuleBubbleChapterProvider(body: body), renderSize: page)
        return try await builder.buildChapter(at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
    }
}

private final class ModuleBubbleChapterProvider: BookContentProvider {
    private let body: ChapterRenderBody

    init(body: ChapterRenderBody) { self.body = body }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第1章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(index: 0, title: "第1章", plainText: "", body: body, sourceHref: "https://example.com/1")
    }
}

/// A module with one 段評 count, on the chapter's second body paragraph.
@MainActor
private final class SecondParagraphBubble: ReaderChapterDecorationSource {
    var asked = false

    func placements(forSpine spineIndex: Int, title: String, paragraphs: [String]) -> ReaderCommentPlacements? {
        asked = true
        let bodies = paragraphs.indices.filter { paragraphs[$0].contains("字") }
        guard bodies.count > 1 else { return nil }
        var placements = ReaderCommentPlacements()
        placements.bubbles[bodies[1]] = .init(count: 12, href: "ydreview://module?d=1", title: "段評")
        return placements
    }
}
