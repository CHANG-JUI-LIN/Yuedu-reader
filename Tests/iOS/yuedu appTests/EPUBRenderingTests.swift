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
            isHorizontallyCentered: false,
            lineDash: []
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

    @Test func bodyBackgroundTakesPriorityOverSingleImagePage() async {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 18)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
        }

        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in
            switch source {
            case "bg.webp": background
            case "cover.webp": cover
            default: nil
            }
        }

        let result = await builder.build(html: """
        <html>
          <head>
            <style>
              body.intro {
                background-image: url("bg.webp");
                background-size: cover;
              }
            </style>
          </head>
          <body class="intro"><img src="cover.webp"/></body>
        </html>
        """, config: testHTMLConfig())

        #expect(result.pageBackgroundImage != nil)
        #expect(result.pageBackgroundImageSource == "bg.webp")
        #expect(result.imagePage == nil)
    }

    @Test func pageBackgroundImageUsesCoverSizing() {
        let rect = CoreTextPageView.backgroundImageRect(
            for: CGSize(width: 100, height: 50),
            in: CGRect(x: 0, y: 0, width: 50, height: 100)
        )

        #expect(abs(rect.minX + 75) < 0.001)
        #expect(abs(rect.minY) < 0.001)
        #expect(abs(rect.width - 200) < 0.001)
        #expect(abs(rect.height - 100) < 0.001)
    }

    @Test func importantBodyBackgroundColorIsAvailableToThePageRenderer() async throws {
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html>
          <body style="background-color: #352d2d !important">
            <p style="color: #fff">Title page</p>
          </body>
        </html>
        """, config: testHTMLConfig()))

        #expect(colorMatches(
            builder.pageBackgroundColor(from: ast),
            red: 53.0 / 255.0,
            green: 45.0 / 255.0,
            blue: 45.0 / 255.0,
            alpha: 1
        ))
    }

    @Test func importantStylesheetBackgroundBeatsNormalInlineBackground() async throws {
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html>
          <head><style>body { background-color: #352d2d !important; }</style></head>
          <body style="background-color: #ffffff">
            <p>Title page</p>
          </body>
        </html>
        """, config: testHTMLConfig()))

        #expect(colorMatches(
            builder.pageBackgroundColor(from: ast),
            red: 53.0 / 255.0,
            green: 45.0 / 255.0,
            blue: 45.0 / 255.0,
            alpha: 1
        ))
    }

    @Test func authoredNegativeTopMarginSurvivesIntoCoreTextParagraphStyle() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html>
          <head><style>.overlap { margin: -3em 0 3em 0; }</style></head>
          <body>
            <p>Heading</p>
            <p class="overlap">Decorative timeline marker</p>
          </body>
        </html>
        """, config: testHTMLConfig())
        let string = attributed.string as NSString
        let headingRange = string.range(of: "Heading")
        let markerRange = string.range(of: "Decorative timeline marker")
        let headingLocation = try #require(headingRange.location == NSNotFound ? nil : headingRange.location)
        let markerLocation = try #require(markerRange.location == NSNotFound ? nil : markerRange.location)
        let headingParagraph = try #require(
            attributed.attribute(.paragraphStyle, at: headingLocation, effectiveRange: nil) as? NSParagraphStyle
        )
        let markerParagraph = try #require(
            attributed.attribute(.paragraphStyle, at: markerLocation, effectiveRange: nil) as? NSParagraphStyle
        )
        let collapsedGap = headingParagraph.paragraphSpacing + markerParagraph.paragraphSpacingBefore

        #expect(abs(collapsedGap + 43) < 0.1)
    }

    @Test func authoredBodyBackgroundColorSurvivesReaderThemeUpdates() async throws {
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { context in
            UIColor(white: 0.45, alpha: 0.3).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in source == "dragon.png" ? texture : nil }
        let html = """
        <html>
          <body style="background-image: url('dragon.png'); background-color: #352d2d!important">
            <p style="color: #fff">Title page</p>
          </body>
        </html>
        """
        let ast = try #require(await builder.buildStyledAST(html: html, config: testHTMLConfig()))
        let rendered = await builder.build(html: html, config: testHTMLConfig())
        let pageBackgroundImage = await builder.pageBackgroundImage(from: ast)
        let pageBackgroundColor = builder.pageBackgroundColor(from: ast)
        #expect(pageBackgroundImage != nil)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: rendered.attributedString,
            imagePage: nil,
            pageBackgroundImage: pageBackgroundImage,
            pageBackgroundColor: pageBackgroundColor,
            anchorOffsets: [:],
            renderSize: CGSize(width: 390, height: 844),
            fontSize: 17,
            contentInsets: .init(top: 52, left: 24, bottom: 72, right: 24)
        )
        let updated = layout.withUpdatedAppearance(
            textColor: .black,
            backgroundColor: .white,
            readerBackgroundImage: nil
        )

        #expect(colorMatches(
            updated.backgroundColor,
            red: 53.0 / 255.0,
            green: 45.0 / 255.0,
            blue: 45.0 / 255.0,
            alpha: 1
        ))
    }

    @Test func tableModelPreservesCellLineBreakAndPerSideBorderColor() async throws {
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html>
          <head><style>
            table {
              border-top: 1px solid #111;
              border-right: 2px solid #222;
              border-bottom: 3px solid #333;
              border-left: 4px solid #444;
            }
            table td {
              color: #fff;
              border-left: 1px solid #fff;
              font-family: "HYWS";
              vertical-align: middle;
              padding: 2px 3px 4px 5px;
              line-height: 1.8em;
            }
            span.timebc {
              color: #ccc;
              font-family: "Sacred Hertz Straight";
              font-size: 0.8em;
            }
          </style></head>
          <body><table><tr><td>1.0<br/><span class="timebc">(2022.8.5)</span><sup><a class="duokan-footnote" href="#d1"><img src="note.png"/></a></sup></td></tr></table></body>
        </html>
        """, config: testHTMLConfig()))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let table = try #require(nodes.compactMap { node -> HTMLTableModel? in
            guard case .table(let table, _) = node else { return nil }
            return table
        }.first)
        let cell = try #require(table.rows.first?.cells.first)

        #expect(table.borderTop == 1)
        #expect(table.borderRight == 2)
        #expect(table.borderBottom == 3)
        #expect(table.borderLeft == 4)
        #expect(cell.text == "1.0\n(2022.8.5)")
        #expect(cell.fontFamilies == ["HYWS"])
        #expect(cell.verticalAlignment == .middle)
        #expect(cell.paddingTop == 2)
        #expect(cell.paddingRight == 3)
        #expect(cell.paddingBottom == 4)
        #expect(cell.paddingLeft == 5)
        #expect(abs((cell.lineHeight ?? 0) - 30.6) < 0.1)
        #expect(cell.textRuns.contains {
            $0.text == "◦" && $0.linkHref == "#d1" && $0.imageSource == "note.png"
        })
        let dateRun = try #require(cell.textRuns.first { $0.text.contains("2022.8.5") })
        #expect(dateRun.fontFamilies == ["Sacred Hertz Straight"])
        #expect(abs(dateRun.fontScale - 0.8) < 0.001)
        #expect(colorMatches(
            dateRun.textColor?.uiColor,
            red: 204.0 / 255.0,
            green: 204.0 / 255.0,
            blue: 204.0 / 255.0,
            alpha: 1
        ))
        #expect(colorMatches(
            cell.borderLeftColor?.uiColor,
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        ))
    }

    @Test @MainActor func borderlessTableRasterStaysFullyTransparent() throws {
        let table = HTMLTableModel(
            caption: nil,
            rows: [
                HTMLTableRow(cells: [
                    HTMLTableCell(text: "", columnSpan: 1, rowSpan: 1, isHeader: false)
                ])
            ]
        )
        let image = try #require(HTMLTableRasterizer.render(
            table: table,
            maxWidth: 240,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white
        ))

        #expect(!imageContainsVisiblePixel(image))
        #expect(image.size.width < 240)
    }

    @Test @MainActor func tableRasterDrawsAuthoredCellImages() throws {
        let authoredImage = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        var cell = HTMLTableCell(text: "", columnSpan: 1, rowSpan: 1, isHeader: false)
        cell.textRuns = [HTMLTableTextRun(
            text: "",
            fontScale: 1,
            fontFamilies: [],
            fontWeight: 400,
            isItalic: false,
            textColor: nil,
            linkHref: nil,
            imageSource: "time.png",
            imageAlt: "time",
            imageWidth: 20,
            imageHeight: 10
        )]
        let table = HTMLTableModel(
            caption: nil,
            rows: [HTMLTableRow(cells: [cell])]
        )
        let image = try #require(HTMLTableRasterizer.renderPages(
            table: table,
            maxWidth: 240,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white,
            imagesBySource: ["time.png": authoredImage]
        ).first?.image)

        #expect(imageContainsVisiblePixel(image))
    }

    @Test @MainActor func longTableRasterPagesKeepEveryAuthoredRow() {
        let rowCount = 37
        let table = HTMLTableModel(
            caption: nil,
            rows: (0..<rowCount).map { index in
                HTMLTableRow(cells: [
                    HTMLTableCell(
                        text: "Row \(index)",
                        columnSpan: 1,
                        rowSpan: 1,
                        isHeader: false
                    )
                ])
            }
        )
        let pages = HTMLTableRasterizer.renderPages(
            table: table,
            maxWidth: 240,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white
        )

        #expect(pages.count > 1)
        #expect(pages.flatMap { Array($0.rowRange) } == Array(0..<rowCount))
    }

    @Test @MainActor func tableRasterPreservesChapterAndFootnoteLinkRegions() async throws {
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html><body><table><tr>
          <td><a href="chapter.xhtml">Chapter</a></td>
          <td><a class="duokan-footnote" href="#d1"><img src="note.png"/></a></td>
        </tr></table></body></html>
        """, config: testHTMLConfig()))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let table = try #require(nodes.compactMap { node -> HTMLTableModel? in
            guard case .table(let table, _) = node else { return nil }
            return table
        }.first)

        let page = try #require(HTMLTableRasterizer.renderPages(
            table: table,
            maxWidth: 240,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white
        ).first)

        #expect(page.linkRegions.contains { $0.href == "chapter.xhtml" && !$0.rect.isEmpty })
        #expect(page.linkRegions.contains { $0.href == "#d1" && !$0.rect.isEmpty })
    }

    @Test @MainActor func actualHongwuEPUBKeepsBackdropLongTOCLinksAndTableFootnotes() async throws {
        let sourceURL = URL(fileURLWithPath: "/Users/zhangruilin/Desktop/Test document/EPUB Format/壹▪洪武大帝.epub")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 390, height: 844)
        )
        let settings = testRenderSettings()

        let frontispieceIndex = try #require(session.chapters.first { $0.title == "扉页" }?.index)
        let frontispiece = try await builder.buildChapter(
            at: frontispieceIndex,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        #expect(frontispiece.pageBackgroundImage != nil)
        #expect(colorMatches(
            frontispiece.pageBackgroundColor,
            red: 53.0 / 255.0,
            green: 45.0 / 255.0,
            blue: 45.0 / 255.0,
            alpha: 1
        ))
        let frontispieceTable = try #require(tableImageRunInfos(in: frontispiece.attributedString).first)
        #expect(frontispieceTable.drawWidth < 200)
        #expect(!frontispieceTable.allowsPreview)

        let productionNotesIndex = try #require(session.chapters.first { $0.title == "制作说明" }?.index)
        let productionNotes = try await builder.buildChapter(
            at: productionNotesIndex,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let productionTables = tableImageRunInfos(in: productionNotes.attributedString)
        #expect(productionTables.contains { info in
            !info.allowsPreview && info.linkRegions.contains { $0.href == "#d2" }
        })

        let tocIndex = try #require(session.chapters.first { $0.title == "目录" }?.index)
        let toc = try await builder.buildChapter(
            at: tocIndex,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let tocTables = tableImageRunInfos(in: toc.attributedString)
        #expect(tocTables.count > 1)
        #expect(tocTables.allSatisfy { !$0.allowsPreview })
        #expect(tocTables.flatMap(\.linkRegions).count >= 30)

        // Every in-book TOC entry must resolve back to a spine chapter — the hrefs are
        // obfuscated filenames (`_*:*….html`) that URL(string:) refuses to parse.
        let tocHref = try #require(session.chapters.first { $0.title == "目录" }?.href)
        let chapterHrefs = tocTables.flatMap(\.linkRegions).map(\.href).filter { !$0.hasPrefix("#") }
        #expect(chapterHrefs.count >= 30)
        for href in chapterHrefs {
            let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: tocHref)
            let match = session.chapterIndex(for: resolved) ?? session.chapterIndex(for: href)
            #expect(match != nil, "TOC link did not resolve: \(href)")
        }
    }

    // MARK: - Obfuscated-filename TOC links (洪武大帝 idiom, self-contained)

    @Test @MainActor
    func obfuscatedFilenameTOCTableLinksResolveAndCarryTapTargets() async throws {
        let chapterName = "_**::ch:one*::.html"
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
            <package version="2.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:obfuscated-toc</dc:identifier>
                <dc:title>Obfuscated</dc:title>
                <dc:language>zh</dc:language>
              </metadata>
              <manifest>
                <item id="ml" href="Text/ml.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="Text/\(chapterName)" media-type="application/xhtml+xml"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              </manifest>
              <spine toc="ncx">
                <itemref idref="ml"/>
                <itemref idref="c1"/>
              </spine>
            </package>
            """.utf8),
            "OPS/toc.ncx": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head><meta name="dtb:uid" content="urn:uuid:obfuscated-toc"/></head>
              <docTitle><text>Obfuscated</text></docTitle>
              <navMap>
                <navPoint id="n1" playOrder="1"><navLabel><text>目录</text></navLabel><content src="Text/ml.xhtml"/></navPoint>
                <navPoint id="n2" playOrder="2"><navLabel><text>童年</text></navLabel><content src="Text/\(chapterName)"/></navPoint>
              </navMap>
            </ncx>
            """.utf8),
            "OPS/Text/ml.xhtml": Data(epubXHTML(title: "目录", body: """
            <table><tbody>
              <tr><td>❖</td><td><a href="\(chapterName)">童年</a></td></tr>
            </tbody></table>
            """).utf8),
            "OPS/Text/\(chapterName)": Data(epubXHTML(title: "童年", body: "<p>正文</p>").utf8)
        ])

        let session = try await PublicationSession.open(sourceURL: epubURL)
        #expect(session.chapters.count == 2)

        // 1. The naked anchor string (colon in its first path segment → URL(string:) == nil)
        //    must still resolve, raw and resolved against the TOC page's directory.
        let tocPageHref = session.chapters[0].href
        let resolved = EPUBStyleResolver.resolveImageHref(chapterName, chapterHref: tocPageHref)
        let matchedChapter = session.chapterIndex(for: resolved) ?? session.chapterIndex(for: chapterName)
        #expect(matchedChapter == 1)

        // 2. The rasterized TOC table carries a tappable hotspot for the link, and hit-testing
        //    the paginated attachment at the hotspot's center returns the same href.
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 390, height: 844)
        )
        let toc = try await builder.buildChapter(
            at: 0,
            settings: testRenderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let regions = tableImageRunInfos(in: toc.attributedString).flatMap(\.linkRegions)
        #expect(regions.contains { $0.href == chapterName })

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: toc.attributedString,
            anchorOffsets: [:],
            renderSize: CGSize(width: 390, height: 844),
            fontSize: 17,
            contentInsets: .init(top: 40, left: 20, bottom: 40, right: 20)
        )
        let attachments = layout.pageRanges.indices.flatMap { page in
            (layout.inlineAttachments[page] ?? []) + (layout.blockAttachments[page] ?? [])
        }
        let tapped = attachments.compactMap { attachment -> CoreTextPaginator.RenderedAttachment.LinkTarget? in
            guard !attachment.linkRegions.isEmpty else { return nil }
            let region = attachment.linkRegions[0]
            let center = CGPoint(
                x: attachment.rect.minX + (region.normalizedRect.midX * attachment.rect.width),
                y: attachment.rect.minY + (region.normalizedRect.midY * attachment.rect.height)
            )
            return attachment.linkTarget(at: center)
        }
        #expect(tapped.contains { $0.href == chapterName })

        // Exercise the real paged-view tap path. The table is one raster attachment whose links
        // live in `linkRegions`; checking only the attachment-wide `linkHref` made every TOC tap
        // fall through to image preview instead of navigation.
        let tableAttachment = try #require(attachments.first { !$0.linkRegions.isEmpty })
        let region = try #require(tableAttachment.linkRegions.first)
        let tapPoint = CGPoint(
            x: tableAttachment.rect.minX + region.normalizedRect.midX * tableAttachment.rect.width,
            y: tableAttachment.rect.minY + region.normalizedRect.midY * tableAttachment.rect.height
        )
        var tappedHref: String?
        let pageView = CoreTextPageView(frame: CGRect(origin: .zero, size: layout.renderSize))
        pageView.onInternalLinkTap = { tappedHref = $0 }
        pageView.configure(layout: layout, pageIndex: 0)
        pageView.debugHandleTap(at: tapPoint)
        #expect(tappedHref == chapterName)
    }

    @Test @MainActor func hongwuProfileTableUsesActualPageHeightBeforeSplitting() async throws {
        let rows = (0..<15).map { index in
            "<tr><td>▪</td><td>欄位\(index)</td><td>這是一段人物檔案內容</td></tr>"
        }.joined()
        let builder = HTMLAttributedStringBuilder()
        let ast = try #require(await builder.buildStyledAST(html: """
        <html><head><style>
        table { width: 100%; border: 1px solid #111; border-collapse: collapse; }
        td { padding: 6px; line-height: 1.8em; border-top: 1px solid #111; }
        </style></head><body><table>\(rows)</table></body></html>
        """, config: testHTMLConfig()))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let table = try #require(nodes.compactMap { node -> HTMLTableModel? in
            guard case .table(let table, _) = node else { return nil }
            return table
        }.first)

        let pages = HTMLTableRasterizer.renderPages(
            table: table,
            maxWidth: 350,
            maxPageHeight: 760,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white
        )
        #expect(pages.count == 1)
        #expect(pages.first?.rowRange == 0..<15)
    }

    // MARK: - CSS multiline comments (洪武大帝 css.css idiom)

    @Test func multilineCSSCommentDoesNotSwallowTheNextRule() {
        let rules = CSSParser.parse(css: """
        /*.p_title {
          background-color: #fff;
          color: #fff;
          text-align: center;
        }*/
        .p_title {
          color: #fff;
          background-color: #111;
          border-radius: 5em;
        }
        """)
        let declarations = rules.map(\.declarations)
        #expect(rules.count == 1)
        #expect(declarations.first?["background-color"] == "#111")
    }

    @Test func rulesInsideMultilineCommentsDoNotLeak() {
        let rules = CSSParser.parse(css: """
        /*
        table.scbg5 tr td {
          border: 1px solid #111;
        }
        .spanybk {
          border: 1px solid #111;
        }
        */
        .time-s {
          float: left;
          width: 35%;
        }
        """)
        #expect(rules.count == 1)
        #expect(rules.first?.declarations["width"] == "35%")
    }

    // MARK: - Inline per-side borders (.underline 题记 idiom)

    @Test func borderBottomOnlySpanRendersAsDashedUnderlineNotABox() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><head><style>
        .underline {
          padding-bottom: 1px;
          border-bottom: 1px dashed #111;
        }
        </style></head><body>
          <p>○　<span class="underline">一切的事情都从1328年的那个夜晚开始</span></p>
        </body></html>
        """, config: testHTMLConfig())

        let range = (attributed.string as NSString).range(of: "一切的事情")
        #expect(range.location != NSNotFound)
        let chip = try #require(attributed.attribute(
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? HTMLAttributedStringBuilder.InlineBorderBoxStyle)
        #expect(chip.edges == [.bottom])
        #expect(!chip.dash.isEmpty)
        #expect(chip.fillColor == nil)
    }

    @Test func fullBorderSpanKeepsClosedChipBox() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <p><span style="border: 1px solid #111; border-radius: 3em; padding: 2px 0.3em;">36</span></p>
        </body></html>
        """, config: testHTMLConfig())

        let range = (attributed.string as NSString).range(of: "36")
        #expect(range.location != NSNotFound)
        let chip = try #require(attributed.attribute(
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? HTMLAttributedStringBuilder.InlineBorderBoxStyle)
        #expect(chip.edges == .all)
        #expect(chip.dash.isEmpty)
    }

    @Test func backgroundOnlySpanGetsAFilledChip() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><head><style>
        .chapter1 span { background-color: #111; color: #fff; padding: 2px 0.4em; }
        </style></head><body>
          <p class="chapter1"><span>参考消息</span>　五年五个皇帝</p>
        </body></html>
        """, config: testHTMLConfig())

        let range = (attributed.string as NSString).range(of: "参考消息")
        #expect(range.location != NSNotFound)
        let chip = try #require(attributed.attribute(
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? HTMLAttributedStringBuilder.InlineBorderBoxStyle)
        #expect(chip.fillColor != nil)
        #expect(chip.edges.isEmpty || chip.borderWidth == 0)
    }

    // MARK: - Whitespace processing (mapChildren)

    @Test func ideographicSpaceAfterInlineChipIsContentNotFormatting() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><head><style>
        .chapter1 span { background-color: #111; color: #fff; padding: 2px 0.4em; }
        </style></head><body>
          <p class="chapter1"><span>参考消息</span>　五年五个皇帝</p>
        </body></html>
        """, config: testHTMLConfig())

        // The U+3000 between the chip and the heading is authored content, not collapsible
        // whitespace — trimming it made the chip's drawn padding overlap the heading glyphs.
        #expect(attributed.string.contains("参考消息\u{3000}五年五个皇帝"))
    }

    @Test func inlineFlowSpacesAroundInlineTagsSurvive() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <p>foo <b>bar</b> baz</p>
        </body></html>
        """, config: testHTMLConfig())

        #expect(attributed.string.contains("foo bar baz"))
    }

    @Test func sourceIndentAfterLineBreakDoesNotLeakALeadingSpace() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <p>line one<br/>
          line two</p>
        </body></html>
        """, config: testHTMLConfig())

        // The collapsed space after <br> would sit at the new line's start; browsers drop it.
        #expect(attributed.string.contains("line one\u{2028}line two"))
    }

    @Test func interBlockIndentationStaysDropped() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <div>
            <p>alpha</p>
            <p>beta</p>
          </div>
        </body></html>
        """, config: testHTMLConfig())

        // Source indentation between block siblings is formatting, never a space glyph.
        #expect(attributed.string.contains("alpha"))
        #expect(attributed.string.contains("beta"))
        #expect(!attributed.string.contains(" "))
    }

    // MARK: - Vertical chapter seal (.num idiom)

    @Test func narrowDisplayBlockSpanBecomesVerticalSeal() async throws {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><head><style>
        .chapter { text-align: right; }
        .num {
          display: block;
          border: 1px solid #111;
          border-radius: 3em;
          padding: 2px 0.3em;
          font-size: 0.6em;
          width: 1em;
        }
        </style></head><body>
          <h3 class="chapter"><span class="num">第一章</span><br/>童年</h3>
        </body></html>
        """, config: testHTMLConfig())

        // Per-character wrap: the seal renders one character per line.
        #expect(attributed.string.contains("第\n一\n章"))

        let range = (attributed.string as NSString).range(of: "第")
        #expect(range.location != NSNotFound)
        // The seal keeps its rounded-border block decoration over the stacked characters …
        let decoration = attributed.attribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            at: range.location,
            effectiveRange: nil
        ) as? HTMLAttributedStringBuilder.BlockRenderStyle
        #expect(decoration != nil)
        #expect((decoration?.borderRadius ?? 0) > 0)
        // … and the box hugs a one-character column, pinned to the left content edge the way
        // a browser positions a block box (inherited text-align must not push it right).
        #expect((decoration?.width ?? 0) < 34)
        #expect(decoration?.textAlign == .left)
        if let para = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle {
            #expect(para.alignment == .left)
        }
        // 童年 keeps the heading's own right alignment.
        let titleRange = (attributed.string as NSString).range(of: "童年")
        if titleRange.location != NSNotFound,
           let para = attributed.attribute(.paragraphStyle, at: titleRange.location, effectiveRange: nil) as? NSParagraphStyle {
            #expect(para.alignment == .right)
        }
    }

    @Test func imageOnlyPageUsesFullRenderBounds() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 2400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 2400))
        }
        let config = testHTMLConfig()
        let attr = NSAttributedString(
            string: "\u{FFFC}",
            attributes: [.font: UIFont.systemFont(ofSize: config.fontSize)]
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attr,
            imagePage: HTMLAttributedStringBuilder.ImagePage(source: "cover.webp", image: image),
            pageBackgroundImage: nil,
            anchorOffsets: [:],
            renderSize: CGSize(width: 944, height: 2048),
            fontSize: config.fontSize,
            contentInsets: .init(top: 140, left: 70, bottom: 120, right: 70)
        )

        let attachment = try #require(layout.blockAttachments[0]?.first)
        #expect(attachment.rect.minY < 1)
        #expect(attachment.rect.height > 2040)
        #expect(attachment.rect.width > 900)
        #expect(attachment.rect.minX < 24)
    }

    @Test func decoratedContainerKeepsOuterFrameWhenChildHasBlockDecoration() async throws {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 24)).image { context in
            UIColor.lightGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
        }

        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in source == "bg.webp" ? background : nil }

        var config = testHTMLConfig()
        config.renderWidth = 360
        let result = await builder.build(html: """
        <html>
          <head>
            <style>
              body.intro {
                background-image: url("bg.webp");
                background-size: cover;
              }
              div.zzxx {
                border: 1px #fff solid;
                background-color: rgba(202, 202, 202, .28);
                padding: 1em 2em;
                margin: 2em 10%;
              }
              hr {
                border: 0;
                border-top: 1px dashed #000;
                margin: 1em 0;
              }
            </style>
          </head>
          <body class="intro">
            <div class="zzxx">
              <p><ruby>制作信息<rt>Information</rt></ruby></p>
              <hr/>
              <p>版本：v1.0(2024.11.12)</p>
            </div>
          </body>
        </html>
        """, config: config)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 428, height: 956),
            fontSize: config.fontSize,
            contentInsets: .init(top: 52, left: 24, bottom: 72, right: 24)
        )

        var frames: [CoreTextPaginator.RenderedBlockRenderable] = []
        for renderables in layout.blockRenderables.values {
            for renderable in renderables {
                let hasFrame = renderable.imageAttachment == nil
                    && renderable.style.borderTopWidth > 0
                    && renderable.style.borderLeftWidth > 0
                    && renderable.style.backgroundFillColor != nil
                    && renderable.rect.width > 220
                if hasFrame {
                    frames.append(renderable)
                }
            }
        }

        let frame = try #require(frames.first, "expected parent .zzxx frame, got \(layout.blockRenderables)")
        #expect(frame.rect.width < 300, "expected .zzxx content box to keep CSS side margins, got \(frame.rect)")
        #expect(colorMatches(frame.style.borderTopColor, red: 1, green: 1, blue: 1, alpha: 1))
        #expect(colorMatches(frame.style.backgroundFillColor, red: 202.0 / 255.0, green: 202.0 / 255.0, blue: 202.0 / 255.0, alpha: 0.28))

        var hrStyles: [HTMLAttributedStringBuilder.HRDividerStyle] = []
        result.attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.hrDividerAttribute,
            in: NSRange(location: 0, length: result.attributedString.length),
            options: []
        ) { value, _, _ in
            if let style = value as? HTMLAttributedStringBuilder.HRDividerStyle {
                hrStyles.append(style)
            }
        }
        let hrStyle = try #require(hrStyles.first)
        #expect(!hrStyle.lineDash.isEmpty, "expected border-top: 1px dashed #000 to keep a dash pattern")
    }

    // The thread wrapper keeps its authored outer margins (`div.tk { margin: 1em }`); the old
    // spacing bloat came from fabricated blank paragraphs after every closed container, which
    // renderBlock no longer emits. Inside the thread, spacing stays compact, and the bubble's
    // padding+border share is structural (the drawn box extends outward by it), so it must
    // survive margin collapse — otherwise the bubble border overlaps the sender name above.
    @Test func chatBubbleWrapperKeepsAuthoredMarginsWithoutBlankParagraphs() async throws {
        var config = testHTMLConfig()
        config.renderWidth = 340
        let result = await HTMLAttributedStringBuilder().build(html: """
        <html>
          <head>
            <style>
              p { text-indent: 2em; line-height: 130%; }
              div.tk {
                page-break-inside: avoid;
                border: 1px solid transparent;
                padding: 3px 7px;
                margin: 1em 1em;
                line-height: 1;
              }
              .tk p {
                margin: 0;
                font-size: .9em;
                text-indent: 0;
              }
              div.ot {
                border: 1px solid #000;
                padding: 3px 7px;
                margin: 3px auto 3px -7px;
                display: inline-block;
                border-radius: 0px 10px 10px;
                background-color: #FFFF99;
                float: left;
              }
            </style>
          </head>
          <body>
            <p>就在这时，手机跳出了一条通知。</p>
            <div class="tk">
              <p>tls123</p>
              <div class="ot"><p>谢谢你。</p></div>
            </div>
            <p>突如其来的讯息映入眼帘。</p>
          </body>
        </html>
        """, config: config)

        let nsString = result.attributedString.string as NSString
        let nameRange = nsString.range(of: "tls123")
        let bubbleRange = nsString.range(of: "谢谢你")
        #expect(nameRange.location != NSNotFound)
        #expect(bubbleRange.location != NSNotFound)
        // No fabricated blank paragraphs anywhere (`</div>` no longer emits an extra "\n",
        // and the empty `clear:both` div renders to nothing).
        #expect(!result.attributedString.string.contains("\n\n"))
        if nameRange.location != NSNotFound,
           let nameStyle = result.attributedString.attribute(
                .paragraphStyle,
                at: nameRange.location,
                effectiveRange: nil
           ) as? NSParagraphStyle {
            // The thread's outer margin is collapsed into the preceding paragraph's spacing.
            #expect(nameStyle.paragraphSpacingBefore <= 5)
            #expect(nameStyle.paragraphSpacing <= config.fontSize * 0.15 + 0.5)
        }
        if bubbleRange.location != NSNotFound,
           let bubbleStyle = result.attributedString.attribute(
                .paragraphStyle,
                at: bubbleRange.location,
                effectiveRange: nil
           ) as? NSParagraphStyle {
            // Before: only the bubble's structural padding+border (3+1) survives compacting.
            #expect(bubbleStyle.paragraphSpacingBefore <= 8)
            // After: authored `.tk` margin-bottom (1em) + its padding+border (3+1) are preserved
            // on the thread's last paragraph — the thread↔body gap lives here now.
            #expect(bubbleStyle.paragraphSpacing >= config.fontSize - 0.5)
            #expect(bubbleStyle.paragraphSpacing <= config.fontSize + 4 + 0.5)
        }

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 390, height: 844),
            fontSize: config.fontSize,
            contentInsets: .init(top: 52, left: 24, bottom: 72, right: 24)
        )

        let nameLine = try #require(firstLineRect(containing: "tls123", in: layout))
        let bubbleLine = try #require(firstLineRect(containing: "谢谢你", in: layout))
        let afterLine = try #require(firstLineRect(containing: "突如其来", in: layout))
        #expect(nameLine.pageIndex == bubbleLine.pageIndex)
        #expect(bubbleLine.pageIndex == afterLine.pageIndex)
        #expect(bubbleLine.rect.minY - nameLine.rect.maxY < config.fontSize * 2)
        #expect(afterLine.rect.minY - bubbleLine.rect.maxY < config.fontSize * 6)
    }

    // duokan section-number headings draw a decorative frame via CSS background-image
    // (`h3 { background-image: url(边框.webp); background-size: 3em 3em; ... }`). The IR
    // pipeline must carry it into the block decoration box, positioned at the heading's
    // flow position (behind its text) — not dropped, and not pinned to the content top.
    @Test func headingBackgroundFrameImageFollowsFlowPosition() async throws {
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in source == "frame.webp" ? frame : nil }
        var config = testHTMLConfig()
        config.renderWidth = 392
        let result = await builder.build(html: """
        <html>
          <head>
            <style>
              h3 {
                color: #fff;
                font-size: 1em;
                text-align: center;
                margin: 0 auto;
                background-image: url("frame.webp");
                background-size: 3em 3em;
                background-position: center center;
                background-repeat: no-repeat;
                padding: 15%;
              }
            </style>
          </head>
          <body>
            <p>正文第一段，位于小节编号之前。</p>
            <h3>壹</h3>
            <p>正文第二段，位于小节编号之后。</p>
          </body>
        </html>
        """, config: config)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 428, height: 956),
            fontSize: config.fontSize,
            contentInsets: .init(top: 52, left: 24, bottom: 72, right: 12)
        )

        let frameBoxes = layout.blockRenderables
            .flatMap { pageIndex, renderables in
                renderables.compactMap { renderable -> (pageIndex: Int, rect: CGRect)? in
                    guard renderable.style.backgroundImage?.image != nil else { return nil }
                    return (pageIndex, renderable.rect)
                }
            }
        #expect(frameBoxes.count == 1, "expected the h3 frame box, got \(frameBoxes)")
        let frameBox = try #require(frameBoxes.first)
        let headingLine = try #require(firstLineRect(containing: "壹", in: layout))
        #expect(frameBox.pageIndex == headingLine.pageIndex)
        #expect(
            abs(frameBox.rect.midY - headingLine.rect.midY) < 60,
            "frame box should wrap the heading's flow position; box=\(frameBox.rect) line=\(headingLine.rect)"
        )
        let firstBodyLine = try #require(firstLineRect(containing: "正文第一段", in: layout))
        #expect(
            frameBox.pageIndex > firstBodyLine.pageIndex
                || frameBox.rect.minY > firstBodyLine.rect.minY,
            "frame box must not be pinned above the preceding paragraph"
        )
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
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <article>
            <table><caption>Schedule</caption><tr><th>Time</th><th>Title</th></tr><tr><td>09:00</td><td>Intro</td></tr></table>
          </article>
        </body></html>
        """, config: testHTMLConfig())

        #expect(attributed.string.contains("\u{FFFC}"))
        var foundTable = false
        attributed.enumerateAttribute(
            HTMLAttributedStringBuilder.semanticTagAttribute,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if value as? String == "table" {
                foundTable = true
                stop.pointee = true
            }
        }
        #expect(foundTable)
    }

    @Test func htmlBuilderRendersMathMLAsCoreTextAttachment() async {
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
          <p>Euler
            <math xmlns="http://www.w3.org/1998/Math/MathML">
              <msup><mi>x</mi><mn>2</mn></msup>
            </math>
          </p>
        </body></html>
        """, config: testHTMLConfig())

        #expect(attributed.string.contains("\u{FFFC}"))

        var foundMathAttachment = false
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, _, stop in
            if attributes[delegateKey] != nil,
               attributes[HTMLAttributedStringBuilder.semanticTagAttribute] as? String == "math" {
                foundMathAttachment = true
                stop.pointee = true
            }
        }
        #expect(foundMathAttachment)
    }

    @Test func emptyMathPreservesUsefulAltInsteadOfDisappearing() async {
        let attributed = await EPUBTestFixtures.renderIR(
            html: #"<p>Before <math alttext="quadratic expression"></math> after.</p>"#,
            config: EPUBTestFixtures.htmlConfig(renderWidth: 220)
        )

        #expect(attributed.string.contains("Before"))
        #expect(attributed.string.contains("[quadratic expression]"))
        #expect(attributed.string.contains("after"))
    }

    @Test func emptyMathWithoutUsefulAltUsesReadableGenericFallback() async {
        let attributed = await EPUBTestFixtures.renderIR(
            html: #"<p>Before <math alttext="Alternative text not available"></math> after.</p>"#,
            config: EPUBTestFixtures.htmlConfig(renderWidth: 220)
        )

        #expect(attributed.string.contains("Before"))
        #expect(attributed.string.contains("[math]"))
        #expect(attributed.string.contains("after"))
    }

    @Test func decoratedPhoneContainersFollowFlowPositions() async throws {
        let topBar = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 78)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 78))
        }
        let bottomBar = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 78)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 78))
        }

        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in
            switch source {
            case "top.webp": topBar
            case "bottom.webp": bottomBar
            default: nil
            }
        }

        var config = testHTMLConfig()
        config.renderWidth = 392
        let result = await builder.build(html: """
        <html>
          <head>
            <style>
              p { text-indent: 2em; line-height: 130%; }
              p.tt {
                text-indent: 0;
                text-align: center;
                margin: 2em 0;
              }
              div.ph {
                width: 80%;
                page-break-inside: avoid;
                border: 1px solid #000;
                margin: 1em auto;
                background-color: rgba(255, 255, 255, 0.28);
              }
              .ph p {
                text-indent: 2em;
                margin-left: 1em;
                margin-right: 1em;
              }
              .center { text-align: center; text-indent: 0; }
              img.width100 { width: 100%; }
            </style>
          </head>
          <body>
            <p class="tt">在灭亡的世界中存活的三种方法</p>
            <div class="ph">
              <img class="width100" src="top.webp"/>
              <p>想要在灭亡的世界中存活下来，有三种方法。事到如今我也忘了是哪几种，但有件事是肯定的。</p>
              <p class="center">《在灭亡的世界中存活的三种方法》<br/>完结</p>
              <img class="width100" src="bottom.webp"/>
            </div>
            <p>显示着网络小说页面的老旧智慧型手机，画面好像卷动得特别吃力。</p>
            <p>也就是说，小说已经结束了。</p>
            <div class="ph">
              <img class="width100" src="top.webp"/>
              <p class="center">《在灭亡的世界中存活的三种方法》</p>
              <p class="center">作者：tls123</p>
              <p class="center">共3,149话</p>
              <img class="width100" src="bottom.webp"/>
            </div>
            <p>长达三千一百四十九话的长篇奇幻小说。</p>
          </body>
        </html>
        """, config: config)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 428, height: 956),
            fontSize: config.fontSize,
            contentInsets: .init(top: 52, left: 24, bottom: 72, right: 12)
        )

        let phoneBoxes = layout.blockRenderables
            .sorted { $0.key < $1.key }
            .flatMap { pageIndex, renderables in
                renderables.compactMap { renderable -> (pageIndex: Int, rect: CGRect)? in
                    guard renderable.imageAttachment == nil,
                          renderable.style.borderTopWidth > 0,
                          renderable.style.borderBottomWidth > 0,
                          renderable.rect.width > 280
                    else { return nil }
                    return (pageIndex, renderable.rect)
                }
            }
            .sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.rect.minY < $1.rect.minY
            }

        #expect(phoneBoxes.count >= 2, "expected at least two phone containers, got \(phoneBoxes)")
        let firstBox = try #require(phoneBoxes.first)
        let secondBox = try #require(phoneBoxes.dropFirst().first)
        #expect(
            secondBox.pageIndex > firstBox.pageIndex || secondBox.rect.minY > firstBox.rect.maxY + 8,
            "phone containers should follow flow order, got \(phoneBoxes)"
        )
        #expect(
            Set(phoneBoxes.map { Int($0.rect.minY.rounded()) }).count > 1,
            "phone containers are pinned to the same page-top Y: \(phoneBoxes)"
        )

        let contentWidth = layout.renderSize.width - layout.contentInsets.left - layout.contentInsets.right
        let expectedPhoneWidth = contentWidth * 0.8
        for phoneBox in phoneBoxes.prefix(2) {
            #expect(
                abs(phoneBox.rect.width - expectedPhoneWidth) < 3,
                "phone container should keep CSS width:80%; expected \(expectedPhoneWidth), got \(phoneBox)"
            )
        }

        let phoneTextLine = try #require(firstLineRect(containing: "想要在灭亡", in: layout))
        #expect(phoneTextLine.pageIndex == firstBox.pageIndex)
        #expect(
            phoneTextLine.rect.minX >= firstBox.rect.minX - 2,
            "phone text should lay out inside the .ph frame; line=\(phoneTextLine.rect) frame=\(firstBox.rect)"
        )
        #expect(
            phoneTextLine.rect.maxX <= firstBox.rect.maxX + 2,
            "phone text should not spill past the .ph frame; line=\(phoneTextLine.rect) frame=\(firstBox.rect)"
        )

        let phoneImages = (layout.inlineAttachments.values.flatMap { $0 }
            + layout.blockAttachments.values.flatMap { $0 })
            .filter { attachment in
                Int(attachment.originalSize.width.rounded()) == 1000
                    && Int(attachment.originalSize.height.rounded()) == 78
            }
        #expect(phoneImages.count >= 4, "expected phone top/bottom images, got \(phoneImages)")
        for attachment in phoneImages.prefix(4) {
            #expect(
                attachment.rect.width <= expectedPhoneWidth + 3,
                "phone image should resolve width:100% against the .ph container, got \(attachment.rect)"
            )
        }
    }

    @Test func pageBreakInsideAvoidKeepsPhoneContainerTogether() async throws {
        let topBar = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 78)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 78))
        }
        let bottomBar = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 78)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 78))
        }

        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { source in
            switch source {
            case "top.webp": topBar
            case "bottom.webp": bottomBar
            default: nil
            }
        }

        var config = testHTMLConfig()
        config.renderWidth = 312
        let result = await builder.build(html: """
        <html>
          <head>
            <style>
              p { text-indent: 2em; line-height: 130%; }
              div.ph {
                width: 80%;
                page-break-inside: avoid;
                border: 1px solid #000;
                margin: 1em auto;
              }
              .ph p {
                text-indent: 2em;
                margin-left: 1em;
                margin-right: 1em;
              }
              .center { text-align: center; text-indent: 0; }
              img.width100 { width: 100%; }
            </style>
          </head>
          <body>
            <p>前文占位占位占位占位占位占位占位占位占位占位占位占位。</p>
            <p>前文占位占位占位占位占位占位占位占位占位占位占位占位。</p>
            <p>前文占位占位占位占位占位占位占位占位占位占位占位占位。</p>
            <div class="ph">
              <img class="width100" src="top.webp"/>
              <p>想要在灭亡的世界中存活下来，有三种方法。事到如今我也忘了是哪几种，但有件事是肯定的。</p>
              <p class="center">《在灭亡的世界中存活的三种方法》<br/>完结</p>
              <img class="width100" src="bottom.webp"/>
            </div>
            <p>后文继续。</p>
          </body>
        </html>
        """, config: config)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 348, height: 360),
            fontSize: config.fontSize,
            contentInsets: .init(top: 28, left: 18, bottom: 32, right: 18)
        )

        let avoidRanges = avoidPageBreakInsideRanges(in: layout.attributedString)
        #expect(!avoidRanges.isEmpty, "expected page-break-inside: avoid ranges")
        let boundaries = layout.pageRanges.dropLast().map { $0.location + $0.length }
        for boundary in boundaries {
            for avoidRange in avoidRanges {
                #expect(
                    !(avoidRange.location < boundary && boundary < avoidRange.location + avoidRange.length),
                    "page boundary \(boundary) should not split avoid range \(avoidRange); pageRanges=\(layout.pageRanges)"
                )
            }
        }
    }

    @Test func htmlBuilderRendersAlignStarMathMLTableAsAttachment() async {
        let attributed = await EPUBTestFixtures.renderIR(html: """
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

        #expect(attributed.string.contains("\u{FFFC}"))
        #expect(!attributed.string.contains("\\begin"))
        #expect(!attributed.string.contains("aligned"))
        #expect(!attributed.string.contains("[math]"))

        let info = firstMathImageRunInfo(in: attributed)
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

    @Test func rubyParagraphReservesAnnotationLineHeight() async throws {
        var config = testHTMLConfig()
        config.fontSize = 20
        config.lineHeightMultiple = 1.0
        config.paragraphSpacing = 0

        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html>
          <head>
            <style>
              p { line-height: 1; margin: 0; }
              rt { font-size: 0.8em; }
            </style>
          </head>
          <body>
            <p><ruby>制作信息<rt>Information</rt></ruby></p>
          </body>
        </html>
        """, config: config)

        let text = attributed.string as NSString
        let baseRange = text.range(of: "制作信息")
        #expect(baseRange.location != NSNotFound)
        let paragraphStyle = try #require(
            attributed.attribute(.paragraphStyle, at: baseRange.location, effectiveRange: nil) as? NSParagraphStyle
        )

        #expect(paragraphStyle.minimumLineHeight >= 30)
        #expect(paragraphStyle.maximumLineHeight == 0)
    }

    @Test func htmlBuilderEmitsEPUBMediaAttachmentForAudioVideo() async {
        let builder = HTMLAttributedStringBuilder()
        builder.mediaURLResolver = { "reader-book://test/\($0)" }
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body><audio title="Narration" controls="controls"><source src="audio/ch1.mp3" type="audio/mpeg"/></audio></body></html>
        """, config: testHTMLConfig(), builder: builder)

        var media: EPUBMediaAttachment?
        attributed.enumerateAttribute(
            HTMLAttributedStringBuilder.mediaAttachmentAttribute,
            in: NSRange(location: 0, length: attributed.length)
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
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body dir="rtl">
          <p>שלום עולם</p>
          <p style="direction: ltr">English override</p>
        </body></html>
        """, config: testHTMLConfig())
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
        let attributed = await EPUBTestFixtures.renderIR(html: html, config: config)
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

private func tableImageRunInfos(in attributedString: NSAttributedString) -> [ImageRunInfo] {
    let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
    var result: [ImageRunInfo] = []
    attributedString.enumerateAttributes(
        in: NSRange(location: 0, length: attributedString.length)
    ) { attributes, _, _ in
        guard attributes[HTMLAttributedStringBuilder.semanticTagAttribute] as? String == "table",
              let value = attributes[delegateKey]
        else { return }
        let delegate = value as! CTRunDelegate
        let pointer = CTRunDelegateGetRefCon(delegate)
        result.append(Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue())
    }
    return result
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

private func firstLineRect(
    containing needle: String,
    in layout: CoreTextPaginator.ChapterLayout,
    pageIndex: Int
) -> CGRect? {
    guard pageIndex < layout.pageRanges.count else { return nil }
    let range = layout.pageRanges[pageIndex]
    let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
        renderSize: layout.renderSize,
        contentInsets: layout.contentInsets,
        fontSize: layout.fontSize,
        writingMode: layout.writingMode
    )
    let frame = CTFramesetterCreateFrame(
        layout.framesetter,
        range,
        CGPath(rect: contentPathRect, transform: nil),
        nil
    )
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
    let nsString = layout.attributedString.string as NSString
    for (index, line) in lines.enumerated() {
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.location >= 0,
              lineRange.location + lineRange.length <= layout.attributedString.length
        else { continue }
        let text = nsString.substring(
            with: NSRange(location: lineRange.location, length: lineRange.length)
        )
        guard text.contains(needle) else { continue }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let origin = origins[index]
        return CGRect(
            x: contentPathRect.minX + origin.x,
            y: layout.renderSize.height - (contentPathRect.minY + origin.y + ascent),
            width: width,
            height: ascent + descent
        )
    }
    return nil
}

private func firstLineRect(
    containing needle: String,
    in layout: CoreTextPaginator.ChapterLayout
) -> (pageIndex: Int, rect: CGRect)? {
    for pageIndex in layout.pageRanges.indices {
        if let rect = firstLineRect(containing: needle, in: layout, pageIndex: pageIndex) {
            return (pageIndex, rect)
        }
    }
    return nil
}

private func avoidPageBreakInsideRanges(in attributedString: NSAttributedString) -> [NSRange] {
    guard attributedString.length > 0 else { return [] }
    var rangesByID: [String: NSRange] = [:]

    func collect(styleKey: NSAttributedString.Key, idKey: NSAttributedString.Key) {
        attributedString.enumerateAttribute(
            styleKey,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, range, _ in
            guard let style = value as? HTMLAttributedStringBuilder.BlockRenderStyle,
                  style.avoidsPageBreakInside,
                  let blockID = attributedString.attribute(
                      idKey,
                      at: range.location,
                      effectiveRange: nil
                  ) as? String
            else { return }

            if let existing = rangesByID[blockID] {
                rangesByID[blockID] = NSUnionRange(existing, range)
            } else {
                rangesByID[blockID] = range
            }
        }
    }

    collect(
        styleKey: HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
        idKey: HTMLAttributedStringBuilder.containerBlockRenderIDAttribute
    )
    collect(
        styleKey: HTMLAttributedStringBuilder.outerContainerBlockRenderStyleAttribute,
        idKey: HTMLAttributedStringBuilder.outerContainerBlockRenderIDAttribute
    )
    collect(
        styleKey: HTMLAttributedStringBuilder.blockRenderStyleAttribute,
        idKey: HTMLAttributedStringBuilder.blockRenderIDAttribute
    )

    return rangesByID.values.sorted {
        if $0.location != $1.location { return $0.location < $1.location }
        return $0.length < $1.length
    }
}

private func colorMatches(
    _ color: UIColor?,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    alpha: CGFloat,
    tolerance: CGFloat = 0.03
) -> Bool {
    guard let color else { return false }
    var actualRed: CGFloat = 0
    var actualGreen: CGFloat = 0
    var actualBlue: CGFloat = 0
    var actualAlpha: CGFloat = 0
    guard color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha) else {
        return false
    }
    return abs(actualRed - red) <= tolerance
        && abs(actualGreen - green) <= tolerance
        && abs(actualBlue - blue) <= tolerance
        && abs(actualAlpha - alpha) <= tolerance
}

private func imageContainsVisiblePixel(_ image: UIImage) -> Bool {
    guard let source = image.cgImage else { return false }
    let width = source.width
    let height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 }
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
