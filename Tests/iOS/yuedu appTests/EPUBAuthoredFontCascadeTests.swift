@testable import YueduCoreText
import Combine
import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("EPUB authored font cascades", .serialized)
@MainActor
struct EPUBAuthoredFontCascadeTests {
    @Test func repeatedFallbackPreparationPreservesAuthoredOrder() throws {
        let primary = try #require(UIFont(name: "Georgia", size: 24))
        let authored = UIFontDescriptor(name: "Courier", size: 24)
        var font = UIFont(descriptor: primary.fontDescriptor.addingAttributes([
            .cascadeList: [authored]
        ]), size: 24)
        for _ in 0..<3 { font = ReaderFontCascade.preservingPrimary(font, size: 24) }
        let cascade = try #require(font.fontDescriptor.object(forKey: .cascadeList) as? [UIFontDescriptor])
        #expect(cascade.first?.postscriptName == authored.postscriptName)
        #expect(cascade.filter { $0.postscriptName == authored.postscriptName }.count == 1)
    }

    @Test func missingGlyphUsesNextCSSFamilyInLegacyPagedAndScrollAfterRestoringDefault() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let package = String(decoding: entries["OPS/package.opf"]!, as: UTF8.self)
        entries["OPS/package.opf"] = Data(package.replacingOccurrences(of: "</manifest>", with:
            "<item id='primary-font' href='Fonts/primary.ttf' media-type='font/ttf'/><item id='fonts-css' href='Styles/fonts.css' media-type='text/css'/></manifest>").utf8)
        entries["OPS/Fonts/primary.ttf"] = try Data(contentsOf: fontURL)
        entries["OPS/Styles/fonts.css"] = Data("""
        @font-face { font-family: BookSubset; src: url('../Fonts/primary.ttf'); }
        p { font-family: BookSubset, TimesNewRomanPSMT; font-size: 24px; }
        """.utf8)
        entries["OPS/chapter1.xhtml"] = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link href="Styles/fonts.css" rel="stylesheet" type="text/css"/>
        </head><body><p>AЖ</p></body></html>
        """.utf8)
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(entries: entries))
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
        var settings = EPUBTestFixtures.renderSettings()
        // Inspect physical glyph runs, not only the paragraph's declared font.
        for selected: String? in [nil, "Georgia", nil] {
            settings.fontPostScriptName = selected
            let legacy = try await builder.buildChapter(at: 0, settings: settings,
                themeTextColor: .black, themeBackgroundColor: .white)
            let renderer = EPUBPageRenderer()
            renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                renderSize: CGSize(width: 320, height: 480), settings: settings)
            for await ready in renderer.$isCoreTextReady.values where ready { break }
            let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
            #expect(engine.choice(for: 0)?.isBrowser == true)
            let paged = try #require(engine.testLayout(for: 0))
            let scroll = try #require(renderer.scrollEngine)
            await scroll.start(initialChapter: 0, contentWidth: 320, viewportExtent: 480,
                loadAdjacentChapters: false)
            guard case .browser(let tile) = try #require(scroll.chunks.first) else {
                Issue.record("Expected Browser scroll"); return
            }
            let lists = [paged.displayList(forPage: 0, themeTextColor: .black,
                oldThemeColor: paged.themeTextColor), tile.chapter.document.displayList]
            var outputs = [legacy.attributedString]
            for list in lists {
                let text = NSMutableAttributedString(string: "")
                for item in list.items {
                    if case .text(let fragment) = item { text.append(fragment.attributedText) }
                }
                outputs.append(text)
            }
            for output in outputs {
                let range = (output.string as NSString).range(of: "AЖ")
                #expect(range.location != NSNotFound)
                let line = CTLineCreateWithAttributedString(output.attributedSubstring(from: range))
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                let names = runs.map { run in
                    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    return CTFontCopyPostScriptName(font) as String
                }
                if let selected {
                    #expect(names.allSatisfy { $0 == selected }, "Actual glyph fonts: \(names)")
                } else {
                    #expect(names == ["Ahem", "TimesNewRomanPSMT"], "Actual glyph fonts: \(names)")
                }
            }
        }
    }
}
