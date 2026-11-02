import Combine
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// The CSS `MOBIMarkupNormalizer` writes for Kindle's presentational markup is
/// frozen by the text contract at the first release, so both engines are asked
/// here whether they lay it out as a Kindle does: a negative `width` hangs the
/// first line out of an indented block, and `<font size>` scales with the
/// reader's chosen size (`rem`), not with a fixed one.
@Suite("MOBI 6 engine parity", .serialized)
@MainActor
struct MOBIEngineParityTests {
    /// Not the default 17, so a size resolved against a fixed root would show.
    static let readerFontSize: CGFloat = 24
    nonisolated static let prose = String(repeating: "The keeper wrote the hours down in the almanac. ", count: 8)
    /// One paragraph a construct: a plain one, `width="14pt"` (a first-line
    /// indent), `width="-14pt"` (a hanging first line), and `<font size>`.
    nonisolated static let html = "<html><body><p>Plain \(prose)</p><p width=\"14pt\">Indented \(prose)</p>"
        + "<p width=\"-14pt\">Hanging \(prose)</p>"
        + "<p><font size=\"+1\">Larger</font> and <font size=\"7\">Largest</font></p></body></html>"

    @Test("the normalizer's markup is what this suite lays out")
    func markup() throws {
        let xhtml = try Self.book().chapters[0].xhtml
        #expect(xhtml.contains(#"<p style="text-indent: 14pt">Indented"#))
        #expect(xhtml.contains(#"<p style="text-indent: -14pt; margin-left: 14pt">Hanging"#))
        #expect(xhtml.contains(#"<span style="font-size: 1.125rem">Larger</span>"#))
        #expect(xhtml.contains(#"<span style="font-size: 3rem">Largest</span>"#))
    }

    @Test("BrowserAuto hangs the first line and sizes <font> from the reader's font size")
    func browserAuto() async throws {
        let session = try await Self.session()
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: CGSize(width: 320, height: 2_000),
                      settings: EPUBTestFixtures.renderSettings(fontSize: Self.readerFontSize))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        _ = await engine.preloadChapter(at: 0)
        #expect(engine.choice(for: 0)?.isBrowser == true)
        let layout = try #require(engine.testLayout(for: 0))
        let fragments = BrowserLayoutTestSupport.allTextFragments(layout.pages)
        let text = layout.sourceText as NSString

        /// Each line's left edge in the paragraph that starts with `word`, top to bottom.
        func lineStarts(_ word: String) throws -> [CGFloat] {
            let start = text.range(of: word + " The keeper")
            try #require(start.location != NSNotFound, "\(word) is in the laid-out text")
            let paragraph = NSRange(location: start.location, length: word.utf16.count + 1 + Self.prose.utf16.count - 1)
            var lines: [CGFloat: CGFloat] = [:]
            for fragment in fragments where NSIntersectionRange(fragment.sourceRange, paragraph).length > 0 {
                let top = fragment.documentRect.minY.rounded()
                lines[top] = min(lines[top] ?? .infinity, fragment.documentRect.minX)
            }
            return lines.sorted { $0.key < $1.key }.map(\.value)
        }
        let plain = try lineStarts("Plain")
        let indented = try lineStarts("Indented")
        let hanging = try lineStarts("Hanging")
        try #require(plain.count >= 2 && indented.count >= 2 && hanging.count >= 2)
        let edge = plain[0]
        let indent = indented[0] - edge
        #expect(indent > 10, "14pt is a visible indent (\(indent))")
        #expect(abs(indented[1] - edge) < 0.5)
        // Hanging: the first line at the edge, every later one indented by it.
        #expect(abs(hanging[0] - edge) < 0.5, "first line at \(hanging[0]), edge \(edge)")
        for start in hanging.dropFirst() {
            #expect(abs(start - edge - indent) < 0.5, "later line at \(start), expected \(edge + indent)")
        }

        func size(of word: String) throws -> CGFloat {
            let range = text.range(of: word)
            let fragment = try #require(fragments.first { NSIntersectionRange($0.sourceRange, range).length > 0 })
            return fragment.font.pointSize
        }
        let plainSize = try size(of: "Plain"), largerSize = try size(of: "Larger"), largestSize = try size(of: "Largest")
        #expect(abs(plainSize - Self.readerFontSize) < 0.01)
        #expect(abs(largerSize - 1.125 * Self.readerFontSize) < 0.01)
        #expect(abs(largestSize - 3 * Self.readerFontSize) < 0.01)
    }

    @Test("legacy hangs the first line and sizes <font> from the reader's font size")
    func legacy() async throws {
        let session = try await Self.session()
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
        let attributed = try await builder.buildChapter(
            at: 0, settings: EPUBTestFixtures.renderSettings(fontSize: Self.readerFontSize),
            themeTextColor: .black, themeBackgroundColor: .white).attributedString
        let text = attributed.string as NSString
        func paragraphStyle(_ word: String) throws -> NSParagraphStyle {
            let location = text.range(of: word).location
            try #require(location != NSNotFound, "\(word) is in the built text")
            return try #require(attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle)
        }
        let plain = try paragraphStyle("Plain")
        let indented = try paragraphStyle("Indented")
        let hanging = try paragraphStyle("Hanging")
        let indent = indented.firstLineHeadIndent - plain.firstLineHeadIndent
        #expect(indent > 10, "14pt is a visible indent (\(indent))")
        #expect(abs(indented.headIndent - plain.headIndent) < 0.5)
        #expect(abs(hanging.firstLineHeadIndent - plain.firstLineHeadIndent) < 0.5)
        #expect(abs(hanging.headIndent - plain.headIndent - indent) < 0.5)

        func size(of word: String) throws -> CGFloat {
            let location = text.range(of: word).location
            return try #require(attributed.attribute(.font, at: location, effectiveRange: nil) as? UIFont).pointSize
        }
        let plainSize = try size(of: "Plain"), largerSize = try size(of: "Larger"), largestSize = try size(of: "Largest")
        #expect(abs(plainSize - Self.readerFontSize) < 0.01)
        #expect(abs(largerSize - 1.125 * Self.readerFontSize) < 0.01)
        #expect(abs(largestSize - 3 * Self.readerFontSize) < 0.01)
    }

    // MARK: Helpers

    nonisolated static func data() -> Data {
        MOBIFileTests.shortHeaderFile(text: Array(html.utf8), encoding: 65001, title: Array("Parity".utf8), locale: 9)
    }

    nonisolated static func book() throws -> MOBIConvertedBook {
        try MOBI6Converter.convert(MOBIFile(data: data()))
    }

    static func session() async throws -> PublicationSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobi-parity-\(UUID().uuidString).epub")
        _ = try await MOBIEPUBWriter.write(try book(), source: MOBIEPUBManifest.Source(original: data(), kind: .mobi6),
                                           identifier: "urn:uuid:mobi-parity", to: url)
        return try await PublicationSession.open(sourceURL: url)
    }
}
