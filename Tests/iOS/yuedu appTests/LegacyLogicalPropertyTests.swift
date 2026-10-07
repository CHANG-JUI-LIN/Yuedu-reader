@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// CSS logical properties in the legacy engine. Legacy sets a vertical chapter as
/// horizontal lines turned on their side, so its head indent is the inline start and
/// paragraph spacing before the block start in both writing modes: a logical property
/// must give exactly what its legacy physical counterpart gives, in either mode.
/// BrowserAuto's side of the same cases is YueduCoreText's `LogicalPropertyTests`.
@MainActor
struct LegacyLogicalPropertyTests {
    private static let size = CGSize(width: 320, height: 480)
    private static let fontSize: CGFloat = 20
    private static let text = String(repeating: "山", count: 30)

    /// The chapter as the legacy builder renders it for `mode`.
    private static func build(css: String, paragraph: String = "<p>\(text)</p>",
                              mode: ReaderWritingMode) async throws -> NSAttributedString {
        let body = paragraph
        let entries: [String: Data] = [
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
                <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>logical</dc:title>
                <dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="css" href="style.css" media-type="text/css"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """.utf8),
            "OPS/style.css": Data("body { margin: 0; padding: 0 } p { margin: 0 } \(css)".utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(
                title: "Nav",
                body: #"<nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Start</a></li></ol></nav>"#).utf8),
            "OPS/chapter1.xhtml": Data(EPUBTestFixtures.xhtml(
                title: "logical", body: body,
                head: #"<link rel="stylesheet" type="text/css" href="style.css"/>"#).utf8),
        ]
        let url = try await EPUBTestFixtures.makeArchive(entries: entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let index = try #require(session.chapterIndex(for: "OPS/chapter1.xhtml")
            ?? session.chapterIndex(for: "chapter1.xhtml"))
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        return try await builder.buildChapter(
            at: index,
            settings: EPUBTestFixtures.renderSettings(fontSize: fontSize, writingMode: mode),
            themeTextColor: .black,
            themeBackgroundColor: .white
        ).attributedString
    }

    private static func paragraphStyle(_ string: NSAttributedString) throws -> NSParagraphStyle {
        let location = (string.string as NSString).range(of: "山").location
        try #require(location != NSNotFound)
        return try #require(string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    }

    /// The number of characters each line of the first paragraph holds, laid out in a
    /// frame the size of the page with the paginator's frame attributes.
    private static func lineLengths(_ string: NSAttributedString, mode: ReaderWritingMode) -> [Int] {
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil),
            CoreTextPaginator.frameAttributes(for: mode) as CFDictionary)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let ns = string.string as NSString
        return lines.map { line in
            let range = CTLineGetStringRange(line)
            return ns.substring(with: NSRange(location: range.location, length: range.length))
                .filter { $0 == "山" }.count
        }.filter { $0 > 0 }
    }

    // MARK: - Cascade

    /// Each logical property against the legacy physical property it stands for.
    private static let pairs: [(logical: String, physical: String)] = [
        ("margin-inline-start", "margin-left"),
        ("margin-inline-end", "margin-right"),
        ("margin-block-start", "margin-top"),
        ("margin-block-end", "margin-bottom"),
        ("padding-inline-start", "padding-left"),
        ("padding-inline-end", "padding-right"),
        ("padding-block-start", "padding-top"),
        ("padding-block-end", "padding-bottom"),
    ]

    @Test func everyLogicalSideSetsWhatItsLegacyCounterpartSets() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            for pair in Self.pairs {
                let logical = try Self.paragraphStyle(try await Self.build(css: "p { \(pair.logical): 2em }", mode: mode))
                let physical = try Self.paragraphStyle(try await Self.build(css: "p { \(pair.physical): 2em }", mode: mode))
                let plain = try Self.paragraphStyle(try await Self.build(css: "", mode: mode))
                #expect(logical == physical, "\(pair.logical) mode=\(mode)")
                // Guard against both sides being ignored alike.
                if pair.logical.hasPrefix("margin-inline") || pair.logical.hasPrefix("padding-inline")
                    || mode == .horizontal {
                    #expect(logical != plain, "\(pair.logical) mode=\(mode) changed nothing")
                }
            }
        }
    }

    @Test func marginInlineStartIsTheHeadIndentInBothModes() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let style = try Self.paragraphStyle(try await Self.build(css: "p { margin-inline-start: 2em }", mode: mode))
            #expect(abs(style.headIndent - 2 * Self.fontSize) < 0.01, "mode=\(mode)")
            #expect(abs(style.firstLineHeadIndent - 2 * Self.fontSize) < 0.01, "mode=\(mode)")
            let end = try Self.paragraphStyle(try await Self.build(css: "p { margin-inline-end: 3em }", mode: mode))
            #expect(abs(end.tailIndent + 3 * Self.fontSize) < 0.01, "mode=\(mode)")
        }
    }

    @Test func theLaterOfALogicalAndAPhysicalDeclarationWins() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let logicalLast = try Self.paragraphStyle(try await Self.build(
                css: "p { margin-left: 1em; margin-inline-start: 2em }", mode: mode))
            #expect(abs(logicalLast.headIndent - 2 * Self.fontSize) < 0.01, "mode=\(mode)")
            let physicalLast = try Self.paragraphStyle(try await Self.build(
                css: "p { margin-inline-start: 2em; margin-left: 1em }", mode: mode))
            #expect(abs(physicalLast.headIndent - Self.fontSize) < 0.01, "mode=\(mode)")
            let laterRule = try Self.paragraphStyle(try await Self.build(
                css: "p { margin-left: 1em } p { margin-inline-start: 2em }", mode: mode))
            #expect(abs(laterRule.headIndent - 2 * Self.fontSize) < 0.01, "mode=\(mode)")
            let inline = try Self.paragraphStyle(try await Self.build(
                css: "p { margin-inline-start: 2em }",
                paragraph: "<p style=\"margin-left: 3em\">\(Self.text)</p>", mode: mode))
            #expect(abs(inline.headIndent - 3 * Self.fontSize) < 0.01, "mode=\(mode)")
        }
    }

    // MARK: - Geometry

    @Test func maxInlineSizeWrapsAtTenCharactersInBothModes() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let string = try await Self.build(css: "p { max-inline-size: 10em }", mode: mode)
            let inlineExtent = mode == .horizontal ? Self.size.width : Self.size.height
            #expect(abs(try Self.paragraphStyle(string).tailIndent + (inlineExtent - 10 * Self.fontSize)) < 0.01,
                    "mode=\(mode)")
            #expect(Self.lineLengths(string, mode: mode) == [10, 10, 10], "mode=\(mode)")

            // From the head indent, not from the page edge.
            let indented = try await Self.build(css: "p { margin-inline-start: 2em; max-inline-size: 10em }", mode: mode)
            #expect(Self.lineLengths(indented, mode: mode) == [10, 10, 10], "indented, mode=\(mode)")

            // `none` lifts it, and a wider page edge or margin still wins over it.
            let lifted = try await Self.build(css: "p { max-inline-size: 10em } p { max-inline-size: none }", mode: mode)
            #expect(try Self.paragraphStyle(lifted).tailIndent == 0, "mode=\(mode)")
            let wide = try await Self.build(css: "p { max-inline-size: 100em; margin-inline-end: 1em }", mode: mode)
            #expect(abs(try Self.paragraphStyle(wide).tailIndent + Self.fontSize) < 0.01, "mode=\(mode)")
        }
    }

    @Test func minInlineSizeIsIgnored() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let with = try Self.paragraphStyle(try await Self.build(css: "p { min-inline-size: 20em }", mode: mode))
            let without = try Self.paragraphStyle(try await Self.build(css: "", mode: mode))
            #expect(with == without, "mode=\(mode)")
        }
    }

    @Test func textAlignEndAlignsToTheInlineEnd() async throws {
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let string = try await Self.build(css: "p { text-align: end }", paragraph: "<p>山路</p>", mode: mode)
            #expect(try Self.paragraphStyle(string).alignment == .right, "mode=\(mode)")
        }
        let string = try await Self.build(css: "p { text-align: end }", paragraph: "<p>山路</p>", mode: .horizontal)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(string as CFAttributedString), CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: Self.size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let index = try #require(lines.firstIndex { CTLineGetStringRange($0).length > 0 })
        var origin = CGPoint.zero
        CTFrameGetLineOrigins(frame, CFRange(location: index, length: 1), &origin)
        let width = CGFloat(CTLineGetTypographicBounds(lines[index], nil, nil, nil))
            - CGFloat(CTLineGetTrailingWhitespaceWidth(lines[index]))
        #expect(abs(origin.x + width - Self.size.width) < 0.5)
    }
}
