import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// Legacy's `text-emphasis` marks and `text-decoration` lines, through `EPUBAttributedStringBuilder`
/// and the paged and scroll painters, in both writing modes (Aozora plan, Task 7). Marks are drawn
/// in red and lines in blue on black text, and found by colour in a 3× render.
@Suite("Legacy text emphasis and decoration", .serialized)
@MainActor
struct LegacyTextEmphasisDecorationTests {
    static let pageSize = CGSize(width: 320, height: 480)
    static let scale: CGFloat = 3
    static let tail = String(repeating: "天地玄黃宇宙洪荒日月盈昃辰宿列張", count: 4)

    static let css = """
        .em { text-emphasis: filled sesame red; text-emphasis-position: over right; }
        .emu { text-emphasis: filled circle red; text-emphasis-position: under left; }
        .plain-em { text-emphasis: filled sesame; text-emphasis-position: over right; }
        .lt { text-decoration: line-through blue; }
        .ul { text-decoration: underline blue; }
        .ur { text-decoration: underline blue; text-underline-position: right; }
        .ov { text-decoration: overline blue; }
        .plain-ov { text-decoration: overline; }
        .dbl { text-decoration: underline double blue; }
        .dot { text-decoration: underline dotted blue; }
        .dash { text-decoration: underline dashed blue; }
        .wavy { text-decoration: underline wavy blue; }
        .none { text-decoration: none; }
        """

    static func entries(body: String) -> [String: Data] {
        [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:legacy-emphasis-decoration</dc:identifier>
                <dc:title>Emphasis</dc:title><dc:language>ja</dc:language>
              </metadata>
              <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="css" href="s.css" media-type="text/css"/>
              <item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c0"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
            <body><nav epub:type="toc"><ol><li><a href="c0.xhtml">Start</a></li></ol></nav></body></html>
            """.utf8),
            "OPS/s.css": Data(css.utf8),
            "OPS/c0.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja"><head><title>c</title>\
            <link rel="stylesheet" type="text/css" href="s.css"/></head><body>\(body)</body></html>
            """.utf8),
        ]
    }

    static func build(_ body: String, mode: ReaderWritingMode) async throws -> NSAttributedString {
        let url = try await EPUBTestFixtures.makeArchive(entries: entries(body: body))
        let session = try await PublicationSession.open(sourceURL: url)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: pageSize)
        let built = try await builder.buildChapter(
            at: 0, settings: EPUBTestFixtures.renderSettings(fontSize: 17, writingMode: mode),
            themeTextColor: .black, themeBackgroundColor: .white)
        return built.attributedString
    }

    static func layout(_ body: String, mode: ReaderWritingMode) async throws -> CoreTextPaginator.ChapterLayout {
        let string = try await build(body, mode: mode)
        return await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: LayoutShared(string).wrappedValue, renderSize: pageSize,
            fontSize: 17, contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), writingMode: mode)
    }

    /// The first page, painted as a page, or as a scroll chunk holding the page's text in a frame
    /// at the chunk's origin, as `CoreTextChunkSlicer` lays chunks out.
    static func render(_ layout: CoreTextPaginator.ChapterLayout, scroll: Bool) throws -> Pixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: pageSize)
        let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            if scroll {
                let chunk = CoreTextChunk(
                    chapterIndex: 0, charRange: layout.pageRanges[0], size: pageSize,
                    framesetter: layout.framesetter, attributedString: layout.attributedString,
                    frame: CoreTextPaginator.makeFrame(
                        framesetter: layout.framesetter, range: layout.pageRanges[0],
                        path: CGPath(rect: bounds, transform: nil), writingMode: layout.writingMode),
                    writingMode: layout.writingMode)
                CoreTextChunkDrawView.draw(chunk, bounds: bounds)
            } else {
                CoreTextPageView.renderPage(layout: layout, pageIndex: 0, in: context.cgContext, bounds: bounds)
            }
        }
        return try Pixels(#require(image.cgImage))
    }

    struct Pixels {
        let width: Int
        let height: Int
        var buffer: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            buffer = [UInt8](repeating: 255, count: width * height * 4)
            let (w, h) = (width, height)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = (y * width + x) * 4
            return (Int(buffer[o]), Int(buffer[o + 1]), Int(buffer[o + 2]))
        }

        static func black(_ c: (Int, Int, Int)) -> Bool { max(c.0, c.1, c.2) < 110 }
        static func red(_ c: (Int, Int, Int)) -> Bool { c.0 > 150 && c.1 < 140 && c.2 < 140 }
        static func blue(_ c: (Int, Int, Int)) -> Bool { c.2 > 150 && c.0 < 140 && c.1 < 160 }
        static func green(_ c: (Int, Int, Int)) -> Bool { c.1 > 100 && c.0 < 90 && c.2 < 90 }
        /// Text, or a line drawn across it.
        static func ink(_ c: (Int, Int, Int)) -> Bool { black(c) || blue(c) }

        /// Runs of rows (horizontal) or columns (vertical, right to left) holding a pixel of `kind`,
        /// in pixels.
        func bands(vertical: Bool, _ kind: ((Int, Int, Int)) -> Bool) -> [ClosedRange<Int>] {
            let count = vertical ? width : height
            var hits = [Bool](repeating: false, count: count)
            for y in 0..<height { for x in 0..<width where kind(rgb(x, y)) { hits[vertical ? x : y] = true } }
            var result: [ClosedRange<Int>] = []
            var start: Int?
            for index in 0...count {
                let hit = index < count && hits[index]
                if hit, start == nil { start = index }
                if !hit, let begin = start { result.append(begin...(index - 1)); start = nil }
            }
            return vertical ? result.reversed() : result
        }

        struct Blob {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var width: Int { maxX - minX + 1 }
            var height: Int { maxY - minY + 1 }
        }

        func blobs(_ kind: ((Int, Int, Int)) -> Bool) -> [Blob] {
            var seen = [Bool](repeating: false, count: width * height)
            var result: [Blob] = []
            for y in 0..<height { for x in 0..<width where !seen[y * width + x] && kind(rgb(x, y)) {
                var blob = Blob()
                var stack = [(x, y)]
                var size = 0
                seen[y * width + x] = true
                while let (cx, cy) = stack.popLast() {
                    blob.minX = min(blob.minX, cx); blob.maxX = max(blob.maxX, cx)
                    blob.minY = min(blob.minY, cy); blob.maxY = max(blob.maxY, cy)
                    size += 1
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height, !seen[ny * width + nx],
                              kind(rgb(nx, ny)) else { continue }
                        seen[ny * width + nx] = true
                        stack.append((nx, ny))
                    }
                }
                if size > 2 { result.append(blob) }
            } }
            return result
        }
    }

    nonisolated static let modes: [ReaderWritingMode] = [.horizontal, .verticalRTL]

    // MARK: - Emphasis marks

    /// One mark on each of 甲乙丙丁, none on the comma or the space, between the line before and
    /// the text (over; right in vertical writing); one on each of 戊己 on the other side. The
    /// marked line grows; the paragraph's other lines keep their pitch.
    @Test(arguments: modes, [false, true])
    func marksSitOnTheirSideOfEachCharacter(mode: ReaderWritingMode, scroll: Bool) async throws {
        let vertical = mode.isVertical
        let marked = "<p>基準基準基準</p><p><span class=\"em\">甲乙、丙 丁</span>\(Self.tail)</p>"
            + "<p><span class=\"emu\">戊己</span></p>"
        let unmarked = marked.replacingOccurrences(of: "class=\"em\"", with: "")
            .replacingOccurrences(of: "class=\"emu\"", with: "")
        let pixels = try Self.render(try await Self.layout(marked, mode: mode), scroll: scroll)
        let reference = try Self.render(try await Self.layout(unmarked, mode: mode), scroll: scroll)

        let lines = pixels.bands(vertical: vertical, Pixels.black)
        let referenceLines = reference.bands(vertical: vertical, Pixels.black)
        try #require(lines.count >= 5 && lines.count == referenceLines.count, "\(lines) vs \(referenceLines)")
        let marks = pixels.blobs(Pixels.red)
        #expect(marks.count == 6, "\(marks)")

        // Across the line, toward the page's top (horizontal) or its right (vertical).
        func across(_ blob: Pixels.Blob) -> ClosedRange<Int> {
            vertical ? (pixels.width - 1 - blob.maxX)...(pixels.width - 1 - blob.minX) : blob.minY...blob.maxY
        }
        func flipped(_ band: ClosedRange<Int>) -> ClosedRange<Int> {
            vertical ? (pixels.width - 1 - band.upperBound)...(pixels.width - 1 - band.lowerBound) : band
        }
        let first = flipped(lines[0]), markedLine = flipped(lines[1]), last = flipped(lines[lines.count - 1])
        let over = marks.filter { across($0).lowerBound > first.upperBound && across($0).upperBound < markedLine.lowerBound }
        let under = marks.filter { across($0).lowerBound > last.upperBound }
        #expect(over.count == 4, "over: \(over); lines \(lines)")
        #expect(under.count == 2, "under: \(under); lines \(lines)")

        let pitch = flipped(lines[3]).lowerBound - flipped(lines[2]).lowerBound
        let referencePitch = flipped(referenceLines[3]).lowerBound - flipped(referenceLines[2]).lowerBound
        #expect(abs(pitch - referencePitch) <= 1, "pitch \(pitch) against \(referencePitch)")
        #expect(markedLine.lowerBound > flipped(referenceLines[1]).lowerBound, "the marked line made room")
    }

    /// Marks are ruby annotations, so the text is unchanged; a ruby's base keeps its ruby.
    @Test(arguments: modes)
    func marksLeaveTheTextAndRubiesAlone(mode: ReaderWritingMode) async throws {
        let string = try await Self.build(
            "<p><span class=\"em\"><ruby>漢<rt>かん</rt></ruby>字、文</span></p>", mode: mode)
        let text = string.string as NSString
        #expect(text.range(of: "漢字、文").location != NSNotFound, "\(text)")
        #expect(text.range(of: "\u{FE45}").location == NSNotFound, "\(text)")
        func annotation(at character: String) -> CTRubyAnnotation? {
            let index = text.range(of: character).location
            guard index != NSNotFound,
                  let value = string.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, at: index,
                                               effectiveRange: nil) else { return nil }
            return (value as! CTRubyAnnotation)
        }
        let ruby = try #require(annotation(at: "漢"))
        #expect(CTRubyAnnotationGetTextForPosition(ruby, .before) as String? == "かん")
        let mark = try #require(annotation(at: "字"))
        let expected = TextEmphasisStyle.shape(filled: true, shape: .sesame).mark(vertical: mode.isVertical)
        #expect(CTRubyAnnotationGetTextForPosition(mark, .before) as String? == expected)
        #expect(annotation(at: "、") == nil)
    }

    // MARK: - Decoration lines

    enum Side { case over, under, through }

    /// Each line on its side of the text: under or over it, or through it; in vertical writing
    /// the under side is the left, and `text-underline-position: right` takes the underline there.
    @Test(arguments: [
        ("lt", ReaderWritingMode.horizontal, Side.through), ("ul", .horizontal, .under), ("ov", .horizontal, .over),
        ("lt", .verticalRTL, .through), ("ul", .verticalRTL, .under), ("ur", .verticalRTL, .over),
        ("ov", .verticalRTL, .over),
    ], [false, true])
    func linesSitOnTheirSide(decoration: (String, ReaderWritingMode, Side), scroll: Bool) async throws {
        let (name, mode, side) = decoration
        let vertical = mode.isVertical
        let pixels = try Self.render(
            try await Self.layout("<p>基準基準</p><p><span class=\"\(name)\">甲乙丙丁</span></p>", mode: mode),
            scroll: scroll)
        // A line-through splits the text's black, and an over- or underline clear of the glyphs
        // is a band of its own: a text line is a band of ink that holds black.
        let black = pixels.bands(vertical: vertical, Pixels.black)
        let lines = pixels.bands(vertical: vertical, Pixels.ink).filter { band in
            black.contains { $0.overlaps(band) }
        }
        try #require(lines.count == 2, "\(lines)")
        let text = lines[1]
        let middle = (text.lowerBound + text.upperBound) / 2
        let drawn = pixels.bands(vertical: vertical, Pixels.blue)
        try #require(drawn.count == 1, "\(name): \(drawn)")
        let line = drawn[0]
        // Horizontal bands run down the page, vertical ones right to left: the over side comes first.
        func before(_ a: Int, _ b: Int) -> Bool { vertical ? a > b : a < b }
        let start = vertical ? line.upperBound : line.lowerBound
        let end = vertical ? line.lowerBound : line.upperBound
        switch side {
        case .over: #expect(before(end, middle), "\(name) \(mode): \(line) against \(text)")
        case .under: #expect(before(middle, start), "\(name) \(mode): \(line) against \(text)")
        case .through: #expect(text.contains(line.lowerBound) && text.contains(line.upperBound),
                               "\(name) \(mode): \(line) against \(text)")
        }
        // Along the line it covers the four characters.
        let blobs = pixels.blobs(Pixels.blue)
        let reach = vertical
            ? (blobs.map(\.maxY).max() ?? 0) - (blobs.map(\.minY).min() ?? 0)
            : (blobs.map(\.maxX).max() ?? 0) - (blobs.map(\.minX).min() ?? 0)
        #expect(abs(CGFloat(reach) - 4 * 17 * Self.scale) <= 2 * Self.scale, "\(name) \(mode): \(reach)")
    }

    /// A double line is two lines a thickness apart; a dotted one dots as long as it is thick, a
    /// dashed one dashes twice that; a wavy one waves wider than it is thick. A horizontal
    /// underline runs under the glyphs, which may cut a piece's width, never its length.
    @Test(arguments: ["dbl", "dot", "dash", "wavy"], modes)
    func lineStyles(name: String, mode: ReaderWritingMode) async throws {
        let vertical = mode.isVertical
        let pixels = try Self.render(
            try await Self.layout("<p>基準基準</p><p><span class=\"\(name)\">甲乙丙丁</span></p>", mode: mode),
            scroll: false)
        // A thickness of 17 / 16, rounded up to whole pixels.
        let thickness = Int(ceil(17.0 / 16 * Self.scale))
        let drawn = pixels.bands(vertical: vertical, Pixels.blue)
        let blobs = pixels.blobs(Pixels.blue)
        func along(_ blob: Pixels.Blob) -> Int { vertical ? blob.height : blob.width }
        func across(_ blob: Pixels.Blob) -> Int { vertical ? blob.width : blob.height }
        switch name {
        case "dbl":
            #expect(drawn.count == 2, "\(drawn)")
        case "dot":
            #expect(blobs.count >= 12, "\(blobs.count)")
            #expect(blobs.allSatisfy { along($0) <= thickness + 1 && across($0) <= thickness + 1 }, "\(blobs)")
        case "dash":
            #expect(blobs.count >= 6, "\(blobs.count)")
            #expect(blobs.dropLast().allSatisfy { abs(along($0) - 2 * across($0)) <= 1 }, "\(blobs)")
        default:
            #expect(drawn.count == 1, "\(drawn)")
            // The wave's curves reach 0.29 of their 1.5 / 16 em amplitude either side of its axis.
            #expect((drawn.first?.count ?? 0) >= thickness + 2, "\(drawn), thickness \(thickness)")
        }
    }

    /// Marks and lines with no colour of their own are drawn in the theme's text colour, also after
    /// the theme changes without a new layout.
    @Test(arguments: modes, [false, true])
    func uncolouredMarksAndLinesFollowTheTheme(mode: ReaderWritingMode, scroll: Bool) async throws {
        let layout = try await Self.layout(
            "<p>基準基準</p><p><span class=\"plain-em\">甲乙</span><span class=\"plain-ov\">丙丁</span></p>", mode: mode)
        let green = UIColor(red: 0, green: 0.6, blue: 0, alpha: 1)
        let pixels = try Self.render(layout.withUpdatedColors(textColor: green, backgroundColor: .white), scroll: scroll)
        let lines = pixels.bands(vertical: mode.isVertical, Pixels.green)
        #expect(lines.count >= 3, "marks and the overline draw beside the text: \(lines)")
        var dark = 0
        for y in 0..<pixels.height { for x in 0..<pixels.width where Pixels.black(pixels.rgb(x, y)) {
            if !Pixels.green(pixels.rgb(x, y)) { dark += 1 }
        } }
        #expect(dark == 0, "\(dark) pixels kept the old theme's black")
    }

    /// `text-decoration` propagates: a box's lines reach the text it holds, a nested box adds its
    /// own, and `none` on a box that would be underlined takes the UA's underline away.
    @Test func decorationsPropagateAndNoneRemovesTheUAs() async throws {
        let string = try await Self.build(
            "<p><u>甲乙</u><u class=\"none\">丙丁</u><s>戊己</s><u><s>庚</s></u></p>", mode: .horizontal)
        let text = string.string as NSString
        func lines(at character: String) -> [RenderTextDecoration.Lines] {
            let index = text.range(of: character).location
            let mark = string.attribute(HTMLAttributedStringBuilder.textDecorationAttribute, at: index,
                                        effectiveRange: nil) as? ReaderTextDecorationMark
            return mark?.decorations.map(\.lines) ?? []
        }
        #expect(lines(at: "甲") == [.underline])
        #expect(lines(at: "丙") == [])
        #expect(lines(at: "戊") == [.lineThrough])
        #expect(lines(at: "庚") == [.underline, .lineThrough])
    }
}
