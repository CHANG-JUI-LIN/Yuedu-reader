import Combine
import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// Where a converted book's 傍点 and 傍線 land, in both engines and both writing modes
/// (docs/superpowers/plans/2026-10-07-aozora-complete-support.md, Task 8): over the text and on
/// the right of a vertical line, or under it and on the left for 左に. BrowserAuto's marks and
/// lines are found as ink outside its text fragments; legacy's as the ruby annotations and
/// decoration marks it draws from (`LegacyTextEmphasisDecorationTests` checks that drawing).
/// The pages are saved for the plan's record.
@Suite("Aozora emphasis probe", .serialized)
@MainActor
struct AozoraEmphasisProbeTests {
    static let source = """
        題
        著者

        甲乙丙丁［＃「甲乙丙丁」に傍点］

        戊己庚辛［＃「戊己庚辛」の左に傍点］

        子丑寅卯［＃「子丑寅卯」にばつ傍点］

        辰巳午未［＃「辰巳午未」に傍線］

        申酉戌亥［＃「申酉戌亥」の左に傍線］

        天地玄黃［＃「天地玄黃」に二重傍線］

        宇宙洪荒［＃「宇宙洪荒」に波線］

        底本：「題」架空書房

        """

    static let size = CGSize(width: 600, height: 900)
    static let scale: CGFloat = 2
    nonisolated static let modes: [ReaderWritingMode] = [.horizontal, .verticalRTL]
    static let record = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-emphasis-probe")

    enum Side { case over, under }

    /// Each construct's text, its side, and whether it is marks (how many) or lines (how many).
    static let constructs: [(text: String, side: Side, marks: Int, lines: Int)] = [
        ("甲乙丙丁", .over, 4, 0), ("戊己庚辛", .under, 4, 0), ("子丑寅卯", .over, 4, 0),
        ("辰巳午未", .over, 0, 1), ("申酉戌亥", .under, 0, 1), ("天地玄黃", .over, 0, 2), ("宇宙洪荒", .over, 0, 1),
    ]

    @Test(arguments: modes)
    func browserAutoDrawsEachOnItsSide(mode: ReaderWritingMode) async throws {
        let vertical = mode.isVertical
        let (session, spine) = try await Self.book()
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: Self.size,
                      settings: EPUBTestFixtures.renderSettings(writingMode: mode))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        _ = await engine.preloadChapter(at: spine)
        #expect(engine.choice(for: spine)?.isBrowser == true, "\(mode)")
        let layout = try #require(engine.testLayout(for: spine))
        try #require(layout.pages.count == 1)

        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: Self.size))
            ReaderDisplayListDrawer.draw(list, in: context.cgContext)
        }
        try FileManager.default.createDirectory(at: Self.record, withIntermediateDirectories: true)
        try image.pngData()?.write(to: Self.record.appendingPathComponent("browser-\(vertical ? "v" : "h").png"))

        // Each run's glyph box on the page: its text's content box, placed as the drawer places
        // the text (`DisplayListDrawer.drawText`). A vertical item's baseline is the x of its
        // column's centre line. A text item's own box is its line box, which holds the marks and
        // lines too.
        let texts = list.items.compactMap { item -> (range: NSRange, box: CGRect, baseline: CGFloat)? in
            guard case .text(let text) = item, text.sourceRange.length > 0 else { return nil }
            let ascent = ceil(text.font.ascender), height = ascent + ceil(-text.font.descender)
            let rect = text.rect.rawValue
            let box = vertical
                ? CGRect(x: text.baselineY - height / 2, y: rect.minY, width: height, height: rect.height)
                : CGRect(x: rect.minX, y: text.baselineY - ascent, width: rect.width, height: height)
            return (text.sourceRange, box.applying(text.paintTransform?.matrix ?? .identity), text.baselineY)
        }
        let source = layout.sourceText as NSString
        let pixels = Ink(try #require(image.cgImage), scale: Self.scale)
        var solidRows: [ClosedRange<Int>] = []

        for construct in Self.constructs {
            let range = source.range(of: construct.text)
            try #require(range.location != NSNotFound, "\(construct.text)")
            let own = texts.filter { NSIntersectionRange($0.range, range).length > 0 }
            let rect = own.map(\.box).reduce(CGRect.null) { $0.union($1) }
            try #require(!rect.isNull, "\(construct.text) \(mode)")
            // The construct's own text, and the half line either side of it, outside every glyph box.
            let half = rect.insetBy(dx: vertical ? -0.75 * 17 : 0, dy: vertical ? 0 : -0.75 * 17)
            let ink = pixels.blobs(in: half, outside: texts.map(\.box))
            let over = ink.filter { vertical ? $0.midX > rect.maxX : $0.midY < rect.minY }
            let under = ink.filter { vertical ? $0.midX < rect.minX : $0.midY > rect.maxY }
            let found = construct.side == .over ? over : under
            let other = construct.side == .over ? under : over
            if construct.marks > 0 {
                #expect(found.count == construct.marks, "\(construct.text) \(mode): \(found) beside \(rect); ink \(ink)")
                #expect(other.isEmpty, "\(construct.text) \(mode): \(other)")
            } else {
                // Lines run through the glyph boxes, beyond the baseline on their side: a row of
                // ink (a column, vertically) unbroken along the text, which the glyphs alone never
                // draw. A vertical line's baseline is its centre, and its over side is the right.
                let baseline = own[0].baseline
                func unbroken(over: Bool) -> [ClosedRange<Int>] {
                    vertical
                        ? pixels.unbrokenColumns(from: rect.minY + 1, to: rect.maxY - 1,
                                                 between: over ? baseline : rect.minX - 0.75 * 17,
                                                 and: over ? rect.maxX + 0.75 * 17 : baseline)
                        : pixels.unbrokenRows(from: rect.minX + 1, to: rect.maxX - 1,
                                              below: over ? rect.minY - 0.75 * 17 : baseline,
                                              above: over ? baseline - 1 : rect.maxY + 0.75 * 17)
                }
                // Horizontally every line is an underline, so it is under the text.
                let side = vertical ? construct.side == .over : false
                let rows = unbroken(over: side)
                #expect(rows.count == construct.lines, "\(construct.text) \(mode): \(rows)")
                #expect(unbroken(over: !side).isEmpty, "\(construct.text) \(mode): \(unbroken(over: !side))")
                if construct.text == "辰巳午未" { solidRows = rows }
                if construct.text == "宇宙洪荒", let wave = rows.first, let solid = solidRows.first {
                    // A wave's stroke is as thick as a solid line's, but it rises and falls, so
                    // fewer of its rows are unbroken.
                    #expect(wave.count < solid.count, "wave \(rows) against solid \(solidRows)")
                }
            }
        }
    }

    @Test(arguments: modes)
    func legacyDrawsEachOnItsSide(mode: ReaderWritingMode) async throws {
        let (session, spine) = try await Self.book()
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: Self.size)
        let built = try await builder.buildChapter(at: spine, settings: EPUBTestFixtures.renderSettings(writingMode: mode),
                                                   themeTextColor: .black, themeBackgroundColor: .white)
        let string = built.attributedString
        let text = string.string as NSString
        for construct in Self.constructs {
            let range = text.range(of: construct.text)
            try #require(range.location != NSNotFound, "\(construct.text)")
            for offset in 0..<range.length {
                let index = range.location + offset
                let ruby = string.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, at: index,
                                            effectiveRange: nil).map { $0 as! CTRubyAnnotation }
                let mark = string.attribute(HTMLAttributedStringBuilder.textDecorationAttribute, at: index,
                                            effectiveRange: nil) as? ReaderTextDecorationMark
                if construct.marks > 0 {
                    let annotation = try #require(ruby, "\(construct.text) \(mode)")
                    let position: CTRubyPosition = construct.side == .over ? .before : .after
                    #expect(CTRubyAnnotationGetTextForPosition(annotation, position) != nil, "\(construct.text) \(mode)")
                    #expect(mark == nil)
                } else {
                    let decoration = try #require(mark?.decorations.first, "\(construct.text) \(mode)")
                    #expect(decoration.lines == .underline && decoration.color == nil)
                    #expect(decoration.underlineRight == (construct.side == .over), "\(construct.text)")
                    #expect(ruby == nil)
                }
            }
        }
        #expect(
            (string.attribute(HTMLAttributedStringBuilder.textDecorationAttribute, at: text.range(of: "天").location,
                              effectiveRange: nil) as? ReaderTextDecorationMark)?.decorations.first?.style == .double)
        #expect(
            (string.attribute(HTMLAttributedStringBuilder.textDecorationAttribute, at: text.range(of: "宇").location,
                              effectiveRange: nil) as? ReaderTextDecorationMark)?.decorations.first?.style == .wavy)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: spine, attrStr: LayoutShared(string).wrappedValue, renderSize: Self.size, fontSize: 17,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), writingMode: mode)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: Self.size))
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0, in: context.cgContext,
                                        bounds: CGRect(origin: .zero, size: Self.size))
        }
        try FileManager.default.createDirectory(at: Self.record, withIntermediateDirectories: true)
        try image.pngData()?.write(to: Self.record.appendingPathComponent("legacy-\(mode.isVertical ? "v" : "h").png"))
    }

    // MARK: Helpers

    static func book() async throws -> (PublicationSession, Int) {
        let document = AozoraDocumentParser.parse(source)
        let chapters = AozoraChapterPlanner.plan(document, source: source)
        let spine = try #require(chapters.firstIndex { $0.text.contains("甲乙丙丁") })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-emphasis-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: [:],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue, length: source.utf16.count),
            identifier: "urn:uuid:aozora-emphasis", to: url)
        return (try await PublicationSession.open(sourceURL: url), spine)
    }

    /// Dark pixels of a render, in points.
    struct Ink {
        let width: Int
        let height: Int
        let scale: CGFloat
        let dark: [Bool]

        init(_ image: CGImage, scale: CGFloat) {
            width = image.width
            height = image.height
            self.scale = scale
            var buffer = [UInt8](repeating: 255, count: width * height * 4)
            let (w, h) = (width, height)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            dark = (0..<(w * h)).map { max(buffer[$0 * 4], buffer[$0 * 4 + 1], buffer[$0 * 4 + 2]) < 128 }
        }

        func isDark(_ x: Int, _ y: Int) -> Bool { dark[y * width + x] }

        /// The connected ink in `window` that no rect of `excluded` holds, as rects in points.
        func blobs(in window: CGRect, outside excluded: [CGRect]) -> [CGRect] {
            let x0 = max(0, Int(window.minX * scale)), x1 = min(width - 1, Int(window.maxX * scale))
            let y0 = max(0, Int(window.minY * scale)), y1 = min(height - 1, Int(window.maxY * scale))
            guard x0 <= x1, y0 <= y1 else { return [] }
            func counts(_ x: Int, _ y: Int) -> Bool {
                guard isDark(x, y) else { return false }
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                return !excluded.contains { $0.contains(point) }
            }
            var seen = Set<Int>()
            var result: [CGRect] = []
            for y in y0...y1 { for x in x0...x1 where !seen.contains(y * width + x) && counts(x, y) {
                var stack = [(x, y)]
                seen.insert(y * width + x)
                var (minX, minY, maxX, maxY, size) = (x, y, x, y, 0)
                while let (cx, cy) = stack.popLast() {
                    minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                    size += 1
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= x0, ny >= y0, nx <= x1, ny <= y1, !seen.contains(ny * width + nx),
                              counts(nx, ny) else { continue }
                        seen.insert(ny * width + nx)
                        stack.append((nx, ny))
                    }
                }
                if size > 2 {
                    result.append(CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                                         width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale))
                }
            } }
            return result
        }

        /// Runs of columns between `between` and `and` dark all the way from `from` down to `to`.
        func unbrokenColumns(from: CGFloat, to: CGFloat, between: CGFloat, and: CGFloat) -> [ClosedRange<Int>] {
            let y0 = Int(from * scale), y1 = Int(to * scale)
            var result: [ClosedRange<Int>] = []
            var start: Int?
            let columns = max(0, Int(between * scale))...min(width - 1, Int(and * scale))
            for x in columns {
                let full = (y0...y1).allSatisfy { isDark(x, $0) }
                if full, start == nil { start = x }
                if !full, let begin = start { result.append(begin...(x - 1)); start = nil }
            }
            if let begin = start { result.append(begin...columns.upperBound) }
            return result
        }

        /// Runs of rows between `below` and `above` dark all the way from `from` to `to`.
        func unbrokenRows(from: CGFloat, to: CGFloat, below: CGFloat, above: CGFloat) -> [ClosedRange<Int>] {
            let x0 = Int(from * scale), x1 = Int(to * scale)
            var result: [ClosedRange<Int>] = []
            var start: Int?
            let rows = Int(below * scale)...min(height - 1, Int(above * scale))
            for y in rows {
                let full = (x0...x1).allSatisfy { isDark($0, y) }
                if full, start == nil { start = y }
                if !full, let begin = start { result.append(begin...(y - 1)); start = nil }
            }
            if let begin = start { result.append(begin...rows.upperBound) }
            return result
        }
    }
}
