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

    private static func makeFixedLayoutEPUB(
        pageCount: Int = 3,
        viewport: CGSize = CGSize(width: 600, height: 800),
        pageBody: (Int) -> String = { index in
            "<body style=\"margin:0\"><div style=\"width:600px;height:800px;background:#ffcc33\">Plate \(index + 1)</div></body>"
        },
        archiveURL: URL? = nil
    ) async throws -> URL {
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
                <meta name="viewport" content="width=\(Int(viewport.width)), height=\(Int(viewport.height))"/>
              </head>
              \(pageBody(index))
            </html>
            """.utf8)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        // Local publication metadata is keyed by filename; each fixture is a
        // different book, even when its temporary parent directory differs.
        let archiveURL = archiveURL ?? root.appendingPathComponent("fixed-layout-\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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

    @Test @MainActor
    func pageEnginePreloadPreservesValidAndOutOfRangeOutcomes() async throws {
        let url = try await Self.makeFixedLayoutEPUB(pageCount: 2)
        let session = try await PublicationSession.open(sourceURL: url)
        let engine = FixedLayoutPageEngine(session: session, renderSize: CGSize(width: 320, height: 600))
        #expect(await engine.preloadChapter(at: 0) == .laidOut)
        #expect(await engine.preloadChapter(at: 1) == .laidOut)
        #expect(await engine.preloadChapter(at: -1) == .outOfRange)
        #expect(await engine.preloadChapter(at: 2) == .outOfRange)
    }

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

    // MARK: Crop borders

    /// 固定頁閱讀器的「自動裁切留白邊框」要對固定版面 EPUB 也有效，放大重繪時也要裁到同一塊。
    @Test("Cropping a fixed-layout page removes its blank margins at every zoom width")
    @MainActor
    func cropsBlankMargins() async throws {
        let filename = "FixedLayoutEPUBCrop-\(UUID().uuidString).epub"
        let archiveURL = LocalMangaArchive.archiveURL(for: filename)
        _ = try await Self.makeFixedLayoutEPUB(
            pageCount: 1,
            viewport: CGSize(width: 400, height: 600),
            pageBody: { _ in
                // 400 × 600 的頁面，內容只佔中間 300 × 300。
                "<body style=\"margin:0;background:#ffffff\"><div style=\"position:absolute;left:50px;top:100px;width:300px;height:300px;background:#808080\"></div></body>"
            },
            archiveURL: archiveURL
        )
        FixedLayoutEPUBRenderer.shared.purge()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            Task { FixedLayoutEPUBRenderer.shared.purge() }
        }
        let page = FixedPage(
            id: 0,
            imageURL: archiveURL.absoluteString,
            headers: [:],
            localURL: nil,
            renderSource: .fixedLayoutEPUB(sourceFilename: filename, chapterIndex: 0)
        )

        let clock = ContinuousClock()
        let fullStart = clock.now
        let full = try #require(await FixedPageImageLoader.loadImage(for: page, targetWidth: 320, cropBorders: false))
        let fullElapsed = clock.now - fullStart
        let cropStart = clock.now
        let cropped = try #require(await FixedPageImageLoader.loadImage(for: page, targetWidth: 320, cropBorders: true))
        let cropElapsed = clock.now - cropStart
        let zoomStart = clock.now
        let zoomed = try #require(await FixedPageImageLoader.loadImage(for: page, targetWidth: 960, cropBorders: true))
        let zoomElapsed = clock.now - zoomStart
        print("⏱ fixedLayoutEPUB render full=\(fullElapsed) cropFirst=\(cropElapsed) cropZoomed=\(zoomElapsed)")

        #expect(abs(full.size.height / full.size.width - 1.5) < 0.05)
        // 對照：取樣本身可用——沒裁的頁中央是內容、上緣是留白。
        #expect(Self.contentGray.contains(Self.channel(full, x: 0.5, y: 0.4)))
        #expect(Self.channel(full, x: 0.5, y: 0.05) > 230)

        #expect(abs(cropped.size.width - 320) < 1)
        #expect(abs(cropped.size.height / cropped.size.width - 1.0) < 0.05)
        #expect(Self.contentGray.contains(Self.channel(cropped, x: 0.1, y: 0.1)))
        #expect(Self.contentGray.contains(Self.channel(cropped, x: 0.9, y: 0.9)))

        let croppedRatio = cropped.size.height / cropped.size.width
        #expect(abs(zoomed.size.height / zoomed.size.width - croppedRatio) < 0.02)
        #expect(Self.contentGray.contains(Self.channel(zoomed, x: 0.05, y: 0.05)))
        #expect(Self.contentGray.contains(Self.channel(zoomed, x: 0.95, y: 0.95)))
    }

    /// 測試頁內容的灰（#808080）；頁面留白是 255。
    private static let contentGray = 90...170

    /// 以左上為原點、依比例取樣一個像素的紅色通道（測試頁都是灰階）。
    /// 回傳 Int 而不是 tuple，失敗時訊息才看得到實際值；取不到回 -1。
    private static func channel(_ image: UIImage, x: CGFloat, y: CGFloat) -> Int {
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width
        let height = cgImage.height
        let px = min(width - 1, max(0, Int(CGFloat(width) * x)))
        let py = min(height - 1, max(0, Int(CGFloat(height) * y)))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return -1 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Int(buffer[(py * width + px) * 4])
        }
    }
}
