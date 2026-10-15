@testable import YueduCoreText
import CoreText
import Testing
import UIKit
import YueduCoreTextTypography
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserReaderTypographyTests {
    private let size = CGSize(width: 240, height: 500)
    private let css = "body,p { margin: 0; padding: 0; }"

    private func layout(_ html: String, config: BrowserLayoutConfig = .init()) throws -> BrowserLayoutDocument.BrowserLayoutPipelineResult {
        try BrowserLayoutDocument(html: html, cssTexts: [css], config: config).makeLayout(containerSize: size)
    }

    private func lines(_ box: BlockBox) -> [LayoutLine] {
        box.children.flatMap { lines($0) } + box.lines
    }

    @Test func readerSpacingChangesUsedGeometryWithoutChangingSource() throws {
        let html = "<p>" + String(repeating: "閱讀測試文字", count: 12) + "</p><p>末段</p>"
        let baseline = try layout(html)
        let lineSpaced = try layout(html, config: BrowserLayoutConfig(lineSpacing: 9))
        let paragraphSpaced = try layout(html, config: BrowserLayoutConfig(paragraphSpacing: 15))
        let letterSpaced = try layout(html, config: BrowserLayoutConfig(letterSpacing: 5))
        #expect(lineSpaced.sourceText == baseline.sourceText)
        #expect(paragraphSpaced.sourceText == baseline.sourceText)
        #expect(letterSpaced.sourceText == baseline.sourceText)
        let normalLines = lines(baseline.rootBox)
        let spacedLines = lines(lineSpaced.rootBox)
        #expect(spacedLines.count == normalLines.count)
        #expect(abs(spacedLines[0].height - normalLines[0].height - 9) < 0.01)
        #expect(abs(paragraphSpaced.rootBox.contentSize.height - baseline.rootBox.contentSize.height - 30) < 0.01)
        #expect(lines(letterSpaced.rootBox).count > normalLines.count)
    }

    @Test func boldLatinPrimaryKeepsCJKFallbackAtReaderSize() throws {
        let result = try layout("<p>Latin中文測試</p>", config: BrowserLayoutConfig(
            rootFontSize: 30, fontFamilies: ["Georgia"], isBold: true
        ))
        let line = try #require(lines(result.rootBox).first?.ctLine)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        #expect(runs.count >= 2)
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = try #require(attrs[kCTFontAttributeName] as? UIFont)
            #expect(abs(font.pointSize - 30) < 0.01)
            let traits = CTFontCopyTraits(font as CTFont) as NSDictionary
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold), "physical font=\(font.fontName), traits=\(traits)")
        }
    }

    @Test func embeddedResolverStillReceivesReaderBoldAndConcreteCascadeSizes() throws {
        let result = try layout("<p>Latin中文</p>", config: BrowserLayoutConfig(
            rootFontSize: 28, isBold: true,
            fontResolver: { _, _, _, size in UIFont(name: "Georgia", size: size) }
        ))
        let font = try #require(lines(result.rootBox).first?.runs.first?.font)
        #expect(font.familyName == "Georgia")
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let cascade = try #require(font.fontDescriptor.object(forKey: .cascadeList) as? [UIFontDescriptor])
        #expect(!cascade.isEmpty)
        #expect(cascade.allSatisfy { $0.pointSize == 28 })
    }

    @Test func regexMatchesAcrossInlineTagsAndChangesShapingAndPaint() async throws {
        let style = ReaderStyleRuleStyle(
            text: ReaderStyleTextStyle(colorHex: 0xFF0000, fontSize: 30, letterSpacing: 3, lineHeight: 60, underline: true),
            decoration: ReaderStyleDecorationStyle(backgroundColorHex: 0x00FF00)
        )
        let config = BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(configuration: configuration(pattern: "測試", style: style), appearance: .light, assetRevision: 0))
        let document = BrowserLayoutDocument(html: "<p>前測<span>試</span>後</p>", cssTexts: [css], config: config)
        let result = try document.makeLayout(containerSize: size)
        // Half-leading sums ascent and descent halves around the font's ink (YueduCoreText 0.5.0),
        // so the used height can land one ULP off (60.00000000000001).
        #expect(abs(lines(result.rootBox)[0].height - 60) < 0.01)
        let pages = try await document.renderPages(containerSize: size)
        let list = DisplayListBuilder.build(for: try #require(pages.first), sourceText: document.lastSourceText)
        let textItems = list.items.compactMap { item -> DisplayTextItem? in
            if case .text(let text) = item { return text }
            return nil
        }
        let highlighted = textItems.filter { $0.text.contains("測") || $0.text.contains("試") }
        #expect(highlighted.count == 2)
        var styledCount = 0
        for item in highlighted {
            let rendered = item.attributedText
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, _, _ in
                guard attrs[RegexHighlightDecoration.attributeKey] != nil else { return }
                styledCount += 1
                #expect((attrs[.font] as? UIFont)?.pointSize == 30)
                #expect(attrs[.foregroundColor] as? UIColor == .red)
                #expect((attrs[.kern] as? NSNumber)?.doubleValue == 3)
                #expect((attrs[.underlineStyle] as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
            }
        }
        #expect(styledCount == 2)
        let image = DisplayListRenderer.render(list, size: size)
        #expect(try countGreenPixels(image) > 100)
    }

    @Test func paragraphLocalRegexCannotBridgeAdjacentBlocks() throws {
        let style = ReaderStyleRuleStyle(text: ReaderStyleTextStyle(colorHex: 0xFF0000))
        let local = configuration(pattern: "甲\\s*乙", style: style, options: [.doesNotCrossParagraph])
        let crossing = configuration(pattern: "甲\\s*乙", style: style)
        let html = "<p>甲</p><p>乙</p>"
        let first = try layout(html, config: BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(configuration: local, appearance: .light, assetRevision: 0)))
        let second = try layout(html, config: BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(configuration: crossing, appearance: .light, assetRevision: 0)))
        #expect(first.sourceText == second.sourceText)
        #expect(!hasRedGlyph(in: first.rootBox))
        #expect(hasRedGlyph(in: second.rootBox))
    }

    @Test func regexStylesRubyBaseUsingChapterSourceOffsets() throws {
        let style = ReaderStyleRuleStyle(text: ReaderStyleTextStyle(colorHex: 0xFF0000, fontSize: 26, lineHeight: 70))
        let result = try layout("<p>前<ruby>漢<rt>kan</rt></ruby>後</p>", config: BrowserLayoutConfig(
            textTransform: BrowserReaderAttributes.transform(configuration: configuration(pattern: "漢", style: style), appearance: .light, assetRevision: 0)
        ))
        #expect(lines(result.rootBox).first?.height == 70)
        let ruby = try #require(lines(result.rootBox).flatMap(\.runs).compactMap(\.ruby).first)
        let run = try #require((CTLineGetGlyphRuns(ruby.base.line) as! [CTRun]).first)
        let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
        #expect((attrs[.font] as? UIFont)?.pointSize == 26)
        #expect(attrs[.foregroundColor] as? UIColor == .red)
    }

    /// A rule that only enlarges the font must grow its line box, as it did before
    /// YueduCoreText 0.5.0's half-leading. Measured 2026-09-23: a 30pt glyph on a 17pt line
    /// reached 13.78pt into the previous line — with or without an authored line-height.
    @Test func regexFontSizeWithoutLineHeightStaysInsideItsLine() throws {
        let style = ReaderStyleRuleStyle(text: ReaderStyleTextStyle(fontSize: 30))
        let config = BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(
            configuration: configuration(pattern: "測", style: style), appearance: .light, assetRevision: 0
        ))
        for sheet in [css, css + " p { line-height: 20px; }"] {
            let result = try BrowserLayoutDocument(html: "<p>上一行<br/>前測後</p>", cssTexts: [sheet], config: config)
                .makeLayout(containerSize: size)
            let rows = lines(result.rootBox)
            #expect(rows.count == 2)
            let styled = try #require(rows.last)
            let runs = CTLineGetGlyphRuns(try #require(styled.ctLine)) as! [CTRun]
            let fonts = runs.compactMap { (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as? UIFont }
            let big = try #require(fonts.first { $0.pointSize == 30 })
            #expect(styled.baseline - big.ascender >= styled.top - 0.01, "glyph top reaches into the previous line")
            #expect(styled.baseline - big.descender <= styled.top + styled.height + 0.01, "glyph bottom leaves its line")
        }
    }

    /// Vertical writing honours a rule's line-height as the column width, as it did before
    /// 0.5.0. Measured 2026-09-23: the column stayed 17 while horizontal lines became 60.
    @Test func regexLineHeightSizesVerticalColumn() throws {
        let style = ReaderStyleRuleStyle(text: ReaderStyleTextStyle(lineHeight: 60))
        let transform = BrowserReaderAttributes.transform(
            configuration: configuration(pattern: "測", style: style), appearance: .light, assetRevision: 0
        )
        let plainResult = try layout("<p>前測後</p>", config: BrowserLayoutConfig(writingMode: .verticalRTL))
        let styledResult = try layout("<p>前測後</p>", config: BrowserLayoutConfig(textTransform: transform, writingMode: .verticalRTL))
        let plain = try #require(lines(plainResult.rootBox).first)
        let styled = try #require(lines(styledResult.rootBox).first)
        #expect(plain.height < 60)
        #expect(abs(styled.height - 60) < 0.01)
    }

    @Test func existingBrowserChapterRefreshesRegexAppearanceAndDisabling() async throws {
        var settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 20, lineHeightMultiple: 1.4, lineSpacing: 0,
            paragraphSpacing: 0, letterSpacing: 0, marginH: 0, marginV: 0,
            footerHeight: 0, contentInsets: .zero
        )
        let style = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(backgroundColorHex: 0x00FF00))
        settings.regexHighlightConfiguration = configuration(pattern: "測試", style: style)
        let resource = MockBrowserLayoutResource(chapters: [.init(
            title: "Test", href: "chapter0.xhtml", html: "<p>測試</p>", css: [css]
        )])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let delegate = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["測試"]),
            renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: folder)
        )
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        await engine.start(renderSize: size, bookId: "browser-regex-refresh")
        let original = try #require(engine.renderSnapshot(forPage: 0))
        #expect(try countGreenPixels(original) > 100)
        let source = engine.chapterText(forSpine: 0)
        settings.regexHighlightConfiguration.customRules[0].lightStyle.decoration.backgroundColorHex = 0xFF0000
        engine.updateRenderSettings(settings)
        engine.applyThemeChange(textColor: .black, backgroundColor: .white)
        await engine.refreshRegexHighlightAppearanceIfNeeded()
        let changed = try #require(engine.renderSnapshot(forPage: 0))
        #expect(try countGreenPixels(changed) == 0)
        #expect(changed.pngData() != original.pngData())
        settings.regexHighlightConfiguration.isEnabled = false
        engine.updateRenderSettings(settings)
        await engine.refreshRegexHighlightAppearanceIfNeeded()
        let disabled = try #require(engine.renderSnapshot(forPage: 0))
        #expect(disabled.pngData() != changed.pngData())
        #expect(engine.chapterText(forSpine: 0) == source)
        #expect(engine.choice(for: 0)?.isBrowser == true)
    }

    private func hasRedGlyph(in box: BlockBox) -> Bool {
        lines(box).compactMap(\.ctLine).contains { line in
            (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
                let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                return attrs[.foregroundColor] as? UIColor == .red
            }
        }
    }

    /// A quote crossing inline boxes (ruby base, `<strong>`) is several display items on one
    /// line; its frame must still be one box, as the legacy engine draws it. Measured
    /// 2026-10-12: 和蘭人形's 「卑怯者、な、名乗れ」 drew three overlapping frames.
    @Test(arguments: [
        "<p>前「甲<strong>乙</strong>丙」後</p>",
        "<p>前「甲<ruby>乙<rt>おつ</rt></ruby>丙」後</p>",
    ])
    func highlightCrossingInlineBoxesPaintsOneBoxPerLine(html: String) async throws {
        let red = ReaderStyleBorder(width: 2, colorHex: 0xFF0000)
        let style = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(
            borders: [.leading: red, .trailing: red]
        ))
        let config = BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(
            configuration: configuration(pattern: "「[^」]*」", style: style), appearance: .light, assetRevision: 0
        ))
        let document = BrowserLayoutDocument(html: html, cssTexts: [css], config: config)
        let pages = try await document.renderPages(containerSize: size)
        let list = DisplayListBuilder.build(for: try #require(pages.first), sourceText: document.lastSourceText)
        let highlighted = list.items.filter { item in
            guard case .text(let text) = item else { return false }
            let attributed = text.attributedText
            var found = false
            attributed.enumerateAttribute(RegexHighlightDecoration.attributeKey,
                                          in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        #expect(highlighted.count >= 3, "the quote should span several display items")

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { r in
            UIColor.white.setFill(); r.fill(CGRect(origin: .zero, size: size))
            ReaderDisplayListDrawer.draw(list, in: r.cgContext)
        }
        // One box has one leading and one trailing border on every row it covers.
        #expect(try maximumRedRunsPerRow(image) == 2)
    }

    /// In a vertical column a curly quote lies on its side, in the horizontal font, while the
    /// text it opens stands upright in CoreText's vertical variant of its font. The box took its
    /// metrics from the opening quote and sat half a column to the right of its text: 5.5pt on
    /// every “” and ‘’ of a vertical EPUB. Taken from the upright text's vertical variant, it was
    /// one em thick — its ascent and descent are half an em each — so it hugged the glyphs and the
    /// quotes lay across its edge; taken from the CSS font, the system font's 1.19 em, it was
    /// 3.7pt thinner than the same text's box in a horizontal line, where PingFang TC draws the
    /// Han at 1.4 em (2026-10-15).
    @Test func verticalHighlightOpenedBySidewaysQuoteStaysOnItsColumn() async throws {
        // The quote goes in the second column, clear of the page's right edge, so no box is
        // clipped; the first column ends above the box's rows, so its ink is not measured.
        let html = "<p>前。</p><p>他說：“多謝。明天再來。”後</p>"
        let image = try await renderedGreenHighlight(html: html, writingMode: .verticalRTL, size: size)
        let box = try extent(of: image) { $0.g > 200 && $0.r < 80 && $0.b < 80 }
        let ink = try extent(of: image, rows: box.rows) { max($0.r, $0.g, $0.b) < 90 }
        #expect(box.columns.upperBound < Int(size.width) - 1, "the box must not reach the page edge")
        let boxCentre = CGFloat(box.columns.lowerBound + box.columns.upperBound) / 2
        let inkCentre = CGFloat(ink.columns.lowerBound + ink.columns.upperBound) / 2
        #expect(abs(boxCentre - inkCentre) <= 1, "box \(box.columns) is off the column of its text \(ink.columns)")
        #expect(box.columns.lowerBound <= ink.columns.lowerBound && ink.columns.upperBound <= box.columns.upperBound,
                "the text and its quotes \(ink.columns) must lie on the box \(box.columns)")

        // As thick as the same text's box in a horizontal line.
        let wide = CGSize(width: 480, height: 200)
        let horizontal = try await renderedGreenHighlight(html: html, writingMode: .horizontal, size: wide)
        let line = try extent(of: horizontal) { $0.g > 200 && $0.r < 80 && $0.b < 80 }
        #expect(abs(box.columns.count - line.rows.count) <= 1,
                "vertical box \(box.columns.count)pt thick, horizontal \(line.rows.count)pt")
    }

    /// `html` drawn at scale 1 on white, with every curly-quoted span on a pure green box. Laid
    /// out with a book's CJK typography, as the reader always lays one out
    /// (`BrowserLayoutPageEngine.makeBrowserConfig`): it decides which fonts draw the Han.
    private func renderedGreenHighlight(
        html: String, writingMode: ReaderWritingMode, size: CGSize
    ) async throws -> UIImage {
        let style = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(backgroundColorHex: 0x00FF00))
        let config = BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(
            configuration: configuration(pattern: "“[^”]*”", style: style), appearance: .light, assetRevision: 0
        ), writingMode: writingMode, cjkTypographyStyle: .traditional)
        let document = BrowserLayoutDocument(html: html, cssTexts: [css], config: config)
        let pages = try await document.renderPages(containerSize: size)
        let list = DisplayListBuilder.build(for: try #require(pages.first), sourceText: document.lastSourceText)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            UIColor.white.setFill(); r.fill(CGRect(origin: .zero, size: size))
            ReaderDisplayListDrawer.draw(list, in: r.cgContext)
        }
    }

    private struct Pixel { let r: Int; let g: Int; let b: Int }

    /// The columns and rows holding the pixels that pass `test`, within `rows` when given.
    private func extent(
        of image: UIImage, rows: ClosedRange<Int>? = nil, where test: (Pixel) -> Bool
    ) throws -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { pointer in
            let context = try #require(CGContext(
                data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var xs: [Int] = []
        var ys: [Int] = []
        for y in rows ?? 0...(height - 1) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if test(Pixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))) {
                    xs.append(x)
                    ys.append(y)
                }
            }
        }
        let minX = try #require(xs.min()), maxX = try #require(xs.max())
        let minY = try #require(ys.min()), maxY = try #require(ys.max())
        return (minX...maxX, minY...maxY)
    }

    private func maximumRedRunsPerRow(_ image: UIImage) throws -> Int {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { pointer in
            let context = try #require(CGContext(
                data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { y in
            var runs = 0
            var inRun = false
            for x in 0..<width {
                let i = (y * width + x) * 4
                let isRed = bytes[i] > 200 && bytes[i + 1] < 60 && bytes[i + 2] < 60
                if isRed, !inRun { runs += 1 }
                inRun = isRed
            }
            return runs
        }.max() ?? 0
    }

    private func configuration(
        pattern: String, style: ReaderStyleRuleStyle, options: RegexHighlightOptions = []
    ) -> RegexHighlightConfiguration {
        RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [RegexHighlightRule(
            id: "browser-test", name: "test", pattern: pattern, isEnabled: true, isBuiltIn: false,
            options: options, lightStyle: style, darkStyle: style
        )])
    }

    private func countGreenPixels(_ image: UIImage) throws -> Int {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { pointer in
            let context = try #require(CGContext(
                data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] < 30 && bytes[$0 + 1] > 220 && bytes[$0 + 2] < 30
        }.count
    }
}
