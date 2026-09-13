import Testing
import SwiftUI
import UIKit
@testable import yuedu_app

/// The vertical title/author layout a cover-less book gets, ported from Legado's
/// `computeCoverTextLayout`. The constants there (width/6, the three-column cap,
/// the 0.05/0.95 margins) are what keeps a two-character title and a
/// twenty-character one both landing sensibly on the same canvas, so these
/// pin them rather than the resulting pixels.
@Suite("Generated book cover layout")
struct GeneratedBookCoverTests {

    /// Stand-in for `UIFont.lineHeight`: proportional to the size, so the
    /// geometry assertions stay arithmetic.
    private func lineHeight(_ size: CGFloat, _ isAuthor: Bool) -> CGFloat { size * 1.2 }

    private func glyphs(
        width: CGFloat = 300,
        height: CGFloat = 400,
        name: String?,
        author: String? = nil,
        drawName: Bool = true,
        drawAuthor: Bool = true
    ) -> [GeneratedCoverGlyph] {
        GeneratedCoverTextLayout.glyphs(
            width: width, height: height, name: name, author: author,
            drawName: drawName, drawAuthor: drawAuthor, lineHeight: lineHeight
        )
    }

    @Test("A short title is one column at width/6, starting below the top margin")
    func shortTitleSingleColumn() {
        let out = glyphs(name: "活著").filter { !$0.isAuthor }
        #expect(out.map(\.text) == ["活", "著"])
        #expect(out.allSatisfy { $0.fontSize == 50 })  // 300 / 6
        // colX = width * 0.1 + fontSize / 2
        #expect(out.allSatisfy { $0.x == 55 })
        // First baseline = topMargin + lineHeight = 400 * 0.05 + 60
        #expect(out[0].y == 80)
        #expect(out[1].y == 140)
    }

    @Test("Filling a column wraps right and drops the rest to width/10")
    func longTitleWrapsAndShrinks() {
        // 60pt advance from y=80 fits 6 glyphs before passing 380 (height * 0.95).
        let out = glyphs(name: "一二三四五六七八").filter { !$0.isAuthor }
        #expect(out.count == 8)
        let first = out.prefix(6)
        let second = out.suffix(2)
        #expect(first.allSatisfy { $0.fontSize == 50 })
        #expect(second.allSatisfy { $0.fontSize == 30 })  // 300 / 10
        // The wrap advances by the *outgoing* column's width — plus our 15%
        // gutter, which Legado does without because its wrap always shrinks the
        // font and ours can be held at the readable floor.
        #expect(second.allSatisfy { $0.x == 112.5 })  // 55 + 50 * 1.15
    }

    @Test("A title too long for three columns ends in an ellipsis")
    func overlongTitleIsElided() {
        let out = glyphs(name: String(repeating: "書", count: 60)).filter { !$0.isAuthor }
        #expect(out.last?.text == "…")
        #expect(out.count < 60)
        // Never a fourth column. Each wrap advances by the outgoing column's own
        // pitch, so column 3 steps by 30 × 1.15, not by 50 × 1.15 again.
        #expect(Set(out.map(\.x)) == [55, 112.5, 147])
    }

    @Test("The author runs down the right edge, bottom-aligned")
    func authorColumnIsBottomAligned() {
        let out = glyphs(name: nil, author: "余華")
        #expect(out.allSatisfy { $0.isAuthor })
        #expect(out.map(\.text) == ["余", "華"])
        #expect(out.allSatisfy { $0.fontSize == 30 })  // 300 / 10
        #expect(out.allSatisfy { $0.x == 255 })        // 300 * 0.85
        // 400 * 0.95 - 2 * 36 = 308
        #expect(out[0].y == 308)
        #expect(out[1].y == 344)
    }

    @Test("A long author is clamped instead of climbing off the top")
    func longAuthorIsClamped() {
        let out = glyphs(name: nil, author: String(repeating: "名", count: 40))
        #expect(!out.isEmpty)
        #expect(out.count < 40)
        // Never above the title's own top margin, never past the bottom.
        #expect(out.allSatisfy { $0.y >= 400 * 0.05 + 36 })
        #expect(out.allSatisfy { $0.y <= 400 * 0.98 })
    }

    @Test("Each toggle silences only its own column")
    func togglesAreIndependent() {
        let authorOnly = glyphs(name: "活著", author: "余華", drawName: false)
        #expect(authorOnly.count == 2)
        #expect(authorOnly.allSatisfy { $0.isAuthor })

        let nameOnly = glyphs(name: "活著", author: "余華", drawAuthor: false)
        #expect(nameOnly.count == 2)
        #expect(nameOnly.allSatisfy { !$0.isAuthor })

        #expect(glyphs(name: "活著", author: "余華", drawName: false, drawAuthor: false).isEmpty)
    }

    /// Legado strips `\p{P}` before drawing: stacked vertically, 《》（）—— sit
    /// alone in the middle of a cell and read as gaps in the title.
    @Test("Punctuation is dropped, not given its own cell")
    func punctuationIsStripped() {
        #expect(GeneratedCoverTextLayout.characters(of: "《活著》") == ["活", "著"])
        #expect(GeneratedCoverTextLayout.characters(of: "史記·李斯列傳") == ["史", "記", "李", "斯", "列", "傳"])
        #expect(GeneratedCoverTextLayout.characters(of: "——") == [])
        #expect(GeneratedCoverTextLayout.characters(of: nil) == [])
    }

    @Test("Emoji stay whole rather than splitting into surrogates")
    func graphemeClustersSurvive() {
        #expect(GeneratedCoverTextLayout.characters(of: "貓🐈book") == ["貓", "🐈", "b", "o", "o", "k"])
    }

    @Test("A degenerate canvas lays nothing out instead of dividing by zero")
    func zeroSizedCanvasIsEmpty() {
        #expect(glyphs(width: 0, height: 400, name: "活著").isEmpty)
        #expect(glyphs(width: 300, height: 0, name: "活著").isEmpty)
    }

    /// Legado stacks every code point, so "Norwegian Wood" comes out as a column
    /// of single letters. Latin script isn't written that way.
    @Test("Only CJK titles are set vertically")
    func scriptDecidesOrientation() {
        #expect(GeneratedCoverTextLayout.prefersVerticalLayout("活著"))
        #expect(GeneratedCoverTextLayout.prefersVerticalLayout("ノルウェイの森"))
        #expect(GeneratedCoverTextLayout.prefersVerticalLayout("Vol.2 三體"))  // mixed: CJK sets the measure
        #expect(!GeneratedCoverTextLayout.prefersVerticalLayout("Norwegian Wood"))
        #expect(!GeneratedCoverTextLayout.prefersVerticalLayout("Fahrenheit 451"))
        #expect(!GeneratedCoverTextLayout.prefersVerticalLayout("Война и мир"))
        #expect(!GeneratedCoverTextLayout.prefersVerticalLayout(""))
    }

    /// The same book has to land on the same tone every launch — a per-process
    /// hash would reshuffle the whole shelf on relaunch.
    @Test("Tone selection is stable and stays in range")
    func toneSelectionIsStable() {
        for count in [1, 6, 24] {
            for seed in ["活著", "宿命之環", "", "A"] {
                let index = StableSeedHash.index(for: seed, count: count)
                #expect((0..<count).contains(index))
                #expect(index == StableSeedHash.index(for: seed, count: count))
            }
        }
    }

    /// The renderer being right is only half of it: `GeneratedBookCover` reads
    /// its size from a `GeometryReader`, so a caller whose frame doesn't reach
    /// the view would draw nothing at all. This renders the SwiftUI view the way
    /// the shelf, the reader's book card and the now-playing artwork frame it,
    /// and fails on a blank result.
    @MainActor
    @Test("The view fills the frame its callers give it")
    func viewRendersInsideACallerFrame() throws {
        for size in [
            CGSize(width: 104, height: 138), CGSize(width: 62, height: 84),
            CGSize(width: 45, height: 65), CGSize(width: 56, height: 56),
        ] {
            let renderer = ImageRenderer(
                content: GeneratedBookCover(title: "宿命之環", author: "愛潛水的烏賊")
                    .frame(width: size.width, height: size.height)
            )
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size == size)
            #expect(!isBlank(image), "\(size) rendered blank — the frame never reached the GeometryReader")
        }
    }

    /// The regression this pins: every cover narrower than 60pt was reduced to a
    /// single character, which is what a shelf row (45×65) and a 4- or 5-column
    /// grid actually are. A book cover shows its title at every size; only the
    /// square, circle-clipped slots (the reader's 34pt button, the 56pt
    /// now-playing artwork) get an initial.
    @Test("Shape picks the treatment — only square slots get a single character")
    func layoutFollowsShapeNotSize() {
        typealias Layout = GeneratedBookCoverRenderer.Layout
        // Circle-clipped, square: an initial.
        #expect(Layout(size: CGSize(width: 34, height: 34)) == .initial)
        #expect(Layout(size: CGSize(width: 56, height: 56)) == .initial)
        // Portrait book covers, every width the app draws: never an initial.
        #expect(Layout(size: CGSize(width: 45, height: 65)) == .thumbnail)  // shelf row
        #expect(Layout(size: CGSize(width: 60, height: 80)) == .thumbnail)  // 5-column grid
        #expect(Layout(size: CGSize(width: 72, height: 96)) == .thumbnail)  // search result
        #expect(Layout(size: CGSize(width: 80, height: 107)) == .full)     // 4-column grid
        #expect(Layout(size: CGSize(width: 104, height: 138)) == .full)    // 3-column grid
        #expect(Layout(size: CGSize(width: 165, height: 220)) == .full)    // 2-column grid
        #expect(Layout(size: .zero) == .thumbnail)
    }

    /// A shelf row is 45×65. Legado's `width/6` title is 7.5pt there and its
    /// `width/10` wrap is 4.5pt, so the first fix gave thumbnails their own
    /// single-column layout — which then showed 苟在武道世界成圣 as 苟在武…
    /// Flooring the font instead keeps Legado's columns, and a whole 8- or
    /// 9-character title fits the smallest cover the app draws.
    @Test("A whole title fits a 45pt shelf row, not three characters and an ellipsis")
    func thumbnailFitsAWholeTitle() {
        func rendered(_ title: String, _ width: CGFloat, _ height: CGFloat) -> [String] {
            GeneratedCoverTextLayout.glyphs(
                width: width, height: height, name: title, author: nil,
                drawName: true, drawAuthor: false, minimumFontSize: 11,
                lineHeight: { size, _ in size * 1.2 }
            ).map(\.text)
        }
        for size in [(CGFloat(45), CGFloat(65)), (60, 80), (72, 96)] {
            #expect(rendered("苟在武道世界成圣", size.0, size.1)
                    == ["苟", "在", "武", "道", "世", "界", "成", "圣"])
            #expect(rendered("我师兄实在太稳健了", size.0, size.1)
                    == ["我", "师", "兄", "实", "在", "太", "稳", "健", "了"])
            #expect(rendered("万古神帝", size.0, size.1) == ["万", "古", "神", "帝"])
        }
        // Three columns is still the cap, so a very long title elides.
        let long = rendered("史記·卷八十七·李斯列傳第二十七", 45, 65)
        #expect(long.last == "…")
        #expect(long.count == 12)
    }

    /// Every glyph has to stay on the cover. A floored font can fill the width
    /// before it reaches Legado's third column, and a column drawn past the
    /// right edge is simply invisible.
    @Test("Columns never run off the right edge")
    func columnsStayInsideTheCover() {
        for width in stride(from: CGFloat(40), through: 200, by: 5) {
            let height = width / 0.75
            let glyphs = GeneratedCoverTextLayout.glyphs(
                width: width, height: height,
                name: String(repeating: "書", count: 40), author: "作者名",
                drawName: true, drawAuthor: true, minimumFontSize: 11,
                lineHeight: { size, _ in size * 1.2 }
            )
            #expect(!glyphs.isEmpty)
            for glyph in glyphs {
                #expect(glyph.x + glyph.fontSize / 2 <= width,
                        "\(glyph.text) runs off a \(width)pt cover")
                #expect(glyph.x - glyph.fontSize / 2 >= 0)
            }
        }
    }

    /// The floor is what makes one algorithm work at both ends; without it a
    /// wrapped column on a shelf row is 4.5pt.
    @Test("No glyph is ever smaller than the readable floor")
    func fontNeverDropsBelowTheFloor() {
        for width in [CGFloat(45), 60, 72, 80, 104, 165] {
            let glyphs = GeneratedCoverTextLayout.glyphs(
                width: width, height: width / 0.75,
                name: "我师兄实在太稳健了", author: "作者",
                drawName: true, drawAuthor: true, minimumFontSize: 11,
                lineHeight: { size, _ in size * 1.2 }
            )
            #expect(glyphs.allSatisfy { $0.fontSize >= 11 })
        }
    }

    /// Local imports carry the literal 未知作者 rather than an empty author, so a
    /// freshly imported TXT would otherwise get it printed down its cover.
    @MainActor
    @Test("The unknown-author placeholder is not painted onto a cover")
    func placeholderAuthorIsNotDrawn() throws {
        let size = CGSize(width: 104, height: 138)
        func render(author: String?) throws -> Data {
            let image = try #require(GeneratedBookCoverRenderer.image(
                title: "万古神帝", author: author, size: size,
                colorScheme: .light, drawsName: true, drawsAuthor: true, scale: 1
            ))
            return try #require(image.pngData())
        }
        #expect(try render(author: localized("未知作者")) == (try render(author: nil)))
        #expect(try render(author: "Unknown Author") == (try render(author: nil)))
        #expect(try render(author: "  ") == (try render(author: nil)))
        #expect(try render(author: "飞天鱼") != (try render(author: nil)))
    }

    /// The bug this covers: the bookshelf never used the shared placeholder — its
    /// row, its grid cell and the open-book transition each inlined their own grey
    /// title card, so swapping the shared one out left a local TXT with no cover
    /// showing the old placeholder. All three now go through
    /// `BookshelfCoverStyle`, and this fails if any of them regains its own.
    @MainActor
    @Test("A coverless shelf book resolves to real artwork, not a blank card")
    func shelfResolvesArtworkForACoverlessBook() throws {
        let book = ReadingBook(title: "宿命之環", author: "愛潛水的烏賊", contentFilename: "x.txt")
        #expect(BookshelfCoverStyle.image(for: book, colorScheme: .light) == nil)

        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: BookshelfCoverStyle.artwork(for: book, colorScheme: scheme)
                    .frame(width: 104, height: 138)
            )
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(!isBlank(image), "\(scheme) shelf cover rendered blank")
        }

        #expect(BookshelfCoverStyle.snapshot(for: book, colorScheme: .light) != nil,
                "the open-book transition would lift an empty card")
    }

    @MainActor
    @Test("Opening preserves the shelf cover layout while increasing pixel density")
    func openingSnapshotPreservesShelfLayout() throws {
        let settings = GlobalSettings.shared
        let originalName = settings.defaultCoverDrawsBookName
        let originalAuthor = settings.defaultCoverDrawsBookAuthor
        settings.defaultCoverDrawsBookName = true
        settings.defaultCoverDrawsBookAuthor = true
        defer {
            settings.defaultCoverDrawsBookName = originalName
            settings.defaultCoverDrawsBookAuthor = originalAuthor
        }

        for title in ["Kusamakura", "苟在武道世界成圣"] {
            let book = ReadingBook(title: title, author: "Natsume, Sōseki", contentFilename: "x.txt")
            for scheme in [ColorScheme.light, .dark] {
                #expect(BookshelfCoverStyle.image(for: book, colorScheme: scheme) == nil)
                for size in [
                    CGSize(width: 45, height: 65),
                    CGSize(width: 60, height: 90),
                    CGSize(width: 104, height: 156),
                ] {
                    let snapshot = try #require(BookshelfCoverStyle.snapshot(
                        for: book, colorScheme: scheme, sourceSize: size
                    ))
                    #expect(abs(snapshot.size.width - size.width) < 0.1)
                    #expect(abs(snapshot.size.height - size.height) < 0.1)
                    #expect(try #require(snapshot.cgImage).height >= 800)
                    let expected = try #require(GeneratedBookCoverRenderer.image(
                        title: title, author: book.author, size: size,
                        colorScheme: scheme, drawsName: true, drawsAuthor: true,
                        scale: snapshot.scale
                    ))
                    #expect(snapshot.pngData() == expected.pngData(),
                            "Opening must preserve the shelf's line breaks, font sizes and author visibility")
                }
            }
        }
    }

    /// True when every pixel is the same colour, which is what a cover that
    /// never got a size looks like.
    @MainActor
    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = Array(pixels[0..<4])
        return !stride(from: 0, to: pixels.count, by: 4).contains { offset in
            Array(pixels[offset..<offset + 4]) != first
        }
    }

    @MainActor
    @Test("Every slot the app draws produces an opaque bitmap at the asked-for size")
    func rendersAtEverySlotSize() {
        // 34/56 are the reader's cover button and the now-playing artwork — the
        // two square, circle-clipped slots that take the initial path.
        let sizes: [CGSize] = [
            CGSize(width: 34, height: 34), CGSize(width: 56, height: 56),
            CGSize(width: 45, height: 65), CGSize(width: 52, height: 70),
            CGSize(width: 62, height: 84), CGSize(width: 72, height: 96),
            CGSize(width: 80, height: 107), CGSize(width: 96, height: 132),
            CGSize(width: 104, height: 138), CGSize(width: 165, height: 220),
        ]
        for size in sizes {
            for scheme in [ColorScheme.light, .dark] {
                for title in ["宿命之環", "Norwegian Wood"] {
                    let image = GeneratedBookCoverRenderer.image(
                        title: title, author: "愛潛水的烏賊", size: size,
                        colorScheme: scheme, drawsName: true, drawsAuthor: true, scale: 3
                    )
                    #expect(image != nil)
                    #expect(image?.size == size)
                }
            }
        }
    }
}
