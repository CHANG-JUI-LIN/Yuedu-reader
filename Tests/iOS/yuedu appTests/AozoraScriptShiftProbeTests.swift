import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// 上付き, 下付き, 返り点, 訓点送り仮名 and 割り注 in legacy (Aozora plan, Tasks 11, 13 and 14).
/// `vertical-align: super` and `sub` raise and lower a run by its parent's size, whatever its own,
/// as WebKit and BrowserAuto move it (`VerticalAlignShift`, pinned against WebKit by
/// YueduCoreText's `ScriptShiftReferenceTests`). In vertical writing, raised text sits right of the
/// column's central line and lowered text left of it.
@Suite("Aozora script shifts in legacy", .serialized)
@MainActor
struct AozoraScriptShiftProbeTests {
    static let source = """
        題
        著者

        学［＃（ビテ）］而時習［＃レ］之。
        x2［＃「2」は上付き小文字］とx2［＃「2」は下付き小文字］。
        本文［＃割り注］注釈の文［＃割り注終わり］本文。

        """

    /// The converter's markup and stylesheet, read by legacy: each run's size and its baseline's
    /// shift from the paragraph's.
    @Test(arguments: LegacyTextEmphasisDecorationTests.modes)
    func theConvertersScriptsShiftInLegacy(mode: ReaderWritingMode) async throws {
        let document = AozoraDocumentParser.parse(Self.source)
        let chapters = AozoraChapterPlanner.plan(document, source: Self.source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-scripts-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: [:],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue,
                                              length: Self.source.utf16.count),
            identifier: "urn:uuid:aozora-scripts", to: url)
        let spine = try #require(chapters.firstIndex { $0.text.contains("学ビテ") })
        let session = try await PublicationSession.open(sourceURL: url)
        let built = try await EPUBAttributedStringBuilder(session: session, renderSize: LegacyTextEmphasisDecorationTests.pageSize)
            .buildChapter(at: spine, settings: EPUBTestFixtures.renderSettings(fontSize: 17, writingMode: mode),
                          themeTextColor: .black, themeBackgroundColor: .white)
        let string = built.attributedString
        let text = string.string as NSString

        func run(_ needle: String, after anchor: Int = 0) throws -> (index: Int, size: CGFloat, offset: CGFloat) {
            let found = text.range(of: needle, range: NSRange(location: anchor, length: text.length - anchor))
            try #require(found.location != NSNotFound, "\(needle)")
            let font = try #require(string.attribute(.font, at: found.location, effectiveRange: nil) as? UIFont)
            let offset = (string.attribute(.baselineOffset, at: found.location, effectiveRange: nil) as? NSNumber)
                .map { CGFloat($0.doubleValue) } ?? 0
            return (found.location, font.pointSize, offset)
        }
        let place = "\(mode)"
        let base = try run("学")
        let parent = base.size
        let raised = VerticalAlignShift.superscript(parentFontSize: parent)
        let lowered = VerticalAlignShift.subscript(parentFontSize: parent)

        let okurigana = try run("ビ", after: base.index)
        #expect(abs(okurigana.size - parent / 2) < 0.01, "\(place) 送り仮名 size \(okurigana.size)")
        #expect(abs(okurigana.offset - base.offset - raised) < 0.01, "\(place) 送り仮名 shift \(okurigana.offset - base.offset)")
        let kaeriten = try run("レ", after: okurigana.index)
        #expect(abs(kaeriten.size - parent / 2) < 0.01, "\(place) 返り点 size \(kaeriten.size)")
        #expect(abs(kaeriten.offset - base.offset + lowered) < 0.01, "\(place) 返り点 shift \(kaeriten.offset - base.offset)")
        #expect(try run("之", after: kaeriten.index).offset == base.offset, "\(place) back on the baseline")

        let line = try run("x", after: kaeriten.index)
        let superscript = try run("2", after: line.index)
        #expect(abs(superscript.offset - line.offset - raised) < 0.01, "\(place) 上付き shift \(superscript.offset - line.offset)")
        let subscriptLine = try run("x", after: superscript.index)
        let `subscript` = try run("2", after: subscriptLine.index)
        #expect(abs(`subscript`.offset - line.offset + lowered) < 0.01, "\(place) 下付き shift \(`subscript`.offset - line.offset)")

        let warichu = try run("（注", after: `subscript`.index)
        #expect(abs(warichu.size - parent / 2) < 0.01, "\(place) 割り注 size \(warichu.size)")
        #expect(warichu.offset == line.offset, "\(place) 割り注 stays on the baseline")
    }

    /// 送り仮名 in red and 返り点 in blue, against the same text with `vertical-align: baseline`:
    /// the red ink moves up (right of a vertical line) by the raise, the blue down (left) by the
    /// drop, in paged and scroll pages.
    @Test(arguments: LegacyTextEmphasisDecorationTests.modes, [false, true])
    func raisedAndLoweredInkMovesAcrossTheLine(mode: ReaderWritingMode, scroll: Bool) async throws {
        let vertical = mode.isVertical
        let body = #"<p>学<sup class="okurigana">ビテ</sup>而時習<sub class="kaeriten">レ</sub>之</p>"#
        let css = """
            .kaeriten { font-size: 0.5em; vertical-align: sub; color: blue; }
            .okurigana { font-size: 0.5em; vertical-align: super; color: red; }
            """
        let flat = css.replacingOccurrences(of: "vertical-align: sub", with: "vertical-align: baseline")
            .replacingOccurrences(of: "vertical-align: super", with: "vertical-align: baseline")
        typealias Pixels = LegacyTextEmphasisDecorationTests.Pixels
        let shifted = try LegacyTextEmphasisDecorationTests.render(
            try await LegacyTextEmphasisDecorationTests.layout(body, mode: mode, css: css), scroll: scroll)
        let reference = try LegacyTextEmphasisDecorationTests.render(
            try await LegacyTextEmphasisDecorationTests.layout(body, mode: mode, css: flat), scroll: scroll)

        /// The centre of `kind`'s ink across the line, in points toward the page's top
        /// (horizontal) or its right (vertical).
        func across(_ pixels: Pixels, _ kind: ((Int, Int, Int)) -> Bool) throws -> CGFloat {
            let blobs = pixels.blobs(kind)
            try #require(!blobs.isEmpty)
            let low = blobs.map { vertical ? $0.minX : -$0.maxY }.min()!
            let high = blobs.map { vertical ? $0.maxX : -$0.minY }.max()!
            return CGFloat(low + high) / 2 / LegacyTextEmphasisDecorationTests.scale
        }
        let parent: CGFloat = 17
        let place = "\(mode) \(scroll ? "scroll" : "paged")"
        let text = try across(shifted, Pixels.black) - across(reference, Pixels.black)
        let red = try across(shifted, Pixels.red) - across(reference, Pixels.red) - text
        let blue = try across(shifted, Pixels.blue) - across(reference, Pixels.blue) - text
        print("SCRIPT_INK \(place) text \(text) okurigana \(red) kaeriten \(blue)")
        // A pixel at 3× either way, for each of the two edges.
        #expect(abs(red - VerticalAlignShift.superscript(parentFontSize: parent)) <= 0.7, "\(place) 送り仮名 moved \(red)")
        #expect(abs(blue + VerticalAlignShift.subscript(parentFontSize: parent)) <= 0.7, "\(place) 返り点 moved \(blue)")
    }
}
