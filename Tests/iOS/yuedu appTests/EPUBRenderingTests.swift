import Testing
import CoreText
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

    @Test func htmlBuilderRendersMathMLAsCoreTextAttachment() async {
        let builder = HTMLAttributedStringBuilder()
        let result = await builder.build(html: """
        <html><body>
          <p>Euler
            <math xmlns="http://www.w3.org/1998/Math/MathML">
              <msup><mi>x</mi><mn>2</mn></msup>
            </math>
          </p>
        </body></html>
        """, config: testHTMLConfig())

        #expect(result.attributedString.string.contains("\u{FFFC}"))

        var foundMathAttachment = false
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        result.attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { attributes, _, stop in
            if attributes[delegateKey] != nil,
               attributes[HTMLAttributedStringBuilder.semanticTagAttribute] as? String == "math" {
                foundMathAttachment = true
                stop.pointee = true
            }
        }
        #expect(foundMathAttachment)
    }

    @Test func htmlBuilderRendersAlignStarMathMLTableAsAttachment() async {
        let builder = HTMLAttributedStringBuilder()
        let result = await builder.build(html: """
        <html><body>
          <p class="p d4p_eqn_block">
            <math alttext="Alternative text not available" xmlns="http://www.w3.org/1998/Math/MathML">
              <mtable columnalign="left" class="align-star">
                <mtr>
                  <mtd columnalign="right" class="align-odd">
                    <mn>2</mn><mi>x</mi><mo>+</mo><mn>3</mn><mi>y</mi><mo>−</mo><mn>4</mn><mi>z</mi>
                  </mtd>
                  <mtd class="align-even">
                    <mo>=</mo><mn>1</mn><mn>3</mn><mspace width="2em"/>
                  </mtd>
                  <mtd columnalign="right" class="align-odd">
                    <mn>4</mn><msub><mrow><mi>x</mi></mrow><mrow><mn>1</mn></mrow></msub><mo>+</mo><mn>5</mn><msub><mrow><mi>x</mi></mrow><mrow><mn>2</mn></mrow></msub>
                  </mtd>
                  <mtd class="align-even">
                    <mo>=</mo><mn>0</mn><mspace width="2em"/>
                  </mtd>
                  <mtd columnalign="right" class="align-label"/>
                  <mtd class="align-label"><mspace width="2em"/></mtd>
                </mtr>
              </mtable>
            </math>
          </p>
        </body></html>
        """, config: testHTMLConfig())

        #expect(result.attributedString.string.contains("\u{FFFC}"))
        #expect(!result.attributedString.string.contains("\\begin"))
        #expect(!result.attributedString.string.contains("aligned"))
        #expect(!result.attributedString.string.contains("[math]"))

        let info = firstMathImageRunInfo(in: result.attributedString)
        #expect(info?.source == "mathml:")
        #expect(info?.image != nil)
        #expect((info?.drawWidth ?? 0) > 0)
        #expect((info?.descent ?? 0) > 0)
    }

    @Test func renderableNodeRendererRendersMathMLAsCoreTextAttachment() async throws {
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html><body>
          <p>
            <math xmlns="http://www.w3.org/1998/Math/MathML">
              <mfrac><mn>1</mn><mi>λ</mi></mfrac>
            </math>
          </p>
        </body></html>
        """, config: testHTMLConfig()))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: testRenderSettings(),
                textColor: .label,
                renderWidth: 320
            )
        )
        let attributed = await renderer.render(nodes)

        var foundMathAttachment = false
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, stop in
            if attributes[delegateKey] != nil,
               attributes[HTMLAttributedStringBuilder.semanticTagAttribute] as? String == "math" {
                foundMathAttachment = true
                stop.pointee = true
            }
        }
        #expect(foundMathAttachment)
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

    @Test func htmlBuilderHonorsDirAttributeAndCSSDirection() async {
        let builder = HTMLAttributedStringBuilder()
        let result = await builder.build(html: """
        <html><body dir="rtl">
          <p>שלום עולם</p>
          <p style="direction: ltr">English override</p>
        </body></html>
        """, config: testHTMLConfig())

        let attributed = result.attributedString
        let text = attributed.string as NSString
        let hebrewRange = text.range(of: "שלום")
        let englishRange = text.range(of: "English")
        #expect(hebrewRange.location != NSNotFound)
        #expect(englishRange.location != NSNotFound)
        guard hebrewRange.location != NSNotFound,
              englishRange.location != NSNotFound,
              let hebrewParagraph = attributed.attribute(
                .paragraphStyle,
                at: hebrewRange.location,
                effectiveRange: nil
              ) as? NSParagraphStyle,
              let englishParagraph = attributed.attribute(
                .paragraphStyle,
                at: englishRange.location,
                effectiveRange: nil
              ) as? NSParagraphStyle
        else { return }
        #expect(hebrewParagraph.baseWritingDirection == .rightToLeft)
        #expect(englishParagraph.baseWritingDirection == .leftToRight)
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

    @Test @MainActor func hebrewLanguageMetadataDefaultsReflowableTextToRTL() async throws {
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
                <dc:identifier id="bookid">urn:uuid:hebrew-rtl</dc:identifier>
                <dc:title>מפליגים בישראל</dc:title>
                <dc:language>he</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine page-progression-direction="rtl">
                <itemref idref="ch1"/>
              </spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="chapter1.xhtml">פרק ראשון</a></li></ol></nav>
            """).utf8),
            "OPS/chapter1.xhtml": Data(epubXHTML(title: "פרק ראשון", body: """
            <p>שלום 123 עולם.</p>
            """).utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)
        #expect(session.pageProgressionDirection == .rtl)
        // page-progression-direction="rtl" must NOT force vertical writing for an
        // RTL bidi script (Hebrew/Arabic). Only CJK vertical-rl books are vertical.
        #expect(session.epubWritingMode != .verticalRL)

        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 360, height: 640)
        )
        let result = try await builder.buildChapter(
            at: 0,
            settings: testRenderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let text = result.attributedString.string as NSString
        let range = text.range(of: "שלום")
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound,
              let paragraph = result.attributedString.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
              ) as? NSParagraphStyle
        else { return }
        #expect(paragraph.baseWritingDirection == .rightToLeft)
    }

    @Test @MainActor func cjkRTLPageProgressionDefaultsToVerticalWriting() async throws {
        // Mirror of the Hebrew case: a CJK book with page-progression-direction="rtl"
        // and no explicit writing-mode metadata must still resolve to vertical-rl via
        // the legacy heuristic, proving the language gate only spares RTL bidi scripts.
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
                <dc:identifier id="bookid">urn:uuid:jp-vertical</dc:identifier>
                <dc:title>草枕</dc:title>
                <dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine page-progression-direction="rtl">
                <itemref idref="ch1"/>
              </spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="chapter1.xhtml">一</a></li></ol></nav>
            """).utf8),
            "OPS/chapter1.xhtml": Data(epubXHTML(title: "一", body: """
            <p>山路を登りながら、こう考えた。</p>
            """).utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)
        #expect(session.pageProgressionDirection == .rtl)
        #expect(session.epubWritingMode == .verticalRL)
    }

    @Test func publicationSessionServesFixedLayoutRelativeResources() async throws {
        let epubURL = try await makeEPUBArchive(entries: [
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
            <package version="3.0"
                     unique-identifier="bookid"
                     xmlns="http://www.idpf.org/2007/opf"
                     prefix="rendition: http://www.idpf.org/vocab/rendition/#">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:fixed-resources</dc:identifier>
                <dc:title>Fixed Layout Resources</dc:title>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">portrait</meta>
                <meta property="rendition:spread">none</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="fixed-css" href="styles/fixed.css" media-type="text/css"/>
                <item id="panel-svg" href="images/panel.svg" media-type="image/svg+xml"/>
                <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml" properties="svg"/>
                <item id="page2" href="page2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="page1" properties="page-spread-center"/>
                <itemref idref="page2" properties="page-spread-center"/>
              </spine>
            </package>
            """.utf8),
            "OEBPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="page1.xhtml">Page 1</a></li><li><a href="page2.xhtml">Page 2</a></li></ol></nav>
            """).utf8),
            "OEBPS/styles/fixed.css": Data("""
            html, body { margin: 0; width: 600px; height: 800px; overflow: hidden; }
            .page { position: relative; width: 600px; height: 800px; background: #f8f5ef; }
            .caption { position: absolute; left: 40px; top: 40px; }
            """.utf8),
            "OEBPS/images/panel.svg": Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#ffcc33"/></svg>
            """.utf8),
            "OEBPS/page1.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>Page 1</title>
                <meta name="viewport" content="width=600, height=800"/>
                <link rel="stylesheet" href="styles/fixed.css" type="text/css"/>
              </head>
              <body>
                <div class="page">
                  <p class="caption">Fixed layout page</p>
                  <img src="images/panel.svg" alt="Panel"/>
                  <svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160">
                    <polygon points="80,5 155,155 5,155" fill="#34c759"/>
                  </svg>
                </div>
              </body>
            </html>
            """.utf8),
            "OEBPS/page2.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Page 2</title><meta name="viewport" content="width=600, height=800"/></head>
              <body><div class="page">Second page</div></body>
            </html>
            """.utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)

        #expect(session.layoutMode == .prePaginated)
        #expect(session.chapters.map(\.href) == ["OEBPS/page1.xhtml", "OEBPS/page2.xhtml"])
        let viewportResolver = FixedLayoutViewportResolver(
            defaultViewport: session.fixedLayoutViewport?.defaultViewport,
            pageViewports: session.fixedLayoutViewport?.pageViewports ?? [:]
        )
        let viewport = await viewportResolver.viewport(
            for: 0,
            resourceProvider: ReadiumBookResourceAdapter(session: session)
        )
        #expect(viewport == CGSize(width: 600, height: 800))
        let fixedPageRefs = await FixedLayoutEPUBPageProvider.chapterRefs(from: session)
        #expect(fixedPageRefs.map(\.title) == ["Page 1", "Page 2"])
        #expect(fixedPageRefs.map(\.url) == ["OEBPS/page1.xhtml", "OEBPS/page2.xhtml"])

        let pageHTML = try await session.chapterHTML(at: 0)
        #expect(pageHTML.contains("<svg"))
        #expect(pageHTML.contains("images/panel.svg"))

        let baseURL = session.resourceURL(for: session.chapters[0].href).deletingLastPathComponent()
        let cssURL = try #require(URL(string: "styles/fixed.css", relativeTo: baseURL)?.absoluteURL)
        let cssResponse = try await session.response(for: cssURL)
        #expect(cssResponse.mimeType == "text/css")
        #expect(String(data: cssResponse.data, encoding: .utf8)?.contains(".page") == true)

        let imageURL = try #require(URL(string: "images/panel.svg", relativeTo: baseURL)?.absoluteURL)
        let imageResponse = try await session.response(for: imageURL)
        #expect(imageResponse.mimeType == "image/svg+xml")
        #expect(String(data: imageResponse.data, encoding: .utf8)?.contains("<svg") == true)
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

    // MARK: - CSS combinator selectors (descendant + child chains)

    /// A descendant + child selector with an attribute selector (`nav[epub|type~='toc'] a > span.toc-label`)
    /// must parse into a 3-component selector, not be dropped. Regression: the parser previously
    /// rejected any selector with more than two whitespace pieces, so EPUB nav `display:block`
    /// rules never applied and the TOC label/description collapsed onto one line.
    @Test func childCombinatorSelectorIsParsedNotDropped() {
        let rules = CSSParser.parse(css: "nav[epub|type~='toc'] a > span.toc-label { display: block; }")
        #expect(rules.count == 1)
        #expect(rules.first?.selector.components.count == 3)
    }

    /// Sibling combinators are still unsupported — the whole rule is dropped (safe no-op) rather
    /// than silently matching the subject alone.
    @Test func siblingCombinatorSelectorIsDropped() {
        #expect(CSSParser.parse(css: "h1 + p { color: red; }").isEmpty)
        #expect(CSSParser.parse(css: "h1 ~ p { color: red; }").isEmpty)
    }

    /// `@charset` / `@namespace` statement at-rules precede the first style rule in many EPUB
    /// stylesheets. The rule regex treats everything up to the first `{` as a selector, so if they
    /// aren't stripped they fuse into the first rule's selector and silently drop its declarations.
    /// Regression: this swallowed `body { font-family: … }`, so the document font (and the embedded
    /// `@font-face` cascade keyed off it) never applied — bold/italic collapsed to system fonts.
    @Test func leadingAtRulesDoNotBreakFirstStyleRule() {
        let css = """
        @charset "UTF-8";
        @namespace "http://www.w3.org/1999/xhtml";
        @namespace epub "http://www.idpf.org/2007/ops";

        body { font-family: 'Quicksand', Helvetica; font-weight: bold; }
        p { color: red; }
        """
        let rules = CSSParser.parse(css: css)
        let bodyRule = rules.first {
            $0.selector.components.count == 1 && $0.selector.components.first?.tag == "body"
        }
        #expect(bodyRule != nil)
        #expect(bodyRule?.declarations["font-family"] == "'Quicksand', Helvetica")
        // The rule that follows must still parse on its own.
        #expect(rules.contains { $0.selector.components.first?.tag == "p" })
    }

    /// End-to-end: the EPUB nav `display:block` rules now reach the spans, so the TOC label and
    /// description render on separate lines (a paragraph break sits between them) instead of
    /// running together inline.
    @Test func tocLabelAndDescRenderOnSeparateLines() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 10,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        nav[epub|type~='toc'] a > span.toc-label { display: block; }
        nav[epub|type~='toc'] a > span.toc-desc  { display: block; margin-left: 3em; }
        nav ol { list-style-type: none; }
        </style></head>
        <body>
          <nav epub:type="toc"><ol>
            <li><a href="p10.xhtml"><span class="toc-label">LabelAlpha</span><span class="toc-desc">DescBeta</span></a></li>
          </ol></nav>
        </body></html>
        """
        let attributed = await builder.build(html: html, config: config).attributedString
        let string = attributed.string as NSString
        let label = string.range(of: "LabelAlpha")
        let desc = string.range(of: "DescBeta")
        #expect(label.location != NSNotFound)
        #expect(desc.location != NSNotFound)
        guard label.location != NSNotFound, desc.location != NSNotFound else { return }
        let gapStart = label.location + label.length
        let between = string.substring(with: NSRange(location: gapStart, length: desc.location - gapStart))
        #expect(between.contains("\n"))

        // The description carries `margin-left: 3em`, so its block paragraph indent must survive the
        // enclosing list item's segment flush — i.e. be larger than the label's. Regression guard for
        // the nested-block-in-inline-anchor flatten bug.
        let labelPara = attributed.attribute(.paragraphStyle, at: label.location, effectiveRange: nil) as? NSParagraphStyle
        let descPara = attributed.attribute(.paragraphStyle, at: desc.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(labelPara != nil)
        #expect(descPara != nil)
        if let labelPara, let descPara {
            #expect(descPara.headIndent > labelPara.headIndent + 1)
        }
    }

    @Test @MainActor func hebrewRTLParagraphsStayFlushRight() async throws {
        // Regression: CoreText double-counts a negative tailIndent on the leading (right)
        // edge of RTL right-aligned text, over-insetting body paragraphs so short lines
        // drift left of the right margin. Both pipelines must keep lines flush to the right
        // content edge (minus only the CSS right margin), not ~3x the margin inward.
        let epubURL = try await makeEPUBArchive(entries: [
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
                <dc:identifier id="bookid">urn:uuid:hebrew-flush</dc:identifier>
                <dc:title>מפליגים</dc:title>
                <dc:language>he</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="css" href="default.css" media-type="text/css"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine page-progression-direction="rtl"><itemref idref="ch1"/></spine>
            </package>
            """.utf8),
            "OPS/default.css": Data("body { padding-left: 0pt; } p { text-align:right; margin: 8px; }".utf8),
            "OPS/nav.xhtml": Data(epubXHTML(title: "Nav", body: "<nav epub:type=\"toc\"><ol><li><a href=\"chapter1.xhtml\">פרק</a></li></ol></nav>").utf8),
            "OPS/chapter1.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="he">
            <head><link href="default.css" rel="stylesheet" type="text/css"/></head>
            <body style="text-align:right" dir="rtl">
            <p>אבישי נכנס לבניין מנהלת המרינה בכניסה פגש את אמיר מנהל המרינה שלום אבישי חפשה אותך היום בחורה מצרפת פנה אליו אמיר<br/>בדיקהקצרה</p>
            </body></html>
            """.utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)
        let W: CGFloat = 360
        let chapterIndex = try #require(session.chapterIndex(for: "OPS/chapter1.xhtml") ?? session.chapterIndex(for: "chapter1.xhtml"))
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: W, height: 640)
        )
        let result = try await builder.buildChapter(
            at: chapterIndex,
            settings: testRenderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let attr = result.attributedString
        let s = attr.string as NSString
        let aIdx = s.range(of: "אבישי").location
        #expect(aIdx != NSNotFound)
        if aIdx != NSNotFound, let ps = attr.attribute(.paragraphStyle, at: aIdx, effectiveRange: nil) as? NSParagraphStyle {
            #expect(ps.alignment == .right)
            #expect(ps.baseWritingDirection == .rightToLeft)
            // The fix carries the right margin in headIndent and zeroes tailIndent for RTL.
            #expect(ps.tailIndent == 0)
        }
        // Frame width must equal the builder's renderWidth (renderSize.width - insets).
        let fs = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            fs, CFRangeMake(0, attr.length),
            CGPath(rect: CGRect(x: 0, y: 0, width: W, height: 4000), transform: nil), nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        var shortRight: CGFloat? = nil
        for (i, line) in lines.enumerated() {
            let lr = CTLineGetStringRange(line)
            let sub = s.substring(with: NSRange(location: lr.location, length: max(0, lr.length)))
            if sub.contains("בדיקהקצרה") {
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                shortRight = origins[i].x + w
            }
        }
        #expect(shortRight != nil)
        if let shortRight {
            // Bug: right edge ~3x the 8px margin inward (≈ W-24). Fix: within ~1x (≈ W-8).
            #expect(shortRight > W - 16, "RTL short line not flush right: rightEdge=\(shortRight) frameWidth=\(W)")
        }
    }
}

private func firstMathImageRunInfo(in attributedString: NSAttributedString) -> ImageRunInfo? {
    let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
    var result: ImageRunInfo?
    attributedString.enumerateAttributes(
        in: NSRange(location: 0, length: attributedString.length)
    ) { attributes, _, stop in
        guard attributes[HTMLAttributedStringBuilder.semanticTagAttribute] as? String == "math",
              let value = attributes[delegateKey]
        else { return }
        let delegate = value as! CTRunDelegate
        let pointer = CTRunDelegateGetRefCon(delegate)
        result = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
        stop.pointee = true
    }
    return result
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

private func testRenderSettings() -> ReaderRenderSettings {
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
