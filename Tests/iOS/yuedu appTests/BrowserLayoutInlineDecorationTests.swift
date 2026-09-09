import CoreText
import Testing
import UIKit
@testable import yuedu_app

@MainActor
@Suite(.serialized)
struct BrowserLayoutInlineDecorationTests {
    private let css = "body, p { margin: 0; font-size: 20px; line-height: 30px; } .label { background-color: #800080; color: white; padding: 4px 12px; }"

    @Test func galleryTitlePaintsPurpleBehindWhiteGlyphs() async throws {
        let result = try await BrowserLayoutTestSupport.layout("<p><span class='label'>紅樓夢畫冊</span></p>", cssTexts: [css])
        let text = try #require(BrowserLayoutTestSupport.allTextFragments(result.pages).first)
        let fill = try #require(fills(result.pages).first { $0.color.isEqual(UIColor(red: 128 / 255, green: 0, blue: 128 / 255, alpha: 1)) })
        #expect(abs(text.rect.minX - fill.rect.minX - 12) < 0.001)
        #expect(abs(fill.rect.maxX - text.rect.maxX - 12) < 0.001)
        #expect(isWhite(text.color))
        let list = DisplayListBuilder.build(for: result.pages[0], sourceText: result.doc.lastSourceText)
        let image = DisplayListRenderer.render(list, size: CGSize(width: 300, height: 400))
        let pixels = try pixelCounts(image, inside: fill.rect.rawValue)
        #expect(pixels.purple > 100)
        let ink = try pixelCounts(image, inside: text.rect.rawValue.intersection(fill.rect.rawValue).insetBy(dx: 1, dy: 1))
        #expect(ink.white > 20)
    }

    @Test func authoredGalleryTitleRetainsSixSeparateBadges() async throws {
        let html = "<div class='heading'><b>红</b> <b>楼</b> <b>梦</b> <b>画</b> <b>册</b> <b>壹</b></div>"
        let style = "body { margin: 0 } .heading { font-size: 105%; color: #fff; text-align: center; width: 10em; padding-bottom: 5px; border-bottom: 1px solid #5f52a0 } .heading b { background-color: #5f52a0; padding: 3px 3px 1px 3px; font-weight: bold }"
        let result = try await BrowserLayoutTestSupport.layout(html, cssTexts: [style])
        let badges = fills(result.pages).filter { $0.color != .clear }
        #expect(badges.count == 6)
        let source = result.doc.lastSourceText as NSString
        let glyphs = BrowserLayoutTestSupport.allTextFragments(result.pages).filter {
            !source.substring(with: $0.sourceRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(glyphs.count == 6)
        for (badge, glyph) in zip(badges, glyphs) {
            #expect(abs(glyph.rect.minX - badge.rect.minX - 3) < 0.001)
            #expect(abs(badge.rect.maxX - glyph.rect.maxX - 3) < 0.001)
            #expect(isWhite(glyph.color))
        }
        #expect(result.doc.lastSourceText == "红 楼 梦 画 册 壹")
    }

    @Test func nestedDecorationRetainsSourceAndPadding() async throws {
        let result = try await BrowserLayoutTestSupport.layout("<p>前<span class='label'>甲<strong>乙😀</strong>丙</span>後</p>", cssTexts: [css])
        let text = BrowserLayoutTestSupport.allTextFragments(result.pages)
        #expect(result.doc.lastSourceText == "前甲乙😀丙後")
        #expect(BrowserLayoutTestSupport.visibleText(result.pages, sourceText: result.doc.lastSourceText) == "前甲乙😀丙後")
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(result.pages))
        let fill = try #require(fills(result.pages).first { $0.color.isEqual(UIColor(red: 128 / 255, green: 0, blue: 128 / 255, alpha: 1)) })
        let first = try #require(text.first { $0.sourceRange.location == 1 })
        let last = try #require(text.first { $0.sourceRange.location == 5 })
        #expect(abs(first.rect.minX - fill.rect.minX - 12) < 0.001)
        #expect(abs(fill.rect.maxX - last.rect.maxX - 12) < 0.001)
        #expect(fills(result.pages).filter { $0.color.isEqual(UIColor(red: 128 / 255, green: 0, blue: 128 / 255, alpha: 1)) }.count == 1)
        let lineOriginX = try #require(text.first).rect.minX
        for fragment in text {
            let line = try #require(fragment.ctLine)
            if case .linear(let range) = fragment.sourceMapping {
                #expect(range.length == fragment.sourceRange.length)
                #expect(range.location >= CTLineGetStringRange(line).location)
                let offset = CTLineGetOffsetForStringIndex(line, range.location, nil)
                #expect(abs(fragment.rect.minX - lineOriginX - offset) < 0.001)
            }
        }
    }

    @Test func nestedBackgroundsPaintInAncestorOrder() async throws {
        let result = try await BrowserLayoutTestSupport.layout(
            "<p><span class='label'>甲<span style='background-color: #008000; padding: 2px 3px'>乙</span>丙</span></p>", cssTexts: [css]
        )
        let decoration = fills(result.pages)
        #expect(decoration.count == 2)
        let outer = try #require(decoration.first)
        let inner = try #require(decoration.last)
        #expect(outer.rect.minX < inner.rect.minX)
        #expect(outer.rect.maxX > inner.rect.maxX)
        let text = try #require(BrowserLayoutTestSupport.allTextFragments(result.pages).first { $0.sourceRange.location == 1 })
        #expect(abs(text.rect.minX - inner.rect.minX - 3) < 0.001)
        #expect(abs(inner.rect.maxX - text.rect.maxX - 3) < 0.001)
        #expect(BrowserLayoutTestSupport.visibleText(result.pages, sourceText: result.doc.lastSourceText) == "甲乙丙")
    }

    @Test func decorationFollowsWrappedLinesAcrossPages() async throws {
        let content = String(repeating: "紅樓夢畫冊", count: 12)
        let result = try await BrowserLayoutTestSupport.layout("<p>開始</p><p><span class='label'>\(content)</span></p>", cssTexts: [css], width: 140, height: 70)
        #expect(result.pages.count > 2)
        #expect(BrowserLayoutTestSupport.visibleText(result.pages, sourceText: result.doc.lastSourceText) == "開始" + content)
        for page in result.pages {
            for text in BrowserLayoutTestSupport.allTextFragments([page]) where isWhite(text.color) {
                #expect(fills([page]).contains { fill in
                    fill.color.isEqual(UIColor(red: 128 / 255, green: 0, blue: 128 / 255, alpha: 1)) && fill.rect.minX <= text.rect.minX + 0.001 && fill.rect.maxX >= text.rect.maxX - 0.001 && fill.rect.minY <= text.baselineY && fill.rect.maxY >= text.baselineY
                })
            }
        }
    }

    @Test(.enabled(if: BrowserLayoutRedChamberRegressionTests.epubPath != nil))
    func originalGalleryPaintsSixPurpleBadgesInPagedAndContinuousFlow() async throws {
        typealias Fixture = BrowserLayoutRedChamberRegressionTests
        let session = try await Fixture.session()
        var gallerySpine: Int?
        for spine in session.chapters.indices.prefix(15) {
            let html = try await session.chapterHTML(at: spine)
            if html.contains("class=\"bti\""), html.contains("<b>壹</b>") {
                gallerySpine = spine
                break
            }
        }
        let spine = try #require(gallerySpine, "Original gallery chapter was not found")
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: spine)
        let input = await adapter.cssFrontendInput(forChapter: spine, html: html)
        let images = await adapter.prefetchImages(forChapter: spine, html: html,
            renderWidth: Fixture.contentRect.width)
        let config = Fixture.makeConfig(adapter: adapter, images: images)
        let document = BrowserLayoutDocument(input: input, config: config, imageLoader: { images[$0] })
        let pipeline = try document.makeLayout(containerSize: Fixture.viewport)
        let pages = PageFragmentation.fragment(box: pipeline.rootBox, pageSize: Fixture.viewport,
            contentInsets: config.contentInsets)
        let firstPage = try #require(pages.first)
        let paged = DisplayListBuilder.build(for: firstPage, sourceText: pipeline.sourceText)
        let flow = BrowserScrollDocument.make(pipeline: pipeline,
            contentWidth: Fixture.contentRect.width, contentInsets: config.contentInsets)
        let continuous = flow.items(in: CGRect(origin: .zero, size: Fixture.viewport))
        let purple = UIColor(red: 95 / 255, green: 82 / 255, blue: 160 / 255, alpha: 1)
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reported-gallery-inline-paint", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, list) in [("paged", paged), ("continuous", continuous)] {
            let badges = list.items.compactMap { item -> DisplayFillItem? in
                if case .fill(let fill) = item, fill.color.isEqual(purple) { return fill }
                return nil
            }
            #expect(badges.count == 6, "\(name): original six character backgrounds")
            let glyphs = list.items.compactMap { item -> DisplayTextItem? in
                if case .text(let text) = item, isWhite(text.color),
                   !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                return nil
            }
            #expect(glyphs.map(\.text).joined() == "红楼梦画册壹")
            for (badge, glyph) in zip(badges, glyphs) {
                #expect(abs(glyph.rect.minX - badge.rect.minX - 3) < 0.01)
                #expect(abs(badge.rect.maxX - glyph.rect.maxX - 3) < 0.01)
                #expect(badge.rect.minY < glyph.baselineY && badge.rect.maxY > glyph.baselineY)
            }
            let image = DisplayListRenderer.render(list, size: Fixture.viewport)
            try #require(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
            // Inspect actual pixels in the padding, where text cannot mask the fill.
            for badge in badges {
                let sample = CGRect(x: badge.rect.minX, y: badge.rect.minY,
                    width: 2, height: badge.rect.height)
                #expect(try matchingPixels(image, inside: sample, color: purple) > 5)
            }
        }
        func heading(in box: BlockBox) -> BlockBox? {
            if box.debugClasses.contains("bti") { return box }
            return box.children.lazy.compactMap { heading(in: $0) }.first
        }
        let title = try #require(heading(in: pipeline.rootBox))
        #expect(abs(title.contentSize.width - 10 * title.style.fontSize) < 0.5)
        #expect(flow.sourceText == pipeline.sourceText)
        #expect(!flow.sourceText.contains("\u{FFFC}") && !flow.sourceText.contains("\u{2060}"))
        print("Original gallery inline paint evidence: \(output.path) spine=\(spine)")
    }

    private func matchingPixels(_ image: UIImage, inside rect: CGRect, color: UIColor) throws -> Int {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let scale = CGFloat(cg.width) / image.size.width
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let target = [red, green, blue].map { Int(($0 * 255).rounded()) }
        var count = 0
        for y in max(0, Int(rect.minY * scale))..<min(cg.height, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(cg.width, Int(rect.maxX * scale)) {
                let offset = (y * cg.width + x) * 4
                if (0..<3).allSatisfy({ abs(Int(bytes[offset + $0]) - target[$0]) < 4 }) { count += 1 }
            }
        }
        return count
    }

    private func isWhite(_ color: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        return color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            && red > 0.999 && green > 0.999 && blue > 0.999 && alpha > 0.999
    }

    private func fills(_ pages: [PageFragments]) -> [FillFragment] {
        pages.flatMap(\.fragments).compactMap { if case .fill(let fill) = $0 { return fill }; return nil }
    }

    private func pixelCounts(_ image: UIImage, inside rect: CGRect) throws -> (purple: Int, white: Int) {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let scale = CGFloat(cg.width) / image.size.width
        var purple = 0
        var white = 0
        for y in max(0, Int(rect.minY * scale))..<min(cg.height, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(cg.width, Int(rect.maxX * scale)) {
                let offset = (y * cg.width + x) * 4
                let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                if r > 100 && r < 160 && g < 20 && b > 100 && b < 160 { purple += 1 }
                if r > 240 && g > 240 && b > 240 { white += 1 }
            }
        }
        return (purple, white)
    }
}
