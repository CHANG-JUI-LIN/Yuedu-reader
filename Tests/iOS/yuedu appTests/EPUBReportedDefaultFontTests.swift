@testable import YueduCoreText
import Combine
import CoreText
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reported EPUB default glyph identity", .serialized)
@MainActor
struct EPUBReportedDefaultFontTests {
    private static let path = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《诡秘之主4》作者：爱潜水的乌贼.epub"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: path)))
    func reportedParagraphUsesItsEmbeddedGlyphs() async throws {
        // Reproduce the reading order from the report: another book already
        // registered a different embedded face with the same PostScript name.
        let redURL = URL(fileURLWithPath: Self.path).deletingLastPathComponent()
            .appendingPathComponent("《红楼梦+大观红楼》人民文学出版.epub")
        let redBytes = try await Self.readFont(redURL,
            href: "OEBPS/Fonts/::*::**::*::*:*****::*:**:*::::**::::***:**:*:::**.ttf")
        _ = try #require(CoreTextFontRegistrationService().registerFont(
            data: redBytes, alias: "previous-book", existingTempURL: nil))
        let bytes = try await Self.readFont(URL(fileURLWithPath: Self.path), href: "OEBPS/Fonts/cc.ttf")
        let target = "原主多年专注读书且有些营养不良，身体素质一直在中等偏下水平。克莱恩加入值夜者后，生活条件变好、开始接受格斗训练后才渐渐改善。"
        // Retain the reported paragraph and its authored font rule while omitting
        // unrelated chapters/images. The font bytes come from the two real EPUBs.
        var entries = EPUBTestFixtures.proseSmoke().entries
        let package = String(decoding: entries["OPS/package.opf"]!, as: UTF8.self)
        entries["OPS/package.opf"] = Data(package.replacingOccurrences(of: "</manifest>", with:
            "<item id='font' href='Fonts/cc.ttf' media-type='font/ttf'/><item id='css' href='Styles/main.css' media-type='text/css'/></manifest>").utf8)
        entries["OPS/Fonts/cc.ttf"] = bytes
        entries["OPS/Styles/main.css"] = Data("""
        @font-face { font-family: "cc"; src: url('../Fonts/cc.ttf'); }
        p.gt1 { font-family: "cc", "黑体", sans-serif; color:#1a2933; font-size:0.85em;
          margin:1em 0.5em; text-indent:2em; font-weight:300; text-align:left; }
        """.utf8)
        entries["OPS/chapter1.xhtml"] = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link href="Styles/main.css" rel="stylesheet" type="text/css"/></head>
        <body><p class="gt1">\(target)</p></body></html>
        """.utf8)
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(entries: entries))
        let spine = 0
        let cgFont = try #require(CGFont(CGDataProvider(data: bytes as CFData)!))
        let source = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil)
        let expectedMap = try #require(CTFontCopyTable(source, CTFontTableTag(kCTFontTableCmap), [])) as Data
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 440, height: 956), settings: EPUBTestFixtures.renderSettings())
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        await engine.preloadChapter(at: spine)
        let layout = try #require(engine.testLayout(for: spine))
        let targetRange = (layout.sourceText as NSString).range(of: target)
        #expect(targetRange.location != NSNotFound)
        let fragments = BrowserLayoutTestSupport.allTextFragments(layout.pages)
            .filter { NSIntersectionRange($0.sourceRange, targetRange).length > 0 }
        #expect(!fragments.isEmpty)
        var names = Set<String>()
        for fragment in fragments {
            let line = try #require(fragment.ctLine)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                names.insert(CTFontCopyPostScriptName(font) as String)
                let actual = CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []).map { $0 as Data }
                #expect(actual == expectedMap, "Unexpected physical font: \(CTFontCopyPostScriptName(font))")
            }
        }
        print("Reported paragraph actual fonts: \(names.sorted()), authored family: \(CTFontCopyFamilyName(source))")
    }
    private static func readFont(_ archiveURL: URL, href: String) async throws -> Data {
        let archive = try await Archive(url: archiveURL, accessMode: .read)
        let entry = try #require(try await archive.get(href))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await archive.extract(entry, to: output)
        return try Data(contentsOf: output)
    }

}
