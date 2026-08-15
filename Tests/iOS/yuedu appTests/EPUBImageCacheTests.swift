import Testing
import CoreText
import Foundation
import ReadiumZIPFoundation
import UIKit
@testable import yuedu_app

/// `EPUBAttributedStringBuilder.loadImage` had no cache, so a chapter that referenced the same
/// illustration many times re-read and re-decoded it from the archive every single time. Measured
/// on device: 102 loads for 11 distinct images in one chapter (58 for 2 in another), 33–40ms per
/// archive read, which came to 97% of that chapter's render time.
///
/// These assert on call counts rather than milliseconds — a timing threshold would be flaky on
/// CI, while "how many archive reads for N references" is exactly the property that regressed.
@Suite("EPUB image cache", .serialized)
struct EPUBImageCacheTests {

    /// Chapter body referencing the same two images repeatedly, the shape that exposed the bug.
    private static func repeatedImageBody(repeats: Int) -> String {
        let paragraphs = (0..<repeats).map { index in
            """
            <p>Paragraph \(index) with a repeated ornament.</p>
            <p><img src="images/ornament.png" alt="ornament"/></p>
            <p><img src="images/divider.png" alt="divider"/></p>
            """
        }
        return paragraphs.joined(separator: "\n")
    }

    private static func onePixelPNG(red: UInt8, green: UInt8, blue: UInt8) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData() ?? Data()
    }

    private static func makeFixture(repeats: Int) async throws -> URL {
        try await makeImageCacheEPUBArchive(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:image-cache</dc:identifier>
                <dc:title>Image Cache</dc:title>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ornament" href="images/ornament.png" media-type="image/png"/>
                <item id="divider" href="images/divider.png" media-type="image/png"/>
                <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="page1"/>
              </spine>
            </package>
            """.utf8),
            "OEBPS/nav.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <head><title>Nav</title></head>
              <body><nav epub:type="toc"><ol><li><a href="page1.xhtml">Page 1</a></li></ol></nav></body>
            </html>
            """.utf8),
            "OEBPS/images/ornament.png": onePixelPNG(red: 255, green: 204, blue: 51),
            "OEBPS/images/divider.png": onePixelPNG(red: 52, green: 199, blue: 89),
            "OEBPS/page1.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Page 1</title></head>
              <body>\(repeatedImageBody(repeats: repeats))</body>
            </html>
            """.utf8),
        ])
    }

    @Test("a chapter reads each distinct image from the archive exactly once")
    @MainActor
    func repeatedImagesReadArchiveOncePerDistinctSource() async throws {
        let repeats = 12
        let epubURL = try await Self.makeFixture(repeats: repeats)
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 390, height: 844)
        )

        let leaves = RenderLeafMetrics()
        _ = try await ReaderDocumentTrace.$renderLeaves.withValue(leaves) {
            try await builder.buildChapter(
                at: 0,
                settings: imageCacheRenderSettings(),
                themeTextColor: .black,
                themeBackgroundColor: .white
            )
        }

        // The chapter references images 2×repeats times, over only two distinct sources.
        let references = leaves.callCount("imageLoad")
        try #require(references >= repeats)
        #expect(leaves.distinctCount("imageLoad") == 2)

        // Only the distinct sources may reach the archive. Without the cache, this equalled
        // `references` — that is the regression these numbers pin down.
        #expect(leaves.callCount("imageLoad.zip") == 2)
        #expect(leaves.callCount("imageLoad.decode") == 2)
        #expect(references > leaves.callCount("imageLoad.zip"))
    }

    @Test("a second chapter build reuses the images the first one decoded")
    @MainActor
    func secondBuildReusesCachedImages() async throws {
        let epubURL = try await Self.makeFixture(repeats: 4)
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 390, height: 844)
        )
        let settings = imageCacheRenderSettings()

        _ = try await builder.buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        // Re-rendering the same chapter — what a font-size or theme change triggers — must not
        // re-read the archive at all, because the cache is per book, not per build.
        let leaves = RenderLeafMetrics()
        _ = try await ReaderDocumentTrace.$renderLeaves.withValue(leaves) {
            try await builder.buildChapter(
                at: 0,
                settings: settings,
                themeTextColor: .black,
                themeBackgroundColor: .white
            )
        }

        #expect(leaves.callCount("imageLoad.zip") == 0)
        #expect(leaves.callCount("imageLoad.decode") == 0)
    }
}

private func imageCacheRenderSettings() -> ReaderRenderSettings {
    ReaderRenderSettings(
        theme: "test",
        textColor: .black,
        backgroundColor: .white,
        fontSize: 17,
        lineHeightMultiple: 1.5,
        lineSpacing: 0,
        paragraphSpacing: 8,
        letterSpacing: 0,
        marginH: 0,
        marginV: 0,
        footerHeight: 0,
        contentInsets: .zero,
        writingMode: .horizontal
    )
}

private func makeImageCacheEPUBArchive(entries: [String: Data]) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let archiveURL = root.appendingPathComponent("image-cache-\(UUID().uuidString).epub")
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
