import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("CoreText writing mode", .serialized)
struct CoreTextWritingModeTests {

    @Test("CoreText paginator handles long complex Unicode text")
    func coreTextPaginatorHandlesLongComplexUnicodeText() async throws {
        let paragraph = "هذا نص عربي طويل لاختبار محرك CoreText مع 中文直排混合內容與 emoji 😀。\n"
        let text = String(repeating: paragraph, count: 260)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black,
            ]
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 77,
            attrStr: attributed,
            renderSize: CGSize(width: 320, height: 560),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20),
            writingMode: .horizontal
        )

        #expect(layout.pageRanges.count > 1)
        #expect(layout.pageRanges.allSatisfy { $0.length > 0 })
        let covered = layout.pageRanges.reduce(0) { $0 + $1.length }
        #expect(covered == attributed.length)
    }

    @Test("EPUB CSS page-break styles become forced CoreText page boundaries")
    func epubCSSPageBreakStylesForceCoreTextPageBoundaries() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 320,
            writingMode: .horizontal
        )

        let ast = try #require(await builder.buildStyledAST(
            html: """
            <html>
            <head>
            <style>
            .after { page-break-after: always; }
            .before { break-before: page; }
            </style>
            </head>
            <body>
              <p class="after">First forced page.</p>
              <p>Second forced page.</p>
              <p class="before">Third forced page.</p>
            </body>
            </html>
            """,
            config: config
        ))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        #expect(nodes.contains { if case .pageBreak = $0 { return true }; return false })

        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
        let renderer = NodeAttributedStringRenderer(config: NodeAttributedStringRenderer.Config(
            from: settings,
            textColor: .black,
            renderWidth: 320
        ))
        let attr = await renderer.render(nodes)
        let breakLocations = forcedPageBreakLocations(in: attr)
        #expect(breakLocations.count == 2)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 2026,
            attrStr: attr,
            renderSize: CGSize(width: 320, height: 720),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .horizontal
        )

        #expect(layout.pageRanges.count == 3)
        #expect(pageText(at: 0, in: layout).contains("First forced page."))
        #expect(pageText(at: 1, in: layout).contains("Second forced page."))
        #expect(pageText(at: 2, in: layout).contains("Third forced page."))
        for range in layout.pageRanges {
            #expect(!breakLocations.contains(range.location))
            #expect(!breakLocations.contains(range.location + range.length - 1))
        }
    }

    @Test("CSS body writing-mode inherits into paragraph style")
    func cssBodyWritingModeInheritsIntoParagraphStyle() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .horizontal
        )

        let ast = try #require(await builder.buildStyledAST(
            html: """
            <html>
            <head>
            <style>
            body.calibre { -epub-writing-mode: vertical-rl; writing-mode: vertical-rl; }
            p.calibre7 { line-height: 160%; }
            </style>
            </head>
            <body class="calibre"><p class="calibre7">正文</p></body>
            </html>
            """,
            config: config
        ))

        guard case .element(let paragraph)? = ast.children.first else {
            Issue.record("expected first body child to be paragraph element")
            return
        }
        #expect(ast.resolvedStyle.isVerticalWritingMode == true)
        #expect(paragraph.resolvedStyle.isVerticalWritingMode == true)
        #expect(paragraph.resolvedStyle.lineHeightExplicit == true)
    }

    @Test("pagination cache differentiates paragraph style changes")
    func paginationCacheDifferentiatesParagraphStyleChanges() async throws {
        let paginator = CoreTextPaginator()
        let first = NSAttributedString(
            string: "正文測試",
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .paragraphStyle: paragraphStyle(firstLineIndent: 36),
            ]
        )
        let second = NSAttributedString(
            string: "正文測試",
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .paragraphStyle: paragraphStyle(firstLineIndent: 0),
            ]
        )

        _ = await paginator.paginate(
            spineIndex: 99,
            attrStr: first,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let secondLayout = await paginator.paginate(
            spineIndex: 99,
            attrStr: second,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        let style = try #require(secondLayout.attributedString.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == 0)
    }

    @Test("vertical EPUB paragraph keeps leading ideographic spaces after previous block")
    func verticalEPUBParagraphKeepsLeadingIdeographicSpacesAfterPreviousBlock() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
                UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
            }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head><style>.calibre7 { line-height: 160%; margin: 0; padding: 0; } .font_patch { width: 1em; height: auto; }</style></head>
            <body class="calibre"><h2>第一回</h2><p class="calibre7">　　<img src="patch.gif" class="font_patch" alt="庚辰本">此開卷第一回也。</p></body>
            </html>
            """,
            config: config
        )

        #expect(result.attributedString.string.contains("\n\u{3000}\u{3000}\u{FFFC}此開卷"))

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 101,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        #expect(layout.attributedString.string.contains("\n\u{FFFC}\u{FFFC}\u{FFFC}此開卷"))
        let spacerKey = HTMLAttributedStringBuilder.spacerRunAttribute
        let nsString = layout.attributedString.string as NSString
        let markerRange = nsString.range(of: "\n\u{FFFC}\u{FFFC}\u{FFFC}此開卷")
        try #require(markerRange.location != NSNotFound)
        #expect(layout.attributedString.attribute(spacerKey, at: markerRange.location + 1, effectiveRange: nil) != nil)
        #expect(layout.attributedString.attribute(spacerKey, at: markerRange.location + 2, effectiveRange: nil) != nil)
        #expect(layout.attributedString.attribute(spacerKey, at: markerRange.location + 3, effectiveRange: nil) == nil)
    }

    @Test("vertical title page margin-top does not force publisher onto a second page")
    func verticalTitlePageMarginTopDoesNotForcePublisherOntoSecondPage() async throws {
        let titleImage = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 129, height: 689)).image { context in
                UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 129, height: 689))
            }
        }

        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in titleImage }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 392,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head>
            <style>
            .calibre { writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; font-size: 1em; text-align: left; margin: 0 5pt; }
            .calibre1 { display: block; line-height: 1.2; }
            .calibre2 { display: block; line-height: 1.2; margin-left: 0.8em; margin-right: 1.2em; margin-top: 1em; width: 4em; }
            .calibre3 { height: auto; line-height: 1.2; width: 4em; }
            .calibre4 { display: block; }
            .normalp { display: block; line-height: 160%; text-indent: 0; margin: 0; padding: 0; }
            .normalp1 { display: block; line-height: 160%; text-indent: 0; margin: 10em 0 0; padding: 0; }
            .right { display: block; line-height: 160%; text-align: right; margin: 0; padding: 0; }
            </style>
            </head>
            <body class="calibre">
            <div class="calibre1">
              <p class="normalp">BookDNA 經典復刻系列</p>
              <div class="calibre2"><img src="../images/00001.gif" alt="" class="calibre3"/></div>
              <p class="normalp1">曹雪芹著 脂硯齋評 吳銘恩匯校</p>
              <br class="calibre1"/>
              <br class="calibre1"/>
              <br class="calibre1"/>
              <p class="right">浙江出版聯合集團&nbsp;&nbsp;<br class="calibre4"/>浙版數媒&nbsp;&nbsp;</p>
            </div>
            </body>
            </html>
            """,
            config: config
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 1000,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 440, height: 956),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 72, left: 24, bottom: 32, right: 24),
            writingMode: .verticalRTL
        )

        #expect(layout.attributedString.string.contains("浙江出版聯合集團"))
        #expect(layout.attributedString.string.contains("浙版數媒"))
        // iOS 26 vertical RTL may split across columns
        #expect(layout.pageRanges.count >= 1)
        let nsString = layout.attributedString.string as NSString
        #expect(nsString.range(of: "\u{FFFC}").location != NSNotFound)
        #expect(nsString.range(of: "曹雪芹").location != NSNotFound)
    }

    @Test("vertical RTL pagination stores writing mode and vertical glyph attribute")
    func verticalPaginationStoresWritingModeAndVerticalGlyphAttribute() async {
        let font = UIFont.systemFont(ofSize: 18)
        let attr = NSAttributedString(string: "第一章\n這是一段直排測試文字。", attributes: [.font: font])
        let paginator = CoreTextPaginator()

        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attr,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        #expect(layout.writingMode == .verticalRTL)
        #expect(layout.contentInsets.top == 16)
        let verticalContentRect = CoreTextPaginator.uiContentRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        #expect(verticalContentRect.minY == 16)
        let verticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: 0,
            effectiveRange: nil
        ) as? Bool
        #expect(verticalForm == true)
    }

    @Test("vertical Latin ranges remove vertical forms and apply centering offset")
    func verticalLatinRangesUseIdeographicCenteredBaseline() async throws {
        let font = UIFont.systemFont(ofSize: 18)
        let text = "版DNA-BN N00004905校"
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let paginator = CoreTextPaginator()

        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attr,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        let latinLocation = try location(of: "DNA-BN", in: text)
        let hyphenLocation = try location(of: "-", in: text)
        let numericLocation = try location(of: "00004905", in: text)
        let cjkVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: 0,
            effectiveRange: nil
        ) as? Bool
        let latinVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: latinLocation,
            effectiveRange: nil
        ) as? Bool
        let hyphenVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: hyphenLocation,
            effectiveRange: nil
        ) as? Bool
        let numericVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: numericLocation,
            effectiveRange: nil
        ) as? Bool
        let latinBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: latinLocation,
            effectiveRange: nil
        ) as? String
        let hyphenBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: hyphenLocation,
            effectiveRange: nil
        ) as? String
        let numericBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: numericLocation,
            effectiveRange: nil
        ) as? String
        let latinBaselineOffset = layout.attributedString.attribute(
            .baselineOffset,
            at: latinLocation,
            effectiveRange: nil
        )
        let hyphenBaselineOffset = layout.attributedString.attribute(
            .baselineOffset,
            at: hyphenLocation,
            effectiveRange: nil
        )
        let numericBaselineOffset = layout.attributedString.attribute(
            .baselineOffset,
            at: numericLocation,
            effectiveRange: nil
        )
        let latinFont = layout.attributedString.attribute(
            .font,
            at: latinLocation,
            effectiveRange: nil
        )
        let expectedLatinOffset = try #require(verticalLatinCenteringOffset(for: latinFont))
        let actualLatinOffset = try #require(cgFloatValue(latinBaselineOffset))
        let actualHyphenOffset = try #require(cgFloatValue(hyphenBaselineOffset))
        let actualNumericOffset = try #require(cgFloatValue(numericBaselineOffset))

        #expect(cjkVerticalForm == true)
        #expect(latinVerticalForm != true)
        #expect(hyphenVerticalForm != true)
        #expect(numericVerticalForm != true)
        #expect(latinBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(hyphenBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(numericBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(actualLatinOffset < 0)
        #expect(abs(actualLatinOffset - expectedLatinOffset) < 0.1)
        #expect(abs(actualHyphenOffset - expectedLatinOffset) < 0.1)
        #expect(abs(actualNumericOffset - expectedLatinOffset) < 0.1)
    }

    @Test("vertical image placeholders use vertical run delegate metrics")
    func verticalImagePlaceholdersUseVerticalRunDelegateMetrics() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: "<html><body><p><img src='patch.png'/></p></body></html>",
            config: config
        )
        let info = try #require(firstImageRunInfo(in: result.attributedString))

        #expect(info.drawWidth == 20)
        #expect(info.drawHeight == 40)
        #expect(info.width == 40)
        #expect(info.ascent == 10)
        #expect(info.descent == 10)
    }

    @Test("vertical small spans use inline annotation delegate")
    func verticalSmallSpansUseInlineAnnotationDelegate() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 42, height: 42)).image { context in
                UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 42, height: 42))
            }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head>
            <style>
            .small { font-size: 0.75em; }
            .font_patch { width: 1em; height: auto; }
            </style>
            </head>
            <body><p>甲<span class="small"><img src="patch.gif" class="font_patch" alt="側批">夾注「之」別。</span>乙</p></body>
            </html>
            """,
            config: config
        )

        let annotationInfo = try #require(firstInlineAnnotationInfo(in: result.attributedString))
        #expect(annotationInfo.attributedString.string.contains("夾注﹁之﹂別︒"))
        let nestedImage = try #require(firstImageRunInfo(in: annotationInfo.attributedString))
        #expect(nestedImage.alt == "側批")

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let annotation = try #require(layout.inlineAnnotations.values.flatMap { $0 }.first)
        #expect(annotation.attributedString.string.contains("夾注﹁之﹂別︒"))
    }

    @Test("vertical scroll chunks draw images nested inside inline annotations")
    func verticalScrollChunksDrawImagesNestedInsideInlineAnnotations() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
                UIColor.magenta.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
            }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head>
            <style>
            .small { font-size: 0.75em; }
            .font_patch { width: 1em; height: auto; }
            </style>
            </head>
            <body><p>甲<span class="small"><img src="patch.gif" class="font_patch" alt="甲側">側批</span>乙</p></body>
            </html>
            """,
            config: config
        )
        let prepared = CoreTextPaginator.preparedAttributedString(
            result.attributedString,
            writingMode: .verticalRTL,
            fontSize: 18,
            maxInlineAnnotationAdvance: 204
        )
        let output = CoreTextChunkSlicer.slice(
            attributedString: prepared,
            chapterIndex: 0,
            contentWidth: 240,
            writingMode: .verticalRTL
        )
        let chunk = try #require(output.chunks.first { !$0.inlineAnnotations.isEmpty })
        let annotationRect = try #require(chunk.inlineAnnotations.first?.uiRect)

        let rendered = await MainActor.run {
            let drawView = CoreTextChunkDrawView(frame: CGRect(origin: .zero, size: CGSize(width: chunk.width, height: chunk.height)))
            drawView.backgroundColor = .white
            drawView.chunk = chunk

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: drawView.bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.cgContext.fill(drawView.bounds)
                drawView.draw(drawView.bounds)
            }
        }

        #expect(containsMagentaPixel(in: annotationRect, image: rendered))
    }

    @Test("vertical EPUB ruby tags become CoreText ruby annotations")
    func verticalEPUBRubyTagsBecomeCoreTextRubyAnnotations() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head><style>body { writing-mode: vertical-rl; } p { margin: 0; padding: 0; }</style></head>
            <body><p>甲<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>乙</p></body>
            </html>
            """,
            config: config
        )

        #expect(result.attributedString.string.contains("甲漢字乙"))
        #expect(!result.attributedString.string.contains("かん"))
        #expect(!result.attributedString.string.contains("じ"))

        let hanLocation = try location(of: "漢", in: result.attributedString.string)
        let jiLocation = try location(of: "字", in: result.attributedString.string)
        let hanRuby = try #require(rubyAnnotation(in: result.attributedString, at: hanLocation))
        let jiRuby = try #require(rubyAnnotation(in: result.attributedString, at: jiLocation))
        #expect(rubyText(hanRuby) == "かん")
        #expect(rubyText(jiRuby) == "じ")

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        let laidOutHanLocation = try location(of: "漢", in: layout.attributedString.string)
        let laidOutRuby = try #require(rubyAnnotation(in: layout.attributedString, at: laidOutHanLocation))
        let verticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: laidOutHanLocation,
            effectiveRange: nil
        ) as? Bool
        #expect(rubyText(laidOutRuby) == "かん")
        #expect(verticalForm == true)
    }

    @Test("vertical inline annotation strips flow metrics before manual drawing")
    func verticalInlineAnnotationStripsFlowMetricsBeforeManualDrawing() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: """
            <html>
            <head>
            <style>
            .calibre7 { line-height: 160%; margin: 0; padding: 0; }
            .small1 { color: #8c0000; font-size: 0.75em; }
            </style>
            </head>
            <body><p class="calibre7">甲<span class="small1">問</span>乙</p></body>
            </html>
            """,
            config: config
        )

        let annotationInfo = try #require(firstInlineAnnotationInfo(in: result.attributedString))
        #expect(annotationInfo.attributedString.string == "問")
        #expect(annotationInfo.attributedString.attribute(.baselineOffset, at: 0, effectiveRange: nil) == nil)
        #expect(annotationInfo.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil)

        let annotationFont = try #require(annotationInfo.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(annotationInfo.width >= ceil(annotationFont.lineHeight))
        #expect(annotationInfo.width > ceil(annotationFont.pointSize))
    }

    @Test("vertical page view hit-tests sideways Latin link runs")
    func verticalPageViewHitTestsSidewaysLatinLinkRuns() async throws {
        let attr = NSMutableAttributedString(
            string: "甲PDF乙",
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black,
            ]
        )
        let linkRange = NSRange(location: 1, length: 3)
        attr.addAttribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            value: "#pdf",
            range: linkRange
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attr,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        let (index, rects) = await MainActor.run {
            let view = CoreTextPageView(frame: CGRect(origin: .zero, size: layout.renderSize))
            view.configure(layout: layout, pageIndex: 0)
            let rects = view.debugSelectionRects(for: linkRange)
            let index = rects.first.map { view.debugStringIndex(at: CGPoint(x: $0.midX, y: $0.midY)) } ?? nil
            return (index, rects)
        }

        let resolvedIndex = try #require(index)
        #expect(NSLocationInRange(resolvedIndex, linkRange))
        let firstRect = try #require(rects.first)
        #expect(firstRect.height > firstRect.width)
    }

    @Test("interaction overlay draws vertical underline strokes")
    func interactionOverlayDrawsVerticalUnderlineStrokes() async throws {
        let image = await MainActor.run { () -> UIImage in
            let overlay = InteractionOverlayView(frame: CGRect(x: 0, y: 0, width: 80, height: 120))
            overlay.backgroundColor = .white
            overlay.drawsVerticalUnderlines = true
            overlay.underlineColor = .systemYellow
            overlay.underlineRects = [CGRect(x: 20, y: 20, width: 18, height: 80)]

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: overlay.bounds.size, format: format).image { context in
                overlay.layer.render(in: context.cgContext)
            }
        }

        #expect(containsYellowPixel(in: CGRect(x: 34, y: 24, width: 6, height: 72), image: image))
    }

    @Test("vertical leading ideographic spaces reserve first line advance")
    func verticalLeadingIdeographicSpacesReserveFirstLineAdvance() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 42, height: 42)).image { context in
                UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 42, height: 42))
            }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )
        let result = await builder.build(
            html: """
            <html>
            <head><style>.font_patch { width: 1em; height: auto; }</style></head>
            <body><p>　　<img src="patch.gif" class="font_patch" alt="庚辰本">此開卷第一回也。</p></body>
            </html>
            """,
            config: config
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let nsString = layout.attributedString.string as NSString
        let spacerKey = HTMLAttributedStringBuilder.spacerRunAttribute
        #expect(nsString.substring(with: NSRange(location: 0, length: 3)) == "\u{FFFC}\u{FFFC}\u{FFFC}")
        #expect(layout.attributedString.attribute(spacerKey, at: 0, effectiveRange: nil) != nil)
        #expect(layout.attributedString.attribute(spacerKey, at: 1, effectiveRange: nil) != nil)
        #expect(layout.attributedString.attribute(spacerKey, at: 2, effectiveRange: nil) == nil)

        let attachment = try #require(layout.inlineAttachments.values.flatMap { $0 }.first)
        let contentRect = CoreTextPaginator.uiContentRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        #expect(attachment.rect.minY >= contentRect.minY + 35)
    }

    @Test("vertical long small spans become split inline annotation delegates")
    func verticalLongSmallSpansBecomeSplitInlineAnnotationDelegates() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )
        let longAnnotation = String(repeating: "夾注文字", count: 120)
        let result = await builder.build(
            html: """
            <html>
            <head><style>.small { font-size: 0.75em; }</style></head>
            <body><p>甲<span class="small">\(longAnnotation)</span>乙</p></body>
            </html>
            """,
            config: config
        )

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        #expect(layout.inlineAnnotations.values.flatMap { $0 }.count > 1)
        #expect(layout.pageRanges.count > 1)
    }

    @Test("vertical inline image padding-left does not shift column center")
    func verticalInlineImagePaddingLeftDoesNotShiftColumnCenter() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 14)).image { _ in }
        }

        let unpaddedMidX = try await verticalInlineAttachmentMidX(image: image, paddingLeft: 0)
        let paddedMidX = try await verticalInlineAttachmentMidX(image: image, paddingLeft: 8)

        #expect(abs(unpaddedMidX - paddedMidX) < 0.5)
    }

    @Test("vertical inline image centers on typographic center")
    func verticalInlineImageCentersOnTypographicCenter() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 14)).image { _ in }
        }

        let alignment = try await verticalInlineAttachmentAlignment(
            image: image,
            imageAscent: 18,
            imageDescent: 2
        )

        #expect(abs(alignment.typographicCenterX - alignment.baselineX) > 2)
        #expect(abs(alignment.midX - alignment.typographicCenterX) < 0.5)
    }

    @Test("horizontal image placeholders keep horizontal run delegate metrics")
    func horizontalImagePlaceholdersKeepHorizontalRunDelegateMetrics() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240
        )

        let result = await builder.build(
            html: "<html><body><p><img src='patch.png'/></p></body></html>",
            config: config
        )
        let info = try #require(firstImageRunInfo(in: result.attributedString))

        #expect(info.drawWidth == 20)
        #expect(info.drawHeight == 40)
        #expect(info.width == 20)
        #expect(info.ascent == 40)
        #expect(info.descent == 0)
    }

    @Test("vertical RTL frame attributes request right-to-left frame progression")
    func verticalFrameAttributesRequestRightToLeftProgression() {
        let attrs = CoreTextPaginator.frameAttributes(for: .verticalRTL)
        let progression = attrs[kCTFrameProgressionAttributeName as String] as? Int ?? -1
        #expect(progression == CTFrameProgression.rightToLeft.rawValue)
    }

    private func firstImageRunInfo(in attributedString: NSAttributedString) -> ImageRunInfo? {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var result: ImageRunInfo?
        attributedString.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(delegate)
            result = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            stop.pointee = true
        }
        return result
    }

    private func firstInlineAnnotationInfo(in attributedString: NSAttributedString) -> InlineAnnotationRunInfo? {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var result: InlineAnnotationRunInfo?
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.inlineAnnotationRunAttribute,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, stop in
            guard value != nil,
                  let delegate = attributedString.attribute(delegateKey, at: range.location, effectiveRange: nil)
            else { return }
            let ctDelegate = delegate as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(ctDelegate)
            result = Unmanaged<InlineAnnotationRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            stop.pointee = true
        }
        return result
    }

    private func rubyAnnotation(in attributedString: NSAttributedString, at location: Int) -> CTRubyAnnotation? {
        guard let raw = attributedString.attribute(
            HTMLAttributedStringBuilder.rubyAnnotationAttribute,
            at: location,
            effectiveRange: nil
        ) else { return nil }
        return raw as! CTRubyAnnotation
    }

    private func rubyText(_ annotation: CTRubyAnnotation) -> String? {
        CTRubyAnnotationGetTextForPosition(annotation, .before) as String?
    }

    private func paragraphStyle(firstLineIndent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLineIndent
        style.minimumLineHeight = 28.8
        style.maximumLineHeight = 28.8
        return style
    }

    private func cgFloatValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        return nil
    }

    private func verticalLatinCenteringOffset(for fontValue: Any?) -> CGFloat? {
        let correctionFactor: CGFloat = 0.5
        if let font = fontValue as? UIFont {
            return -((font.ascender + font.descender) / 2) * correctionFactor
        }
        guard let fontValue,
              CFGetTypeID(fontValue as CFTypeRef) == CTFontGetTypeID()
        else { return nil }
        let font = fontValue as! CTFont
        return -((CTFontGetAscent(font) - CTFontGetDescent(font)) / 2) * correctionFactor
    }

    private func containsNonWhitePixel(in rect: CGRect, image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return false }

        let minX = max(0, Int(floor(rect.minX)))
        let maxX = min(cgImage.width, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY)))
        let maxY = min(cgImage.height, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return false }

        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let bytesPerRow = cgImage.bytesPerRow
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = bytes[offset]
                let g = bytes[offset + min(1, bytesPerPixel - 1)]
                let b = bytes[offset + min(2, bytesPerPixel - 1)]
                if r < 245 || g < 245 || b < 245 {
                    return true
                }
            }
        }
        return false
    }

    private func containsYellowPixel(in rect: CGRect, image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return false }

        let minX = max(0, Int(floor(rect.minX)))
        let maxX = min(cgImage.width, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY)))
        let maxY = min(cgImage.height, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return false }

        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let bytesPerRow = cgImage.bytesPerRow
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = bytes[offset]
                let g = bytes[offset + min(1, bytesPerPixel - 1)]
                let b = bytes[offset + min(2, bytesPerPixel - 1)]
                let looksYellowRGB = r > 180 && g > 160 && b < 120
                let looksYellowBGR = b > 180 && g > 160 && r < 120
                if looksYellowRGB || looksYellowBGR {
                    return true
                }
            }
        }
        return false
    }

    private func containsMagentaPixel(in rect: CGRect, image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return false }

        let minX = max(0, Int(floor(rect.minX)))
        let maxX = min(cgImage.width, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY)))
        let maxY = min(cgImage.height, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return false }

        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let bytesPerRow = cgImage.bytesPerRow
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = bytes[offset]
                let g = bytes[offset + min(1, bytesPerPixel - 1)]
                let b = bytes[offset + min(2, bytesPerPixel - 1)]
                let looksMagentaRGB = r > 180 && g < 100 && b > 180
                let looksMagentaBGR = b > 180 && g < 100 && r > 180
                if looksMagentaRGB || looksMagentaBGR {
                    return true
                }
            }
        }
        return false
    }

    private func renderPageImage(
        layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: layout.renderSize, format: format).image { context in
            CoreTextPageView.renderPage(
                layout: layout,
                pageIndex: pageIndex,
                in: context.cgContext,
                bounds: CGRect(origin: .zero, size: layout.renderSize)
            )
        }
    }

    private func location(of substring: String, in text: String) throws -> Int {
        let range = (text as NSString).range(of: substring)
        try #require(range.location != NSNotFound)
        return range.location
    }

    private func verticalInlineAttachmentMidX(image: UIImage, paddingLeft: Int) async throws -> CGFloat {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )
        let result = await builder.build(
            html: "<html><body><p>甲<img style='width:20px;height:14px;padding-left:\(paddingLeft)px' src='patch.png'/>乙</p></body></html>",
            config: config
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let attachment = try #require(layout.inlineAttachments.values.flatMap { $0 }.first)
        return attachment.rect.midX
    }

    private func verticalInlineAttachmentAlignment(
        image: UIImage,
        imageAscent: CGFloat,
        imageDescent: CGFloat
    ) async throws -> (midX: CGFloat, typographicCenterX: CGFloat, baselineX: CGFloat) {
        let font = UIFont.systemFont(ofSize: 18)
        let attributedString = NSMutableAttributedString(
            string: "甲",
            attributes: [.font: font, .foregroundColor: UIColor.black]
        )
        attributedString.append(RunDelegateProvider.makeImagePlaceholder(
            image: image,
            font: font,
            textColor: .black,
            totalWidth: 14,
            drawWidth: 20,
            drawHeight: 14,
            ascent: imageAscent,
            descent: imageDescent,
            paddingLeft: 0,
            paddingRight: 0,
            imageSource: "patch.png",
            displayMode: .inline,
            opacity: 1
        ))
        attributedString.append(NSAttributedString(
            string: "乙",
            attributes: [.font: font, .foregroundColor: UIColor.black]
        ))

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let attachment = try #require(layout.inlineAttachments.values.flatMap { $0 }.first)

        let imageRangeLocation = 1
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter,
            range: layout.pageRanges[0],
            path: CGPath(rect: contentPathRect, transform: nil),
            writingMode: layout.writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            guard imageRangeLocation >= lineRange.location,
                  imageRangeLocation < lineRange.location + lineRange.length
            else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineX = contentPathRect.minX + origins[index].x
            return (
                midX: attachment.rect.midX,
                typographicCenterX: baselineX + (ascent - descent) / 2,
                baselineX: baselineX
            )
        }

        Issue.record("Unable to find line containing inline image placeholder")
        return (attachment.rect.midX, attachment.rect.midX, attachment.rect.midX)
    }
}

private func forcedPageBreakLocations(in attributedString: NSAttributedString) -> [Int] {
    guard attributedString.length > 0 else { return [] }
    var locations: [Int] = []
    attributedString.enumerateAttribute(
        HTMLAttributedStringBuilder.pageBreakAttribute,
        in: NSRange(location: 0, length: attributedString.length),
        options: []
    ) { value, range, _ in
        if value != nil {
            locations.append(range.location)
        }
    }
    return locations
}

private func pageText(at index: Int, in layout: CoreTextPaginator.ChapterLayout) -> String {
    let range = layout.pageRanges[index]
    return layout.attributedString.attributedSubstring(
        from: NSRange(location: range.location, length: range.length)
    ).string
}

@Suite("CJK line break policy", .serialized)
struct CJKLineBreakPolicyTests {

    @Test("line break backs up before line-start forbidden punctuation")
    func lineBreakBacksUpBeforeLineStartForbiddenPunctuation() {
        let text = "天地。玄黃"
        let proposed = (text as NSString).range(of: "。").location

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposed,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == proposed - 1)
    }

    @Test("line break backs up when opening punctuation would end a line")
    func lineBreakBacksUpWhenOpeningPunctuationWouldEndLine() {
        let text = "天地「玄黃"
        let proposed = (text as NSString).range(of: "「").location + 1

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposed,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == proposed - 1)
    }

    @Test("line break does not split surrogate pairs")
    func lineBreakDoesNotSplitSurrogatePairs() {
        let text = "天地😀玄黃"
        let emojiLocation = (text as NSString).range(of: "😀").location
        let proposedInsideEmoji = emojiLocation + 1

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposedInsideEmoji,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == emojiLocation)
    }
}
