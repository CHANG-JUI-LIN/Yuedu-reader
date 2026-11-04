import Combine
import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Where each of Aozora's layout annotations puts its text, in both engines and both
/// writing modes (docs/superpowers/plans/2026-10-07-aozora-complete-support.md,
/// Phase 2b): the converted book's stylesheet must move the text, not only hold a
/// rule. One em is the reader's 17pt.
@Suite("Aozora stylesheet geometry", .serialized)
@MainActor
struct AozoraStylesheetGeometryTests {
    /// Each construct on characters of its own, so a character finds its paragraph. A
    /// 中見出し starts a chapter, so it comes last, in a chapter of its own.
    static let source = """
        題
        著者

        辛［＃「辛」は大見出し］
        基準
        ［＃ここから２字下げ］
        甲甲甲
        ［＃ここで字下げ終わり］
        ［＃ここから２字下げ、折り返して４字下げ］
        \(String(repeating: "乙", count: 80))
        ［＃ここで字下げ終わり］
        ［＃地付き］丙丙
        ［＃地から２字上げ］丁丁
        ［＃ここから５字詰め］
        \(String(repeating: "戊", count: 12))
        ［＃ここで字詰め終わり］
        己己［＃「己己」は１段階大きな文字］
        庚庚［＃「庚庚」は１段階小さな文字］
        ［＃ここから罫囲み］
        壬壬
        ［＃ここで罫囲み終わり］
        癸癸［＃「癸癸」に傍点］
        斜斜［＃「斜斜」は斜体］
        子子［＃「子子」は中見出し］
        中見出しの章

        底本：「題」架空書房

        """

    static let size = CGSize(width: 600, height: 900)
    static let em: CGFloat = 17

    /// The classes the measurements below rely on, so a parser change that drops one
    /// fails here and not as a puzzling distance.
    @Test func theFixtureUsesEveryMeasuredClass() async throws {
        let (_, chapters, _) = try await Self.book()
        let document = AozoraDocumentParser.parse(Self.source)
        let xhtml = chapters.map { AozoraXHTMLWriter.document(for: $0, in: document, images: [:]) }.joined()
        for name in ["o-midashi", "naka-midashi", "jisage_2", "jisage_4 first_2", "chitsuki_0", "chitsuki_2",
                     "jizume_5", "dai1", "sho1", "keigakomi", "sesame_dot", "shatai"] {
            #expect(xhtml.contains(name), "\(name) in \(xhtml)")
        }
    }

    @Test(arguments: [ReaderWritingMode.horizontal, ReaderWritingMode.verticalRTL])
    func browserAutoPlacesEveryConstruct(mode: ReaderWritingMode) async throws {
        let (session, chapters, spine) = try await Self.book()
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: Self.size,
                      settings: EPUBTestFixtures.renderSettings(writingMode: mode))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        func laidOut(_ spine: Int) async throws -> BrowserText {
            _ = await engine.preloadChapter(at: spine)
            #expect(engine.choice(for: spine)?.isBrowser == true, "spine \(spine) \(mode)")
            return BrowserText(layout: try #require(engine.testLayout(for: spine)), vertical: mode == .verticalRTL)
        }
        let text = try await laidOut(spine)
        let headingText = try await laidOut(try Self.spine(of: "子子", in: chapters))
        let em = Self.em

        let reference = try text.lines(of: "基準")[0].start
        let indented = try text.lines(of: "甲甲甲")
        #expect(abs(indented[0].start - reference - 2 * em) < 0.5, "字下げ \(mode): \(indented[0].start - reference)")

        let hanging = try text.lines(of: String(repeating: "乙", count: 80))
        try #require(hanging.count >= 2, "折り返し \(mode): \(hanging)")
        #expect(abs(hanging[0].start - reference - 2 * em) < 0.5, "折り返し first \(mode): \(hanging)")
        for line in hanging.dropFirst() {
            #expect(abs(line.start - reference - 4 * em) < 0.5, "折り返し rest \(mode): \(hanging)")
        }

        // The page's content box is inset equally on both sides.
        let inlineExtent = mode == .horizontal ? Self.size.width : Self.size.height
        let grounded = try text.lines(of: "丙丙")[0]
        #expect(abs(grounded.end - (inlineExtent - reference)) < 0.5, "地付き \(mode): \(grounded), \(reference)")
        let raised = try text.lines(of: "丁丁")[0]
        #expect(abs(grounded.end - raised.end - 2 * em) < 0.5, "字上げ \(mode): \(raised) vs \(grounded)")

        let limited = try text.lines(of: String(repeating: "戊", count: 12))
        #expect(limited.map(\.characters) == [5, 5, 2], "字詰め \(mode): \(limited)")

        #expect(abs(try text.font(of: "己己").pointSize - 1.125 * em) < 0.01, "１段階大きな \(mode)")
        #expect(abs(try text.font(of: "庚庚").pointSize - 0.8125 * em) < 0.01, "１段階小さな \(mode)")
        for (heading, scale, source) in [("辛", 1.25, text), ("子子", 1.125, headingText)] as [(String, CGFloat, BrowserText)] {
            let font = try source.font(of: heading)
            #expect(abs(font.pointSize - scale * em) < 0.01, "見出し \(heading) \(mode): \(font.pointSize)")
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold), "見出し \(heading) \(mode): \(font)")
        }

        // 罫囲み: a bordered box around the text, the text 1px + 1em in from its start.
        let boxed = try text.fragments(of: "壬壬")
        let box = try #require(text.fills.first { fill in
            [fill.borderTop, fill.borderBottom, fill.borderLeft, fill.borderRight].allSatisfy(\.isVisible)
                && fill.rect.rawValue.contains(CGPoint(x: boxed[0].rect.rawValue.midX, y: boxed[0].rect.rawValue.midY))
        }, "罫囲み \(mode): \(text.fills.map(\.rect.rawValue))")
        let boxStart = mode == .horizontal ? box.rect.rawValue.minX : box.rect.rawValue.minY
        let boxedStart = try text.lines(of: "壬壬")[0].start
        #expect(abs(boxedStart - boxStart - (1 + em)) < 0.5, "罫囲み padding \(mode): \(boxedStart - boxStart)")

        // 傍点 is an `em`, and aozora.css sets it upright.
        let emphasized = try text.font(of: "癸癸")
        #expect(!emphasized.fontDescriptor.symbolicTraits.contains(.traitItalic), "傍点 \(mode): \(emphasized)")
        #expect(CTFontGetMatrix(emphasized).c == 0, "傍点 \(mode): \(CTFontGetMatrix(emphasized))")

        // 斜体: CJK fonts have no italic face, so the Han is drawn in the CJK stand-in
        // with a shear in its matrix (the fragment's own font is the primary one).
        let slantedLine = try #require(try text.fragments(of: "斜斜")[0].ctLine)
        let drawn = (CTLineGetGlyphRuns(slantedLine) as! [CTRun]).map {
            (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont
        }
        #expect(drawn.contains { CTFontGetMatrix($0).c != 0 }, "斜体 \(mode): \(drawn)")
    }

    @Test(arguments: [ReaderWritingMode.horizontal, ReaderWritingMode.verticalRTL])
    func legacyPlacesEveryConstruct(mode: ReaderWritingMode) async throws {
        let (session, chapters, spine) = try await Self.book()
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: Self.size)
        func chapter(_ spine: Int) async throws -> NSAttributedString {
            try await builder.buildChapter(at: spine, settings: EPUBTestFixtures.renderSettings(writingMode: mode),
                                           themeTextColor: .black, themeBackgroundColor: .white).attributedString
        }
        let string = try await chapter(spine)
        let headingString = try await chapter(try Self.spine(of: "子子", in: chapters))
        let em = Self.em
        func style(_ marker: String) throws -> NSParagraphStyle {
            try #require(string.attribute(.paragraphStyle, at: try Self.location(of: marker, in: string),
                                          effectiveRange: nil) as? NSParagraphStyle, "\(marker) \(mode)")
        }
        func font(_ marker: String, in source: NSAttributedString? = nil) throws -> UIFont {
            let source = source ?? string
            return try #require(source.attribute(.font, at: try Self.location(of: marker, in: source),
                                                 effectiveRange: nil) as? UIFont, "\(marker) \(mode)")
        }

        let reference = try style("基準")
        let indented = try style("甲甲甲")
        #expect(abs(indented.firstLineHeadIndent - reference.firstLineHeadIndent - 2 * em) < 0.01, "字下げ \(mode)")
        #expect(abs(indented.headIndent - reference.headIndent - 2 * em) < 0.01, "字下げ \(mode)")
        let hanging = try style("乙乙")
        #expect(abs(hanging.firstLineHeadIndent - reference.firstLineHeadIndent - 2 * em) < 0.01, "折り返し \(mode)")
        #expect(abs(hanging.headIndent - reference.headIndent - 4 * em) < 0.01, "折り返し \(mode)")

        let grounded = try style("丙丙")
        #expect(grounded.alignment == .right && grounded.tailIndent == reference.tailIndent, "地付き \(mode): \(grounded)")
        let raised = try style("丁丁")
        #expect(raised.alignment == .right && abs(raised.tailIndent - (reference.tailIndent - 2 * em)) < 0.01,
                "字上げ \(mode): \(raised)")
        #expect(Self.lineLengths(of: "戊", in: string, mode: mode) == [5, 5, 2], "字詰め \(mode)")

        #expect(abs(try font("己己").pointSize - 1.125 * em) < 0.01, "１段階大きな \(mode)")
        #expect(abs(try font("庚庚").pointSize - 0.8125 * em) < 0.01, "１段階小さな \(mode)")
        for (heading, scale, source) in [("辛", 1.25, string), ("子子", 1.125, headingString)]
            as [(String, CGFloat, NSAttributedString)] {
            let headingFont = try font(heading, in: source)
            #expect(abs(headingFont.pointSize - scale * em) < 0.01, "見出し \(heading) \(mode): \(headingFont.pointSize)")
            #expect(headingFont.fontDescriptor.symbolicTraits.contains(.traitBold), "見出し \(heading) \(mode): \(headingFont)")
        }

        let boxed = try Self.location(of: "壬壬", in: string)
        #expect(string.attribute(HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute, at: boxed, effectiveRange: nil) != nil
                || string.attribute(HTMLAttributedStringBuilder.blockRenderStyleAttribute, at: boxed, effectiveRange: nil) != nil,
                "罫囲み \(mode)")

        let emphasized = try font("癸癸")
        #expect(!emphasized.fontDescriptor.symbolicTraits.contains(.traitItalic), "傍点 \(mode): \(emphasized)")
        #expect(string.attribute(.obliqueness, at: try Self.location(of: "癸癸", in: string), effectiveRange: nil) == nil,
                "傍点 \(mode)")
        let slanted = try font("斜斜")
        #expect(CTFontGetMatrix(slanted).c != 0, "斜体 \(mode): \(CTFontGetMatrix(slanted))")
    }

    // MARK: Helpers

    /// The converted book and the spine of its body chapter.
    static func book() async throws -> (PublicationSession, [AozoraChapter], Int) {
        let document = AozoraDocumentParser.parse(source)
        let chapters = AozoraChapterPlanner.plan(document, source: source)
        let spine = try spine(of: "基準", in: chapters)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-geometry-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: [:],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue, length: source.utf16.count),
            identifier: "urn:uuid:aozora-geometry", to: url)
        return (try await PublicationSession.open(sourceURL: url), chapters, spine)
    }

    static func spine(of marker: String, in chapters: [AozoraChapter]) throws -> Int {
        try #require(chapters.firstIndex { $0.text.contains(marker) }, "\(marker)")
    }

    static func location(of marker: String, in string: NSAttributedString) throws -> Int {
        let location = (string.string as NSString).range(of: marker).location
        try #require(location != NSNotFound, "\(marker)")
        return location
    }

    /// How many `character`s each line holds, laid out in a page-sized frame with the
    /// paginator's frame attributes.
    static func lineLengths(of character: Character, in string: NSAttributedString, mode: ReaderWritingMode) -> [Int] {
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil),
            CoreTextPaginator.frameAttributes(for: mode) as CFDictionary)
        let ns = string.string as NSString
        return (CTFrameGetLines(frame) as! [CTLine]).map { line in
            let range = CTLineGetStringRange(line)
            return ns.substring(with: NSRange(location: range.location, length: range.length)).filter { $0 == character }.count
        }.filter { $0 > 0 }
    }
}

/// A BrowserAuto chapter's text fragments, measured along the inline axis: x in
/// horizontal writing, y in vertical.
@MainActor
private struct BrowserText {
    struct Line: CustomStringConvertible {
        var start: CGFloat
        var end: CGFloat
        var characters: Int
        var description: String { "[\(start)…\(end), \(characters)]" }
    }

    let sourceText: NSString
    let fragments: [(page: Int, fragment: TextFragment)]
    let fills: [FillFragment]
    let vertical: Bool

    init(layout: BrowserChapterLayout, vertical: Bool) {
        func flattened(_ fragments: [Fragment]) -> [Fragment] {
            fragments.flatMap { fragment -> [Fragment] in
                if case .group(let children) = fragment { return flattened(children) }
                return [fragment]
            }
        }
        sourceText = layout.sourceText as NSString
        fragments = layout.pages.enumerated().flatMap { index, page in
            flattened(page.fragments).compactMap { fragment -> (page: Int, fragment: TextFragment)? in
                guard case .text(let text) = fragment, text.sourceRange.length > 0 else { return nil }
                return (index, text)
            }
        }
        fills = layout.pages.flatMap { page in
            flattened(page.fragments).compactMap { fragment -> FillFragment? in
                guard case .fill(let fill) = fragment else { return nil }
                return fill
            }
        }
        self.vertical = vertical
    }

    func range(of marker: String) throws -> NSRange {
        let range = sourceText.range(of: marker)
        try #require(range.location != NSNotFound, "\(marker)")
        return range
    }

    func fragments(of marker: String) throws -> [TextFragment] {
        let range = try range(of: marker)
        let found = fragments.filter { NSIntersectionRange($0.fragment.sourceRange, range).length > 0 }.map(\.fragment)
        try #require(!found.isEmpty, "no fragment for \(marker)")
        return found
    }

    func font(of marker: String) throws -> UIFont {
        try fragments(of: marker)[0].font
    }

    /// The lines `marker` is laid out on, in order: where each starts and ends along
    /// the inline axis and how many of the marker's characters it holds.
    func lines(of marker: String) throws -> [Line] {
        let range = try range(of: marker)
        var lines: [(key: [Int], line: Line)] = []
        for (page, fragment) in fragments {
            let overlap = NSIntersectionRange(fragment.sourceRange, range)
            guard overlap.length > 0 else { continue }
            let rect = fragment.rect.rawValue
            // A line is a row in horizontal writing and a column in vertical.
            let key = [page, Int(((vertical ? -rect.midX : rect.midY) * 2).rounded())]
            let start = vertical ? rect.minY : rect.minX
            let end = vertical ? rect.maxY : rect.maxX
            if let index = lines.firstIndex(where: { $0.key == key }) {
                lines[index].line.start = min(lines[index].line.start, start)
                lines[index].line.end = max(lines[index].line.end, end)
                lines[index].line.characters += overlap.length
            } else {
                lines.append((key, Line(start: start, end: end, characters: overlap.length)))
            }
        }
        try #require(!lines.isEmpty, "no line for \(marker)")
        return lines.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.line)
    }
}
