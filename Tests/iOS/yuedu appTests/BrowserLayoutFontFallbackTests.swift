import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Browser layout font registration and fallback", .serialized)
@MainActor
struct BrowserLayoutFontFallbackTests {
    @Test("identical embedded font bytes keep one live process registration")
    func identicalFontBytesReuseLiveRegistration() throws {
        let data = try Data(contentsOf: fixtureURL)
        let firstService = CoreTextFontRegistrationService()
        let first = try #require(
            firstService.registerFont(data: data, alias: "first-resolver", existingTempURL: nil)
        )
        // Mirrors one frontend/resolver being released before another frontend
        // asks for the same immutable EPUB font asset.
        if let firstURL = first.tempFileURL {
            firstService.cleanupTemporaryFile(at: firstURL)
        }

        let secondService = CoreTextFontRegistrationService()
        let second = try #require(
            secondService.registerFont(data: data, alias: "second-resolver", existingTempURL: nil)
        )

        #expect(second.postScriptName == first.postScriptName)
        #expect(second.tempFileURL == first.tempFileURL)
        if let retainedURL = first.tempFileURL {
            #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        }

        let font = try #require(UIFont(name: second.postScriptName, size: 20))
        #expect(glyphs(for: "A", font: font).allSatisfy { $0 != 0 })
    }

    @Test("Latin glyphs stay on the embedded primary face")
    func latinOnlyKeepsPrimaryFace() throws {
        let lines = try layout(runs: [run("Browser", location: 0)])
        let physical = physicalRuns(in: try #require(lines.first?.ctLine))

        #expect(physical.contains { $0.fontName == "Ahem" })
        expectNoMissingGlyphs(physical)
    }

    @Test("one missing CJK scalar uses a real Unicode fallback")
    func oneMissingCJKScalarFallsBack() throws {
        let lines = try layout(runs: [run("A百B", location: 0)])
        let physical = physicalRuns(in: try #require(lines.first?.ctLine))

        #expect(physical.contains { $0.fontName != "Ahem" })
        expectNoMissingGlyphs(physical)
    }

    @Test("mixed Latin and CJK text shapes without LastResort")
    func mixedTextFallsBackPerPhysicalRun() throws {
        let text = "Character 百科全书"
        let lines = try layout(runs: [run(text, location: 0)])

        #expect(lines.flatMap(\.runs).map(\.sourceRange) == [
            NSRange(location: 0, length: (text as NSString).length),
        ])
        expectNoMissingGlyphs(physicalRuns(in: try #require(lines.first?.ctLine)))
    }

    @Test("full-width punctuation uses Unicode fallback")
    func punctuationFallsBack() throws {
        let lines = try layout(runs: [run("，。！？", location: 0)])
        expectNoMissingGlyphs(physicalRuns(in: try #require(lines.first?.ctLine)))
    }

    @Test("bold and italic styles retain fallback coverage")
    func boldAndItalicRetainCoverage() throws {
        var bold = style
        bold.fontWeight = 700
        var italic = style
        italic.isItalic = true
        let lines = try layout(runs: [
            run("粗体百科", location: 0, style: bold),
            run("斜体人物", location: 4, style: italic),
        ])

        for line in lines {
            expectNoMissingGlyphs(physicalRuns(in: try #require(line.ctLine)))
        }
        #expect(lines.flatMap(\.runs).map(\.style.fontWeight).contains(700))
        #expect(lines.flatMap(\.runs).map(\.style.isItalic).contains(true))
    }

    @Test("linked fallback text keeps its link and source range")
    func linkMappingSurvivesFallback() throws {
        let text = "百科全书"
        let lines = try layout(runs: [
            run(text, location: 0, linkTarget: "chapter.xhtml#entry"),
        ])
        let output = try #require(lines.first?.runs.first)

        #expect(output.linkTarget == "chapter.xhtml#entry")
        #expect(output.sourceRange == NSRange(location: 0, length: 4))
        expectNoMissingGlyphs(physicalRuns(in: try #require(lines.first?.ctLine)))
    }

    @Test("ruby base and annotation each receive Unicode fallback")
    func rubyBaseAndAnnotationFallBackIndependently() throws {
        let baseStyle = style
        var annotationStyle = style
        annotationStyle.fontSize = 10
        let unit = RubyInlineUnit(
            base: [RubyInlinePiece(
                text: "百科",
                style: baseStyle,
                sourceRange: NSRange(location: 0, length: 2),
                nodeID: 71,
                linkTarget: nil
            )],
            annotation: RubyAnnotation(pieces: [RubyAnnotationPiece(
                text: "人物",
                style: annotationStyle,
                nodeID: 72,
                linkTarget: nil
            )]),
            sourceRange: NSRange(location: 0, length: 2),
            nodeID: 70,
            linkTarget: nil,
            alignment: .center,
            position: .over
        )
        let lines = try layout(runs: [InlineRun(
            text: "百科",
            style: baseStyle,
            sourceRange: NSRange(location: 0, length: 2),
            nodeID: 70,
            ruby: unit
        )])
        let ruby = try #require(lines.first?.runs.first?.ruby)

        expectNoMissingGlyphs(physicalRuns(in: ruby.base.line))
        expectNoMissingGlyphs(physicalRuns(in: ruby.annotation.line))
        #expect(ruby.base.pieces.first?.sourceRange == NSRange(location: 0, length: 2))
        #expect(ruby.annotation.pieces.first?.sourceRange == NSRange(location: 0, length: 2))
    }

    @Test("fallback does not alter pagination or selection source mapping")
    func sourceAndSelectionMappingRemainLinear() throws {
        let text = "A百科全书B"
        let lines = try layout(runs: [run(text, location: 0)])
        let block = BlockBox(style: style, lines: lines)
        block.debugNodeID = 80
        _ = BlockLayout.layOut(root: block, containerWidth: 300)
        let pages = PageFragmentation.fragment(
            box: block,
            pageSize: CGSize(width: 300, height: 100)
        )
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)

        #expect(fragments.map(\.sourceRange) == [
            NSRange(location: 0, length: (text as NSString).length),
        ])
        #expect(fragments.first?.sourceMapping == .linear(
            shapedRange: NSRange(location: 0, length: (text as NSString).length)
        ))
        expectNoMissingGlyphs(physicalRuns(in: try #require(fragments.first?.ctLine)))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
    }

    private var style: ComputedStyle {
        var result = ComputedStyle(fontSize: 20, fontFamilies: ["Ahem"])
        result.color = .black
        result.lineHeight = 28
        return result
    }

    private func run(
        _ text: String,
        location: Int,
        style: ComputedStyle? = nil,
        linkTarget: String? = nil
    ) -> InlineRun {
        InlineRun(
            text: text,
            style: style ?? self.style,
            sourceRange: NSRange(location: location, length: (text as NSString).length),
            nodeID: 60 + location,
            linkTarget: linkTarget
        )
    }

    private func layout(runs: [InlineRun]) throws -> [LayoutLine] {
        let primary = try registeredAhemFont(size: 20)
        let source = runs.map(\.text).joined()
        return InlineLayout.layoutLines(
            runs: runs,
            context: InlineFormattingContext(
                containingInlineSize: 500,
                rootFontSize: 20,
                lineHeight: nil,
                writingMode: .horizontal,
                sourceText: source,
                fontResolver: { _, _, _, size in
                    ReaderFontCascade.preservingPrimary(primary, size: size)
                },
                floatContext: nil,
                blockOffsetY: 0
            )
        )
    }

    private func registeredAhemFont(size: CGFloat) throws -> UIFont {
        let data = try Data(contentsOf: fixtureURL)
        let result = try #require(
            CoreTextFontRegistrationService().registerFont(
                data: data,
                alias: "fallback-primary",
                existingTempURL: nil
            )
        )
        return try #require(UIFont(name: result.postScriptName, size: size))
    }

    private struct PhysicalRun {
        let fontName: String
        let glyphs: [CGGlyph]
    }

    private func physicalRuns(in line: CTLine) -> [PhysicalRun] {
        (CTLineGetGlyphRuns(line) as! [CTRun]).map { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            return PhysicalRun(
                fontName: CTFontCopyPostScriptName(font) as String,
                glyphs: glyphs
            )
        }
    }

    private func expectNoMissingGlyphs(_ runs: [PhysicalRun]) {
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { !$0.fontName.lowercased().contains("lastresort") })
        #expect(runs.flatMap(\.glyphs).allSatisfy { $0 != 0 })
    }

    private func glyphs(for text: String, font: UIFont) -> [CGGlyph] {
        let utf16 = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: utf16.count)
        let ctFont = font as CTFont
        _ = CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count)
        return glyphs
    }
}
