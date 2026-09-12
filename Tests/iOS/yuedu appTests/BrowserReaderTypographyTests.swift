@testable import YueduCoreText
import CoreText
import Testing
import UIKit
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
        #expect(lines(result.rootBox)[0].height == 60)
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
