@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Legacy scroll slicing must never emit a chunk whose frame lays out nothing: the painter
/// draws a chunk from its frame's lines, so a zero-line chunk is a blank band where the
/// chapter's content (here, an image) should be. Both chapters below were caught by the
/// render-fidelity harness under its neutral profile (17pt, line-height 1.5, no paragraph
/// spacing, 366pt content width).
@Suite("Chunk slicer keeps image-only lines", .serialized)
@MainActor
struct CoreTextChunkSlicerImageLineTests {
    nonisolated static let directory = "/Users/zhangruilin/Desktop/Test document/EPUB Format"
    nonisolated static let glossary = directory + "/AI术语词典-第一册.epub"
    nonisolated static let theDeal = directory + "/The Deal (Off-Campus, Book 1) (Elle Kennedy) (z-library.sk, 1lib.sk, z-lib.sk).epub"

    static let screen = CGSize(width: 390, height: 800)

    /// The fidelity harness's neutral profile: 17pt, line-height 1.5, everything else 0.
    static let fidelity = settings(fontSize: 17, lineHeight: 1.5, lineSpacing: 0, paragraphSpacing: 0, margin: 12)

    /// The app's own defaults (`GlobalSettings.defaultReader*`): 18pt, 1.65, paragraph
    /// spacing 0.8em, horizontal margin 24; line spacing derived as `ReaderSettings.lineSpacing` does.
    static let appDefaults = settings(fontSize: 18, lineHeight: 1.65, lineSpacing: (1.65 - 1) * 18,
                                      paragraphSpacing: 18 * 0.8, margin: 24)

    static func settings(fontSize: CGFloat, lineHeight: CGFloat, lineSpacing: CGFloat,
                         paragraphSpacing: CGFloat, margin: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "slicer", textColor: .black, backgroundColor: .white,
            fontSize: fontSize, lineHeightMultiple: lineHeight, lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing, letterSpacing: 0,
            marginH: margin, marginV: margin, footerHeight: ReaderLayoutMetrics.footerHeight,
            contentInsets: UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin))
    }

    static func chunks(epub: String, spine: Int, settings: ReaderRenderSettings)
        async throws -> (chunks: [CoreTextChunk], attributed: NSAttributedString, imagePage: Bool) {
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: epub))
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: screen)
        let result = try await builder.buildChapter(
            at: spine, settings: settings,
            themeTextColor: settings.textColor, themeBackgroundColor: settings.backgroundColor)
        let output = CoreTextChunkSlicer.slice(
            attributedString: result.attributedString, chapterIndex: spine,
            contentWidth: screen.width - 2 * settings.marginH, pageBackgroundImage: result.pageBackgroundImage,
            minimumBackdropExtent: screen.height)
        return (output.chunks, result.attributedString, result.imagePage != nil)
    }

    /// Every chunk shows what it holds: either its frame laid out at least one line, or it
    /// is an image-only chunk that carries its attachment.
    static func assertEveryChunkDraws(_ chunks: [CoreTextChunk], _ label: String) {
        #expect(!chunks.isEmpty, "\(label): no chunks")
        for (index, chunk) in chunks.enumerated() {
            chunk.materializeFrameIfNeeded()
            if chunk.isImageOnly {
                #expect(!chunk.attachments.isEmpty, "\(label) chunk \(index): image-only without attachment")
                continue
            }
            let lines = chunk.frame.map { (CTFrameGetLines($0) as! [CTLine]).count } ?? 0
            #expect(lines > 0,
                    "\(label) chunk \(index) range=\(chunk.charRange.location)+\(chunk.charRange.length) height=\(chunk.height) lays out 0 lines: \(lines == 0 ? diagnose(chunk) : "")")
        }
    }

    /// What the zero-line chunk's range needs: the same range laid out in an unbounded box.
    static func diagnose(_ chunk: CoreTextChunk) -> String {
        let attr = chunk.attributedString
        let range = chunk.charRange
        var fit = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            chunk.framesetter, range, nil, CGSize(width: chunk.width, height: .greatestFiniteMagnitude), &fit)
        let tall: CGFloat = 100_000
        let frame = CTFramesetterCreateFrame(
            chunk.framesetter, range, CGPath(rect: CGRect(x: 0, y: 0, width: chunk.width, height: tall), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        var text = "suggested=\(suggested) fit=\(fit.length)"
        for (i, line) in lines.enumerated() {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &a, &d, &l)
            text += " | line\(i) top=\(tall - origins[i].y) asc=\(a) desc=\(d) lead=\(l) range=\(CTLineGetStringRange(line))"
        }
        let sub = attr.attributedSubstring(from: NSRange(location: range.location, length: range.length))
        sub.enumerateAttributes(in: NSRange(location: 0, length: sub.length)) { attrs, r, _ in
            let p = attrs[.paragraphStyle] as? NSParagraphStyle
            text += " | attrs@\(r) lhm=\(p?.lineHeightMultiple ?? -1) min=\(p?.minimumLineHeight ?? -1) max=\(p?.maximumLineHeight ?? -1) before=\(p?.paragraphSpacingBefore ?? -1) after=\(p?.paragraphSpacing ?? -1) ls=\(p?.lineSpacing ?? -1) font=\((attrs[.font] as? UIFont)?.pointSize ?? -1)"
            if let delegate = attrs[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] {
                let info = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(delegate as! CTRunDelegate)).takeUnretainedValue()
                text += " image drawH=\(info.drawHeight) h=\(info.height) asc=\(info.ascent) desc=\(info.descent) mode=\(info.displayMode)"
            }
        }
        return text
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: glossary)))
    func glossaryCoverChunkDraws() async throws {
        let built = try await Self.chunks(epub: Self.glossary, spine: 0, settings: Self.fidelity)
        Self.assertEveryChunkDraws(built.chunks, "glossary/0")
        // The cover image itself must reach the painter.
        #expect(built.chunks.contains { !$0.attachments.isEmpty }, "glossary/0: cover image missing")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: theDeal)))
    func theDealLastImageChunkDraws() async throws {
        let built = try await Self.chunks(epub: Self.theDeal, spine: 50, settings: Self.fidelity)
        Self.assertEveryChunkDraws(built.chunks, "the-deal/50")
        let last = try #require(built.chunks.last)
        #expect(!last.attachments.isEmpty, "the-deal/50: final image missing")
    }

    /// The app's own defaults (18pt, 1.65, paragraph spacing 0.8em).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: glossary) && FileManager.default.fileExists(atPath: theDeal)))
    func appDefaultsChunksDraw() async throws {
        let defaults = Self.appDefaults
        let glossary = try await Self.chunks(epub: Self.glossary, spine: 0, settings: defaults)
        Self.assertEveryChunkDraws(glossary.chunks, "defaults glossary/0")
        let deal = try await Self.chunks(epub: Self.theDeal, spine: 50, settings: defaults)
        Self.assertEveryChunkDraws(deal.chunks, "defaults the-deal/50")
    }

    // MARK: - Vertical (vertical-rl) slicing

    /// A block image's paragraph is pinned to `ceil(ascent + descent)`
    /// (`NodeAttributedStringRenderer.imageBlockParagraphStyle`), and Core Text answers that
    /// with a negative line descent. Vertical slicing must still lay the image column out,
    /// and its terminal chunk must still compact to the columns it uses rather than stay
    /// `heightCap` wide.
    static func verticalImageParagraph(drawHeight: CGFloat, fontSize: CGFloat) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(drawHeight)
        paragraph.maximumLineHeight = ceil(drawHeight)
        let result = NSMutableAttributedString(attributedString: RunDelegateProvider.makeImagePlaceholder(
            image: UIImage(), font: font, textColor: .black,
            totalWidth: 200, drawWidth: 200, drawHeight: drawHeight,
            ascent: drawHeight, descent: 0, paddingLeft: 0, paddingRight: 0,
            imageSource: "image.png", displayMode: .block, opacity: 1))
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    @Test func verticalPinnedImageColumnDrawsAndCompacts() {
        let heightCap = CoreTextChunkSlicer.defaultHeightCap
        var failures: [String] = []
        // Fractional draw heights are what the builder produces from scaled images; step
        // through enough of them to hit every rounding the pinned line height can take.
        for step in 0..<200 {
            let drawHeight = 100 + CGFloat(step) * 2.37
            let attr = Self.verticalImageParagraph(drawHeight: drawHeight, fontSize: 17)
            let output = CoreTextChunkSlicer.slice(
                attributedString: attr, chapterIndex: 0, contentWidth: 776,
                heightCap: heightCap, writingMode: .verticalRTL)
            for (index, chunk) in output.chunks.enumerated() {
                let lines = chunk.frame.map { CTFrameGetLines($0) as! [CTLine] } ?? []
                guard let line = lines.first else {
                    failures.append("drawHeight=\(drawHeight) chunk \(index): 0 columns")
                    continue
                }
                var descent: CGFloat = 0
                let ascent = CTLineGetTypographicBounds(line, nil, &descent, nil)
                if chunk.width >= heightCap {
                    failures.append("drawHeight=\(drawHeight) chunk \(index): width \(chunk.width) not compacted (line ascent=\(ascent) descent=\(descent))")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) cases:\n\(failures.prefix(20).joined(separator: "\n"))")
    }
}
