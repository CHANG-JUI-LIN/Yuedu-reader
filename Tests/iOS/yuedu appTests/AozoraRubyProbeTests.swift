import Combine
import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Where a converted book's 左ルビ and readings on both sides of a word land, in both engines and
/// both writing modes (docs/superpowers/plans/2026-10-07-aozora-complete-support.md, Task 9): a
/// reading over the text and on the right of a vertical line, a left one under it and on the left.
/// BrowserAuto's readings are found as ink outside its text fragments; legacy's as its ruby
/// annotations and the room Core Text makes for them. The pages are saved for the plan's record.
@Suite("Aozora ruby probe", .serialized)
@MainActor
struct AozoraRubyProbeTests {
    /// Two blank lines between constructs, so no reading reaches the next construct's window.
    static let source = """
        題
        著者

        刺青［＃「刺青」の左に「イレズミ」のルビ］


        室適《しつてき》［＃「室適」の左に「オクサマ」のルビ］


        ｜真似《まね》［＃「真似」に「ママ」の注記］


        ｜漢字《かんじ》

        底本：「題」架空書房

        """

    static let size = CGSize(width: 600, height: 900)
    static let scale: CGFloat = 2
    nonisolated static let modes: [ReaderWritingMode] = [.horizontal, .verticalRTL]
    static let record = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-ruby-probe")

    /// Each construct's base, and its readings over (right of) and under (left of) it: the inner
    /// reading first. Legacy keeps one reading per side, the inner one.
    static let constructs: [(base: String, over: [String], under: [String])] = [
        ("刺青", [], ["イレズミ"]), ("室適", ["しつてき"], ["オクサマ"]), ("真似", ["まね", "ママ"], []),
        ("漢字", ["かんじ"], []),
    ]

    @Test(arguments: modes)
    func browserAutoSetsEachReadingOnItsSide(mode: ReaderWritingMode) async throws {
        let vertical = mode.isVertical
        let (session, spine) = try await Self.book()
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: Self.size,
                      settings: EPUBTestFixtures.renderSettings(writingMode: mode))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        _ = await engine.preloadChapter(at: spine)
        #expect(engine.choice(for: spine)?.isBrowser == true, "\(mode)")
        let layout = try #require(engine.testLayout(for: spine))
        try #require(layout.pages.count == 1)

        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: Self.size))
            ReaderDisplayListDrawer.draw(list, in: context.cgContext)
        }
        try FileManager.default.createDirectory(at: Self.record, withIntermediateDirectories: true)
        try image.pngData()?.write(to: Self.record.appendingPathComponent("browser-\(vertical ? "v" : "h").png"))

        // Each base run's glyph box on the page, as `AozoraEmphasisProbeTests` finds it. An
        // annotation is a text item at half the size, mapped to its base's source text; its ink
        // lies outside every base box.
        let texts = list.items.compactMap { item -> (range: NSRange, box: CGRect)? in
            guard case .text(let text) = item, text.sourceRange.length > 0, text.font.pointSize > 12 else { return nil }
            let ascent = ceil(text.font.ascender), height = ascent + ceil(-text.font.descender)
            let rect = text.rect.rawValue
            let box = vertical
                ? CGRect(x: text.baselineY - height / 2, y: rect.minY, width: height, height: rect.height)
                : CGRect(x: rect.minX, y: text.baselineY - ascent, width: rect.width, height: height)
            return (text.sourceRange, box.applying(text.paintTransform?.matrix ?? .identity))
        }
        let source = layout.sourceText as NSString
        for reading in Self.constructs.flatMap({ $0.over + $0.under }) {
            #expect(source.range(of: reading).location == NSNotFound, "\(reading) is not source text")
        }
        let pixels = AozoraEmphasisProbeTests.Ink(try #require(image.cgImage), scale: Self.scale)

        for construct in Self.constructs {
            let range = source.range(of: construct.base)
            try #require(range.location != NSNotFound, "\(construct.base)")
            let rect = texts.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.box)
                .reduce(CGRect.null) { $0.union($1) }
            try #require(!rect.isNull, "\(construct.base) \(mode)")
            let reach: CGFloat = 2 * 17
            let window = rect.insetBy(dx: vertical ? -reach : 0, dy: vertical ? 0 : -reach)
            let ink = pixels.blobs(in: window, outside: texts.map(\.box))
            // How far each side's ink reaches beyond the base: one reading's annotation box is 13
            // beyond it, a second on the same side 13 further.
            let over = ink.filter { vertical ? $0.midX > rect.maxX : $0.midY < rect.minY }
                .map { vertical ? $0.maxX - rect.maxX : rect.minY - $0.minY }.max()
            let under = ink.filter { vertical ? $0.midX < rect.minX : $0.midY > rect.maxY }
                .map { vertical ? rect.minX - $0.minX : $0.maxY - rect.maxY }.max()
            for (side, readings, found) in [("over", construct.over, over), ("under", construct.under, under)] {
                switch readings.count {
                case 0: #expect(found == nil, "\(construct.base) \(mode) \(side): \(ink) beside \(rect)")
                case 1: #expect(found.map { $0 > 3 && $0 <= 13.5 } == true, "\(construct.base) \(mode) \(side): \(found ?? 0)")
                default: #expect(found.map { $0 > 16 && $0 <= 26.5 } == true, "\(construct.base) \(mode) \(side): \(found ?? 0)")
                }
            }
        }
    }

    @Test(arguments: modes)
    func legacySetsEachReadingOnItsSide(mode: ReaderWritingMode) async throws {
        let (session, spine) = try await Self.book()
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: Self.size)
        let built = try await builder.buildChapter(at: spine, settings: EPUBTestFixtures.renderSettings(writingMode: mode),
                                                   themeTextColor: .black, themeBackgroundColor: .white)
        let string = built.attributedString
        let text = string.string as NSString
        for construct in Self.constructs {
            let range = text.range(of: construct.base)
            try #require(range.location != NSNotFound, "\(construct.base)")
            var effective = NSRange()
            let annotation = try #require(
                string.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, at: range.location,
                                 effectiveRange: &effective).map { $0 as! CTRubyAnnotation },
                "\(construct.base) \(mode)")
            #expect(effective == range, "one annotation over the whole base: \(construct.base) \(mode)")
            func reading(_ position: CTRubyPosition) -> String? {
                CTRubyAnnotationGetTextForPosition(annotation, position).map { $0 as String }
            }
            #expect(reading(.before) == construct.over.first, "\(construct.base) \(mode)")
            #expect(reading(.after) == construct.under.first, "\(construct.base) \(mode)")

            // Core Text makes room on each side that has a reading: the base's line against the
            // same line without its ruby. A reading at 0.85 of the text grows its side by more
            // than 6; any ruby grows the descent by 2.6 (iOS 26.5 simulator, 2026-11-04).
            let paragraph = text.paragraphRange(for: range)
            let line = NSMutableAttributedString(attributedString: string.attributedSubstring(from: paragraph))
            let bare = NSMutableAttributedString(attributedString: line)
            bare.removeAttribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                                 range: NSRange(location: 0, length: bare.length))
            func extents(_ attributed: NSAttributedString) -> (ascent: CGFloat, descent: CGFloat) {
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), &ascent, &descent, nil)
                return (ascent, descent)
            }
            let (with, without) = (extents(line), extents(bare))
            for (side, grown, reads) in [("ascent", with.ascent - without.ascent, !construct.over.isEmpty),
                                         ("descent", with.descent - without.descent, !construct.under.isEmpty)] {
                #expect(reads ? grown > 6 : grown < 4, "\(construct.base) \(mode): \(side) grows by \(grown)")
            }
        }

        let layout = await CoreTextPaginator().paginate(
            spineIndex: spine, attrStr: LayoutShared(string).wrappedValue, renderSize: Self.size, fontSize: 17,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), writingMode: mode)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: Self.size))
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0, in: context.cgContext,
                                        bounds: CGRect(origin: .zero, size: Self.size))
        }
        try FileManager.default.createDirectory(at: Self.record, withIntermediateDirectories: true)
        try image.pngData()?.write(to: Self.record.appendingPathComponent("legacy-\(mode.isVertical ? "v" : "h").png"))
    }

    // MARK: Helpers

    static func book() async throws -> (PublicationSession, Int) {
        let document = AozoraDocumentParser.parse(source)
        let chapters = AozoraChapterPlanner.plan(document, source: source)
        let spine = try #require(chapters.firstIndex { $0.text.contains("刺青") })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-ruby-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: [:],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue, length: source.utf16.count),
            identifier: "urn:uuid:aozora-ruby", to: url)
        return (try await PublicationSession.open(sourceURL: url), spine)
    }
}
