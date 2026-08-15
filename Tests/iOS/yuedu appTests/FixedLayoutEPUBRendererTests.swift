import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

/// A fixed-layout EPUB used to reopen the whole publication, build a fresh WKWebView
/// and throw the result away for *every page turn*. These tests pin the three things
/// that made that fixable: the document is described once, a re-read page comes back
/// from cache, and two pages rendered at once both get an answer — before the render
/// queue existed, the second load stranded the first caller until a watchdog fired.
@Suite("Fixed-layout EPUB renderer", .serialized)
struct FixedLayoutEPUBRendererTests {

    // MARK: Fixture

    private static func makeFixedLayoutEPUB(pageCount: Int = 3) async throws -> URL {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8),
        ]

        let manifestItems = (0..<pageCount).map {
            "<item id=\"page\($0)\" href=\"page\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n    ")
        let spineItems = (0..<pageCount).map {
            "<itemref idref=\"page\($0)\"/>"
        }.joined(separator: "\n    ")
        let navItems = (0..<pageCount).map {
            "<li><a href=\"page\($0).xhtml\">Plate \($0 + 1)</a></li>"
        }.joined(separator: "")

        entries["OEBPS/content.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf"
           prefix="rendition: http://www.idpf.org/vocab/rendition/#">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:fixed-layout-renderer</dc:identifier>
            <dc:title>Fixed Layout Renderer</dc:title>
            <meta property="rendition:layout">pre-paginated</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifestItems)
          </manifest>
          <spine>
            \(spineItems)
          </spine>
        </package>
        """.utf8)

        entries["OEBPS/nav.xhtml"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>Nav</title></head>
          <body><nav epub:type="toc"><ol>\(navItems)</ol></nav></body>
        </html>
        """.utf8)

        for index in 0..<pageCount {
            entries["OEBPS/page\(index).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>Plate \(index + 1)</title>
                <meta name="viewport" content="width=600, height=800"/>
              </head>
              <body style="margin:0"><div style="width:600px;height:800px;background:#ffcc33">Plate \(index + 1)</div></body>
            </html>
            """.utf8)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let archiveURL = root.appendingPathComponent("fixed-layout.epub")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let archive = try await Archive(url: archiveURL, accessMode: .create)
        for (path, data) in entries {
            let fileURL = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
            try await archive.addEntry(with: path, fileURL: fileURL)
        }
        return archiveURL
    }

    // MARK: Tests

    @Test("The document reports every page and a table of contents in one pass")
    func describesDocumentOnce() async throws {
        let url = try await Self.makeFixedLayoutEPUB(pageCount: 3)
        await FixedLayoutEPUBRenderer.shared.purge()
        defer { Task { await FixedLayoutEPUBRenderer.shared.purge() } }

        let info = try await FixedLayoutEPUBRenderer.shared.documentInfo(sourceURL: url)

        #expect(info.pageCount == 3)
        #expect(info.sections.map(\.startPage) == [0, 1, 2])
        #expect(info.sections.map(\.title) == ["Plate 1", "Plate 2", "Plate 3"])
    }

    @Test("A page read twice comes back from cache instead of rendering again")
    func cachesRenderedPages() async throws {
        let url = try await Self.makeFixedLayoutEPUB(pageCount: 2)
        await FixedLayoutEPUBRenderer.shared.purge()
        defer { Task { await FixedLayoutEPUBRenderer.shared.purge() } }

        let first = await FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 0, targetWidth: 180)
        let second = await FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 0, targetWidth: 180)

        let rendered = try #require(first)
        // The 600x800 viewport survives the snapshot, captured at display size.
        #expect(rendered.size.width > 0)
        #expect(abs(rendered.size.height / rendered.size.width - 800.0 / 600.0) < 0.05)
        // Same object, not merely an equal one: the second read never re-rendered.
        #expect(rendered === second)
    }

    @Test("Pages requested at the same time all get rendered")
    func serializesConcurrentRenders() async throws {
        let url = try await Self.makeFixedLayoutEPUB(pageCount: 3)
        await FixedLayoutEPUBRenderer.shared.purge()
        defer { Task { await FixedLayoutEPUBRenderer.shared.purge() } }

        async let page0 = FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 0, targetWidth: 160)
        async let page1 = FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 1, targetWidth: 160)
        async let page2 = FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 2, targetWidth: 160)

        let images = await [page0, page1, page2]
        #expect(images.allSatisfy { $0 != nil })
    }

    @Test("An out-of-range page reports failure instead of hanging")
    func rejectsOutOfRangePage() async throws {
        let url = try await Self.makeFixedLayoutEPUB(pageCount: 1)
        await FixedLayoutEPUBRenderer.shared.purge()
        defer { Task { await FixedLayoutEPUBRenderer.shared.purge() } }

        let image = await FixedLayoutEPUBRenderer.shared.image(sourceURL: url, pageIndex: 5, targetWidth: 160)

        #expect(image == nil)
    }
}
