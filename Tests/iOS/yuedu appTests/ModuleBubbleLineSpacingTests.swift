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

    /// Against a 來源配置's own bubble on the same paragraph — the same font, size, line height
    /// and bubble size — a module's bubble claims as much of its line and moves its line as far:
    /// not at all when it fits the line, evenly above and below when it is taller.
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
            for ending in ["。", "。”"] {
                let text = String(repeating: "字", count: 50) + ending
                for scale in [1.0, 1.5, 2.0] {
                    settings.commentBubbleScale = scale
                    for fontSize: CGFloat in [18, 22] {
                        for lineHeightMultiple: CGFloat in [1.3, 1.8] {
                            let renderSettings = ReaderRenderSettings(
                                theme: "test", textColor: .black, backgroundColor: .white,
                                fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, lineSpacing: 0, paragraphSpacing: 10,
                                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                                contentInsets: insets, writingMode: .horizontal)
                            let setup = "\(name.isEmpty ? "system" : name) \(ending) \(fontSize)pt × \(lineHeightMultiple) ×\(scale)"

                            // A 來源配置's own bubble, drawn in the paragraph.
                            let sourced = try await build(
                                html: "<p>\(text)</p><p>\(text)\(sourceMarker)</p><p>\(text)</p><p>\(text)</p>",
                                settings: renderSettings).attributedString
                            // The same chapter without it, and a module's bubble on that paragraph.
                            let built = try await build(html: "<p>\(text)</p><p>\(text)</p><p>\(text)</p><p>\(text)</p>",
                                                        settings: renderSettings).attributedString
                            if !name.isEmpty {
                                let han = (built.string as NSString).range(of: "字").location
                                let font = built.attribute(.font, at: han, effectiveRange: nil) as? UIFont
                                // A Latin face gives its Han characters to the CJK fallback; the
                                // paragraph is still in it, and its punctuation and metrics are.
                                if font?.fontName == name { setInReaderFont.insert(name) }
                            }
                            let display = try await moduleDisplay(html: "<p>\(text)</p><p>\(text)</p><p>\(text)</p><p>\(text)</p>",
                                                                  settings: renderSettings)

                            let source = try #require(measure(sourced, against: built), "\(setup): no source bubble line")
                            let module = try #require(measure(display, against: built), "\(setup): no module bubble line")
                            if module.claim.drawHeight > module.lineHeight, module.above + module.below > 0.5 { grown += 1 }
                            if abs(module.above - source.above) > 0.5 || abs(module.below - source.below) > 0.5 {
                                failures.append("\(setup): the module's bubble moved its line \(module.above)pt from the line above "
                                                + "and \(-module.below)pt from the one below; a source's own, \(source.above)pt and \(-source.below)pt")
                            }
                            if module.claim != source.claim {
                                failures.append("\(setup): the module's bubble claims \(module.claim), a source's own \(source.claim)")
                            }
                            // Either bubble, on a line it fits: the line keeps its place. A
                            // bubble taller than its line grows it as a source's own does (above);
                            // how evenly is `CommentBubbleLineEndTests`'s, in the system font.
                            for (label, moved) in [("module", module), ("source", source)]
                            where moved.claim.drawHeight <= moved.lineHeight && (abs(moved.above) > 0.5 || abs(moved.below) > 0.5) {
                                failures.append("\(setup): a \(label) bubble that fits moved its line \(moved.above)pt above, \(moved.below)pt below")
                            }
                        }
                    }
                }
            }
            if !name.isEmpty { measuredFonts += 1 }
        }
        #expect(measuredFonts > 0 && !setInReaderFont.isEmpty,
                "no reader font other than the system's set the chapter's text: the test no longer reaches the case")
        #expect(grown > 0, "no module bubble grew a line it is taller than: the test no longer reaches `ReviewBubbleLineFit`")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The chapter with a module's bubble on its second paragraph, as the reader's document
    /// store makes it.
    private func moduleDisplay(html: String, settings: ReaderRenderSettings) async throws -> NSAttributedString {
        let store = ChapterDocumentStore(builder: OnlineProviderAttributedStringBuilder(
            provider: ModuleBubbleChapterProvider(html: html), renderSize: page))
        let source = SecondParagraphBubble()
        store.decorationSource = source
        let document = try await store.document(for: ChapterDocumentRequest(
            spineIndex: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white))
        try #require(source.asked, "the store never asked for the chapter's comments")
        return document.attributedString
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

    private func build(html: String, settings: ReaderRenderSettings) async throws -> AttributedChapterBuildResult {
        let builder = OnlineProviderAttributedStringBuilder(provider: ModuleBubbleChapterProvider(html: html), renderSize: page)
        return try await builder.buildChapter(at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
    }
}

private final class ModuleBubbleChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) { self.html = html }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第1章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(index: 0, title: "第1章", plainText: "", body: .html(html), sourceHref: "https://example.com/1")
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
