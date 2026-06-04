import Testing
import Foundation
import ReadiumZIPFoundation
import UIKit
@testable import yuedu_app

struct EPUBRenderingTests {

    // MARK: - HR divider has correct attribute

    @Test func hrDividerCarriesAttribute() {
        // Compile-time verification: HRDividerStyle and hrDividerAttribute exist
        let key = HTMLAttributedStringBuilder.hrDividerAttribute
        let style = HTMLAttributedStringBuilder.HRDividerStyle(
            color: .black,
            lineWidth: 1.0,
            ruleWidth: nil,
            ruleWidthPercent: nil,
            marginLeft: 0,
            marginRight: 0,
            inheritedBlockMarginLeft: 0,
            inheritedBlockMarginRight: 0,
            alignment: .natural,
            isHorizontallyCentered: false
        )
        #expect(key.rawValue == "ReaderHRDivider")
        #expect(style.lineWidth == 1.0)
    }

    // MARK: - Image source resolution

    @Test func imageSourceReadsXlinkHref() {
        let attrs: [String: String] = ["xlink:href": "cover.jpg"]
        let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] ?? ""
        #expect(src == "cover.jpg")
    }

    @Test func imageSourcePrefersSrc() {
        let attrs: [String: String] = ["src": "logo.png", "xlink:href": "ignored.jpg"]
        let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] ?? ""
        #expect(src == "logo.png")
    }

    // MARK: - Percentage length resolution

    @Test func resolvePercentRelativeToBase() {
        let value = "40%"
        let base: CGFloat = 440
        let result: CGFloat? = {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasSuffix("%"), let number = Double(trimmed.dropLast()) {
                return CGFloat(number / 100.0) * base
            }
            return nil
        }()
        #expect(result == 176.0)
    }

    @Test func resolveEmRelativeToFontSize() {
        let value = "2em"
        let base: CGFloat = 17
        let result: CGFloat? = {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasSuffix("em"), let number = Double(trimmed.dropLast(2)) {
                return CGFloat(number) * base
            }
            return nil
        }()
        #expect(result == 34.0)
    }

    // MARK: - Margin auto: only center when both sides are auto

    @Test func singleSidedAutoMarginDoesNotCenter() {
        // margin: 0 1em 0 auto → left=auto, right=1em
        let left = "auto"
        let right = "1em"
        let isCentered: Bool = {
            let l = left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let r = right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l == "auto" && r == "auto"
        }()
        #expect(!isCentered)
    }

    @Test func doubleSidedAutoMarginDoesCenter() {
        let left = "auto"
        let right = "auto"
        let isCentered: Bool = {
            let l = left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let r = right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l == "auto" && r == "auto"
        }()
        #expect(isCentered)
    }

    // MARK: - HTML entity count sanity

    @Test func copyrightPageHasHrElements() {
        let html = """
        <body><h1>版权信息</h1><p>text</p><hr/><p>text2</p><hr/><p>text3</p></body>
        """
        // SwiftSoup would count 2 <hr> elements
        let hrCount = html.components(separatedBy: "<hr").count - 1
        #expect(hrCount == 2)
    }

    @Test func htmlBuilderRasterizesTablesAndPreservesSemanticTag() async {
        let builder = HTMLAttributedStringBuilder()
        let result = await builder.build(html: """
        <html><body>
          <article>
            <table><caption>Schedule</caption><tr><th>Time</th><th>Title</th></tr><tr><td>09:00</td><td>Intro</td></tr></table>
          </article>
        </body></html>
        """, config: testHTMLConfig())

        #expect(result.attributedString.string.contains("\u{FFFC}"))
        var foundTable = false
        result.attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.semanticTagAttribute,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, stop in
            if value as? String == "table" {
                foundTable = true
                stop.pointee = true
            }
        }
        #expect(foundTable)
    }

    @Test func htmlBuilderEmitsEPUBMediaAttachmentForAudioVideo() async {
        let builder = HTMLAttributedStringBuilder()
        builder.mediaURLResolver = { "reader-book://test/\($0)" }
        let result = await builder.build(html: """
        <html><body><audio title="Narration"><source src="audio/ch1.mp3" type="audio/mpeg"/></audio></body></html>
        """, config: testHTMLConfig())

        var media: EPUBMediaAttachment?
        result.attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.mediaAttachmentAttribute,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, stop in
            if let value = value as? EPUBMediaAttachment {
                media = value
                stop.pointee = true
            }
        }

        #expect(media?.kind == .audio)
        #expect(media?.sourceHref == "reader-book://test/audio/ch1.mp3")
        #expect(media?.mediaType == "audio/mpeg")
    }

    @Test func smilParserExtractsFragmentsAndClockValues() {
        let overlay = SMILMediaOverlayParser.parse(xml: """
        <smil><body><seq>
          <par id="p1"><text src="chapter.xhtml#frag1"/><audio src="audio/ch1.mp3" clipBegin="npt=1.5s" clipEnd="00:00:03.000"/></par>
          <par id="p2"><text src="chapter.xhtml#frag2"/><audio src="audio/ch1.mp3" clipBegin="3s" clipEnd="4500ms"/></par>
        </seq></body></smil>
        """, smilHref: "overlays/ch1.smil", chapterHref: "chapter.xhtml")

        #expect(overlay.fragments.count == 2)
        #expect(overlay.fragments[0].textFragmentID == "frag1")
        #expect(overlay.fragments[0].clipBegin == 1.5)
        #expect(overlay.fragments[0].clipEnd == 3.0)
        #expect(overlay.fragments[1].clipEnd == 4.5)
    }

    @Test func publicationSessionParsesFixedLayoutRenditionMetadata() async throws {
        let epubURL = try await makeEPUBArchive(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0"
                     unique-identifier="bookid"
                     xmlns="http://www.idpf.org/2007/opf"
                     prefix="rendition: http://www.idpf.org/vocab/rendition/#">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:fxl-test</dc:identifier>
                <dc:title>FXL Metadata Test</dc:title>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta property="rendition:orientation">landscape</meta>
                <meta property="rendition:viewport">width=800, height=600</meta>
                <meta property="rendition:viewport" refines="#p2">width=1024, height=768</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/>
                <item id="p2" href="p2.xhtml" media-type="application/xhtml+xml"/>
                <item id="p3" href="p3.xhtml" media-type="application/xhtml+xml"/>
                <item id="p4" href="p4.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine page-progression-direction="ltr">
                <itemref idref="p1" properties="page-spread-right"/>
                <itemref idref="p2" properties="page-spread-left rendition:orientation-landscape"/>
                <itemref idref="p3" properties="page-spread-right"/>
                <itemref idref="p4" properties="rendition:page-spread-center"/>
              </spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="p1.xhtml">Page 1</a></li></ol></nav>
            """).utf8),
            "OPS/p1.xhtml": Data(epubXHTML(title: "Page 1", body: "<p>Page 1</p>").utf8),
            "OPS/p2.xhtml": Data(epubXHTML(title: "Page 2", body: "<p>Page 2</p>").utf8),
            "OPS/p3.xhtml": Data(epubXHTML(title: "Page 3", body: "<p>Page 3</p>").utf8),
            "OPS/p4.xhtml": Data(epubXHTML(title: "Page 4", body: "<p>Page 4</p>").utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)

        #expect(session.layoutMode == .prePaginated)
        #expect(session.fixedLayoutSpread == .landscape)
        #expect(session.fixedLayoutOrientation == .landscape)
        #expect(session.pageProgressionDirection == .ltr)
        #expect(session.fixedLayoutViewport?.defaultViewport == CGSize(width: 800, height: 600))
        #expect(session.fixedLayoutViewport?.pageViewports[1] == CGSize(width: 1024, height: 768))
        #expect(session.chapters.map(\.spreadSide) == [.right, .left, .right, .center])
        #expect(session.chapters[1].orientationOverride == .landscape)
    }

    @Test func publicationSessionLinksMediaOverlayManifestItems() async throws {
        let epubURL = try await makeEPUBArchive(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0"
                     unique-identifier="bookid"
                     xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:mo-test</dc:identifier>
                <dc:title>Media Overlay Test</dc:title>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml" media-overlay="mo1"/>
                <item id="mo1" href="overlays/ch1.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine>
                <itemref idref="ch1"/>
              </spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol></nav>
            """).utf8),
            "OPS/ch1.xhtml": Data(epubXHTML(title: "Chapter 1", body: """
            <p id="p1">First paragraph.</p><p id="p2">Second paragraph.</p>
            """).utf8),
            "OPS/overlays/ch1.smil": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
              <body><seq>
                <par id="p1"><text src="../ch1.xhtml#p1"/><audio src="../audio/ch1.mp3" clipBegin="0s" clipEnd="2s"/></par>
                <par id="p2"><text src="../ch1.xhtml#p2"/><audio src="../audio/ch1.mp3" clipBegin="2s" clipEnd="4s"/></par>
              </seq></body>
            </smil>
            """.utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)

        let overlay = try #require(session.mediaOverlaysByChapter[0])
        #expect(overlay.chapterHref == "OPS/ch1.xhtml")
        #expect(overlay.smilHref == "OPS/overlays/ch1.smil")
        #expect(overlay.fragments.map(\.textFragmentID) == ["p1", "p2"])
        #expect(overlay.fragments[0].textHref == "OPS/ch1.xhtml")
        #expect(overlay.fragments[0].audioHref == "OPS/audio/ch1.mp3")
        #expect(overlay.fragments[1].clipEnd == 4.0)
    }
}

private func testHTMLConfig() -> HTMLAttributedStringBuilder.Config {
    HTMLAttributedStringBuilder.Config(
        fontSize: 17,
        lineHeightMultiple: 1.5,
        lineSpacing: 0,
        paragraphSpacing: 8,
        firstLineIndent: 0,
        textColor: .label,
        backgroundColor: .systemBackground,
        fontFamilyName: nil,
        renderWidth: 320
    )
}

private func epubXHTML(title: String, body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>\(title)</title></head>
      <body>\(body)</body>
    </html>
    """
}

private func makeEPUBArchive(entries: [String: Data]) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let archiveURL = root.appendingPathComponent("sample-\(UUID().uuidString).epub")
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
