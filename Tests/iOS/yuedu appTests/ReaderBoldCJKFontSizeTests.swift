@testable import YueduCoreText
import Testing
import CoreText
import Foundation
import UIKit
@testable import yuedu_app

/// 粗體 must not change how big the text is drawn.
///
/// The reader's font cascade used to hand CoreText fallback descriptors built with
/// `size: 0` ("inherit the primary's size"). That inherits only while CoreText can
/// use the descriptor as written; with a bold primary it re-matches each fallback
/// against the bold trait, and the re-matched descriptor keeps the literal `0`,
/// which resolves to CoreText's 12pt default. Latin glyphs came from the primary
/// font and stayed at the reader size, so switching 粗體 on shrank only the CJK
/// text — from 20pt to 12pt.
struct ReaderBoldCJKFontSizeTests {

    private static let sample = "第一段中文測試 Latin ABC 123"

    private func settings(isBold: Bool, fontSize: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal,
            fontPostScriptName: nil,
            isBold: isBold
        )
    }

    /// Point size CoreText actually shapes `character` at, after cascade fallback.
    private func shapedSize(
        of character: Character,
        in attributed: NSAttributedString
    ) -> CGFloat? {
        let offset = (attributed.string as NSString).range(of: String(character)).location
        guard offset != NSNotFound else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            guard offset >= range.location, offset < range.location + range.length else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName] else { return nil }
            return CTFontGetSize(fontValue as! CTFont)
        }
        return nil
    }

    @Test(arguments: [false, true])
    @MainActor func boldKeepsCJKAtTheReaderFontSize(isBold: Bool) async throws {
        let fontSize: CGFloat = 20
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings(isBold: isBold, fontSize: fontSize),
                textColor: .black,
                baseFontSize: fontSize,
                renderWidth: 320
            )
        )
        let rendered = await renderer.render([
            .paragraph([.text(Self.sample)], style: RenderStyle())
        ])

        let cjkSize = try #require(shapedSize(of: "測", in: rendered))
        let latinSize = try #require(shapedSize(of: "A", in: rendered))
        #expect(cjkSize == fontSize)
        #expect(latinSize == fontSize)
    }

    /// The cascade itself, without the renderer around it: a bold primary must still
    /// draw its CJK fallback at the requested size.
    @Test(arguments: [false, true])
    func cascadeFallbackKeepsRequestedSize(isBold: Bool) throws {
        let size: CGFloat = 20
        let primary = UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
        let cascaded = ReaderFontCascade.preservingPrimary(primary, size: size)
        let attributed = NSAttributedString(string: "測", attributes: [.font: cascaded])
        let line = CTLineCreateWithAttributedString(attributed)
        let run = try #require((CTLineGetGlyphRuns(line) as! [CTRun]).first)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let font = try #require(attributes[kCTFontAttributeName]) as! CTFont
        #expect(CTFontGetSize(font) == size)
    }
}
