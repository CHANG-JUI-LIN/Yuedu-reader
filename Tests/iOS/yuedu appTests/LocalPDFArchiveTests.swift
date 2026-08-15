import Foundation
import PDFKit
import Testing
import UIKit
@testable import yuedu_app

/// PDF import reads a real document: page count, the file's own bookmarks, and the
/// rasterized page the fixed-page reader actually displays. These are the pieces a
/// wrong assumption would break silently — a mis-flattened outline still produces a
/// table of contents, it just points at the wrong pages.
@Suite("Local PDF archive")
struct LocalPDFArchiveTests {

    // MARK: Fixtures

    /// A PDF written to disk with `pageCount` pages of the given point size.
    private static func makePDF(
        pageCount: Int,
        pageSize: CGSize = CGSize(width: 400, height: 600),
        filename: String = "fixture.pdf"
    ) throws -> URL {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                let text = "Page \(index + 1)"
                text.draw(
                    at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
                )
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Inspection

    @Test("Inspect reports the real page count")
    func inspectReadsDocument() throws {
        let url = try Self.makePDF(pageCount: 3)
        defer { Self.cleanup(url) }

        let info = try LocalPDFArchive.inspect(url: url)

        #expect(info.pageCount == 3)
        #expect(info.sections.isEmpty)
    }

    @Test("A PDF with no embedded title falls back to a cleaned-up filename")
    func titleFallsBackToFilename() throws {
        let url = try Self.makePDF(pageCount: 1, filename: "My_Manual.pdf")
        defer { Self.cleanup(url) }

        let document = try #require(PDFDocument(url: url))
        let embeddedTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        try #require(embeddedTitle.isEmpty)

        #expect(try LocalPDFArchive.inspect(url: url).title == "My Manual")
    }

    @Test("A non-PDF file is rejected before anything else runs")
    func rejectsWrongExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try "not a pdf".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: LocalPDFArchiveError.self) {
            try LocalPDFArchive.inspect(url: url)
        }
    }

    // MARK: Outline

    @Test("Bookmarks flatten depth-first, keeping their page targets")
    func flattensOutlineDepthFirst() throws {
        let url = try Self.makePDF(pageCount: 4)
        defer { Self.cleanup(url) }
        let document = try #require(PDFDocument(url: url))

        let root = PDFOutline()
        root.insertChild(Self.outline("Chapter 1", page: 0, in: document), at: 0)
        let second = Self.outline("Chapter 2", page: 2, in: document)
        second.insertChild(Self.outline("Chapter 2.1", page: 3, in: document), at: 0)
        root.insertChild(second, at: 1)
        document.outlineRoot = root

        let sections = LocalPDFArchive.sections(in: document)

        #expect(sections.map(\.startPage) == [0, 2, 3])
        #expect(sections.map(\.title) == [
            "Chapter 1",
            "Chapter 2",
            "\u{2007}\u{2007}Chapter 2.1",
        ])
    }

    @Test("Bookmarks that resolve to no page are dropped rather than shown as dead rows")
    func dropsUnresolvableBookmarks() throws {
        let url = try Self.makePDF(pageCount: 2)
        defer { Self.cleanup(url) }
        let document = try #require(PDFDocument(url: url))

        let root = PDFOutline()
        let dangling = PDFOutline()
        dangling.label = "Nowhere"
        root.insertChild(dangling, at: 0)
        root.insertChild(Self.outline("Real", page: 1, in: document), at: 1)
        document.outlineRoot = root

        let sections = LocalPDFArchive.sections(in: document)

        #expect(sections.count == 1)
        #expect(sections.first?.startPage == 1)
    }

    private static func outline(_ label: String, page: Int, in document: PDFDocument) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = label
        if let pdfPage = document.page(at: page) {
            outline.destination = PDFDestination(page: pdfPage, at: .zero)
        }
        return outline
    }

    // MARK: Chapter model

    @Test("A PDF book is one chapter covering every page")
    func buildsSingleChapter() throws {
        let url = try Self.makePDF(pageCount: 7)
        defer { Self.cleanup(url) }

        let info = try LocalPDFArchive.inspect(url: url)
        let ref = LocalPDFArchive.chapterRef(for: info, filename: "abc.pdf", bookTitle: "Book")

        #expect(ref.index == 0)
        #expect(ref.url == "abc.pdf")
        #expect(ref.title == "Book")
        #expect(ref.pdfPageCount == 7)
    }

    /// `pdfPageCount` had to be optional: the synthesized decoder only tolerates a
    /// missing key for optional properties, and every book saved before PDF support
    /// lacks it.
    @Test("Chapter refs saved before PDF support still decode")
    func decodesLegacyChapterRef() throws {
        let json = """
        {"id":"\(UUID().uuidString)","index":4,"title":"第五章","url":"https://example.com/5"}
        """
        let ref = try JSONDecoder().decode(OnlineChapterRef.self, from: Data(json.utf8))

        #expect(ref.index == 4)
        #expect(ref.pdfPageCount == nil)
    }

    // MARK: Rasterizing

    @Test("A rendered page keeps the document's aspect ratio at the requested scale")
    func rendersPageAtRequestedSize() throws {
        let url = try Self.makePDF(pageCount: 1, pageSize: CGSize(width: 400, height: 600))
        defer { Self.cleanup(url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let image = try #require(PDFPageRasterizer.renderPage(page, targetWidth: 200, scale: 2))

        #expect(image.size.width == 200)
        #expect(image.size.height == 300)
        #expect(image.scale == 2)
        // Points times scale is what actually lands in the bitmap.
        #expect(image.cgImage?.width == 400)
    }

    @Test("Rendering a page reads through the rasterizer's cache")
    func rasterizerServesPages() async throws {
        let url = try Self.makePDF(pageCount: 2)
        defer { Self.cleanup(url) }
        let rasterizer = PDFPageRasterizer()

        #expect(await rasterizer.pageCount(fileURL: url) == 2)

        let first = await rasterizer.image(fileURL: url, pageIndex: 1, targetWidth: 120, scale: 1)
        let cached = await rasterizer.image(fileURL: url, pageIndex: 1, targetWidth: 120, scale: 1)
        #expect(first != nil)
        #expect(first === cached)

        // Out of range asks for a page the document doesn't have.
        let missing = await rasterizer.image(fileURL: url, pageIndex: 9, targetWidth: 120, scale: 1)
        #expect(missing == nil)

        await rasterizer.purge()
    }
}
