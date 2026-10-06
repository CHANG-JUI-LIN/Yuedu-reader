import Combine
import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// W3C vertical typography in both engines
/// (docs/superpowers/plans/2026-10-06-vertical-typography.md).
///
/// Every case is a short self-written chapter drawn through each engine's real
/// drawing path. The mark under test is red, its partner blue, its Han
/// neighbours black, and a green lead paragraph carries the script. Positions
/// are measured from the coloured ink, in ems, against the neighbours: the
/// cell of a mark between two Han characters is centred between their ink.
@Suite("Vertical typography acceptance", .serialized)
@MainActor
struct VerticalTypographyAcceptanceTests {
    // MARK: Fixtures

    enum Engine: String, CaseIterable, CustomStringConvertible {
        case browser, legacy
        var description: String { rawValue }
    }

    struct Script: CustomStringConvertible {
        let name: String
        /// Declared on the chapter, as the reported 紅樓夢 declares zh-cn for Traditional text.
        let declared: String
        let lead: String
        let han: String
        let hanFont: String
        var description: String { name }
    }

    static let traditional = Script(
        name: "traditional", declared: "zh-cn",
        lead: "這裡說的是舊時候的事，誰也記不清楚了。後來聽說，那邊的園子裡還開著花。",
        han: "國", hanFont: "PingFangTC-Regular")
    static let simplified = Script(
        name: "simplified", declared: "zh-TW",
        lead: "这里说的是旧时候的事，谁也记不清楚了。后来听说，那边的园子里还开着花。",
        han: "国", hanFont: "PingFangSC-Regular")
    static let japanese = Script(
        name: "japanese", declared: "zh",
        lead: "これは昔の話である。誰もよく覚えていない。あの庭にはまだ花が咲いているそうだ。",
        han: "国", hanFont: "HiraginoSans-W3")
    static let scripts = [traditional, simplified, japanese]

    nonisolated static let fontSize: CGFloat = 17
    nonisolated static let scale: CGFloat = 3
    nonisolated static let pageSize = CGSize(width: 320, height: 480)
    nonisolated static var em: CGFloat { fontSize * scale }

    /// One chapter per case: the lead paragraph in green, then the case.
    struct Case {
        let id: String
        let body: (Script) -> String
    }

    static func red(_ text: String) -> String { #"<span style="color:#FF0000">\#(text)</span>"# }
    static func blue(_ text: String) -> String { #"<span style="color:#0000FF">\#(text)</span>"# }

    static let positionMarks = ["。", "，", "、", "：", "？"]
    static let pairs: [(String, String)] = [("：", "「"), ("？", "」"), ("。", "」"), ("」", "「"), ("、", "「"), ("（", "「")]

    static var cases: [Case] {
        var result: [Case] = []
        for mark in positionMarks {
            result.append(Case(id: "position \(mark)") { "<p>\($0.han)\(red(mark))\($0.han)</p>" })
        }
        for (a, b) in pairs {
            result.append(Case(id: "pair \(a)\(b)") { "<p>\($0.han)\(red(a))\(blue(b))\($0.han)</p>" })
        }
        result.append(Case(id: "latin") { "<p>\($0.han)\(red("Kindle"))\($0.han)</p>" })
        result.append(Case(id: "dash") { "<p>\($0.han)\(red("——"))\($0.han)</p>" })
        result.append(Case(id: "ellipsis") { "<p>\($0.han)\(red("……"))\($0.han)</p>" })
        result.append(Case(id: "tcy") {
            "<p>\($0.han)<span style=\"color:#FF0000;text-combine-upright:all;-webkit-text-combine:horizontal\">12</span>\($0.han)</p>"
        })
        result.append(Case(id: "orientation") { _ in "<p>漢字かなカナKindle 2014年ーー「本」</p>" })
        return result
    }

    static func entries(for script: Script) -> [String: Data] {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
        ]
        var manifest = #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        var spine = ""
        for (index, item) in cases.enumerated() {
            manifest += #"<item id="c\#(index)" href="c\#(index).xhtml" media-type="application/xhtml+xml"/>"#
            spine += #"<itemref idref="c\#(index)"/>"#
            entries["OPS/c\(index).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(script.declared)" lang="\(script.declared)">
            <head><title>\(item.id)</title></head>
            <body><p style="color:#00A000">\(script.lead)</p>\(item.body(script))</body></html>
            """.utf8)
        }
        entries["OPS/package.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:vertical-\(script.name)</dc:identifier>
            <dc:title>Vertical \(script.name)</dc:title>
            <dc:language>\(script.declared)</dc:language>
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """.utf8)
        entries["OPS/nav.xhtml"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
        <body><nav epub:type="toc"><ol><li><a href="c0.xhtml">Start</a></li></ol></nav></body></html>
        """.utf8)
        return entries
    }

    // MARK: Rendering

    /// What one engine drew for one chapter, plus the text it shaped.
    struct Drawn {
        let image: CGImage
        let text: NSAttributedString
        let route: String
    }

    final class Book {
        let session: PublicationSession
        var renderers: [ReaderWritingMode: EPUBPageRenderer] = [:]
        init(session: PublicationSession) { self.session = session }
    }

    static func open(_ script: Script) async throws -> Book {
        let url = try await EPUBTestFixtures.makeArchive(entries: entries(for: script))
        return Book(session: try await PublicationSession.open(sourceURL: url))
    }

    static func draw(_ engine: Engine, book: Book, spine: Int, mode: ReaderWritingMode) async throws -> Drawn {
        let settings = EPUBTestFixtures.renderSettings(fontSize: fontSize, writingMode: mode)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        switch engine {
        case .browser:
            let renderer: EPUBPageRenderer
            if let existing = book.renderers[mode] {
                renderer = existing
            } else {
                renderer = EPUBPageRenderer()
                renderer.load(publicationSession: book.session, bookIdentifier: UUID().uuidString,
                    renderSize: pageSize, settings: settings)
                for await ready in renderer.$isCoreTextReady.values where ready { break }
                book.renderers[mode] = renderer
            }
            let pageEngine = try #require(renderer.engine as? BrowserLayoutPageEngine)
            _ = await pageEngine.preloadChapter(at: spine)
            let route = pageEngine.choice(for: spine)?.debugLabel ?? "nil"
            guard let layout = pageEngine.testLayout(for: spine) else {
                // Sent to legacy: draw that engine instead, and say so in the route.
                let legacy = try await draw(.legacy, book: book, spine: spine, mode: mode)
                return Drawn(image: legacy.image, text: legacy.text, route: route)
            }
            let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
            let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                ReaderDisplayListDrawer.draw(list, in: context.cgContext)
            }
            let text = NSMutableAttributedString()
            for item in list.items {
                if case .text(let fragment) = item { text.append(fragment.attributedText) }
            }
            return Drawn(image: try #require(image.cgImage), text: text, route: route)
        case .legacy:
            let builder = EPUBAttributedStringBuilder(session: book.session, renderSize: pageSize)
            let built = try await builder.buildChapter(at: spine, settings: settings,
                themeTextColor: .black, themeBackgroundColor: .white)
            let layout = await CoreTextPaginator().paginate(
                spineIndex: spine, attrStr: built.attributedString, renderSize: pageSize,
                fontSize: fontSize, contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
                writingMode: mode)
            let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                CoreTextPageView.renderPage(layout: layout, pageIndex: 0, in: context.cgContext,
                    bounds: CGRect(origin: .zero, size: pageSize))
            }
            let prepared = CoreTextPaginator.preparedAttributedString(built.attributedString,
                writingMode: mode, fontSize: fontSize, maxInlineAnnotationAdvance: nil)
            return Drawn(image: try #require(image.cgImage), text: prepared, route: "legacy")
        }
    }

    // MARK: Ink

    enum Ink { case red, blue, black }

    /// Bounding boxes of coloured ink, in pixels.
    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 255, count: w * h * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytes = buffer
        }

        func matches(_ ink: Ink, x: Int, y: Int) -> Bool {
            // Row 0 of a bitmap context's buffer is the top of the image.
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            switch ink {
            case .red: return r > 150 && g < 120 && b < 120 && r - g > 70
            case .blue: return b > 150 && r < 120 && g < 140 && b - r > 70
            case .black: return r < 110 && g < 110 && b < 110 && abs(r - g) < 40 && abs(g - b) < 40
            }
        }

        func box(_ ink: Ink, in window: CGRect? = nil) -> CGRect? {
            let area = window ?? CGRect(x: 0, y: 0, width: width, height: height)
            let x0 = max(0, Int(area.minX)), x1 = min(width, Int(area.maxX.rounded(.up)))
            let y0 = max(0, Int(area.minY)), y1 = min(height, Int(area.maxY.rounded(.up)))
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) where matches(ink, x: x, y: y) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard minX != .max else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    /// A target's ink and its two Han neighbours along the column (vertical) or line.
    struct Measure {
        let target: CGRect
        let partner: CGRect?
        let before: CGRect
        let after: CGRect
        let vertical: Bool

        var em: CGFloat { VerticalTypographyAcceptanceTests.em }
        func cross(_ r: CGRect) -> CGFloat { vertical ? r.midX : r.midY }
        func inline(_ r: CGRect) -> CGFloat { vertical ? r.midY : r.midX }
        var columnCentre: CGFloat { (cross(before) + cross(after)) / 2 }
        var cellCentre: CGFloat { (inline(before) + inline(after)) / 2 }
        /// Positive: right of the column centre (vertical), below the line centre (horizontal).
        var crossOffset: CGFloat { (cross(target) - columnCentre) / em }
        /// Positive: later along the text.
        var inlineOffset: CGFloat { (inline(target) - cellCentre) / em }
        /// The ems between the neighbours, less their own two half cells.
        var advance: CGFloat { (inline(after) - inline(before)) / em - 1 }
        var overlap: CGFloat {
            guard let partner else { return 0 }
            let i = target.intersection(partner)
            return i.isNull ? 0 : i.width * i.height
        }
        var targetCrossExtent: CGFloat { (vertical ? target.width : target.height) / em }
        var targetInlineExtent: CGFloat { (vertical ? target.height : target.width) / em }
    }

    static func measure(_ drawn: Drawn, vertical: Bool) throws -> Measure {
        let pixels = Pixels(drawn.image)
        let target = try #require(pixels.box(.red), "no red ink")
        let partner = pixels.box(.blue)
        let both = partner.map { target.union($0) } ?? target
        // The column (or line) the target sits in, a little wider than one em.
        let crossCentre = vertical ? both.midX : both.midY
        let band = em * 0.75
        let reach = em * 2.5
        let window: (CGFloat, CGFloat) -> CGRect = { start, end in
            vertical
                ? CGRect(x: crossCentre - band, y: start, width: band * 2, height: end - start)
                : CGRect(x: start, y: crossCentre - band, width: end - start, height: band * 2)
        }
        let lower = vertical ? both.minY : both.minX
        let upper = vertical ? both.maxY : both.maxX
        let before = try #require(pixels.box(.black, in: window(lower - reach, lower - 1)), "no Han before")
        let after = try #require(pixels.box(.black, in: window(upper + 1, upper + reach)), "no Han after")
        return Measure(target: target, partner: partner, before: before, after: after, vertical: vertical)
    }

    // MARK: Glyph facts from the shaped text

    struct GlyphFact { let character: String; let upright: Bool; let font: String }

    static func facts(of text: NSAttributedString) -> [GlyphFact] {
        let verticalForms = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)
        let line = CTLineCreateWithAttributedString(text)
        var fonts: [Int: String] = [:]
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let range = CTRunGetStringRange(run)
            for index in range.location..<(range.location + range.length) {
                fonts[index] = CTFontCopyPostScriptName(font) as String
            }
        }
        let ns = text.string as NSString
        var result: [GlyphFact] = []
        var index = 0
        while index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let upright = (text.attribute(verticalForms, at: range.location, effectiveRange: nil) as? Bool) == true
            result.append(GlyphFact(character: ns.substring(with: range), upright: upright,
                font: fonts[range.location] ?? "-"))
            index = NSMaxRange(range)
        }
        return result
    }

    // MARK: Tests

    @Test(arguments: Engine.allCases)
    func positions(engine: Engine) async throws {
        for script in Self.scripts {
            let book = try await Self.open(script)
            for mode in [ReaderWritingMode.verticalRTL, .horizontal] {
                for mark in Self.positionMarks {
                    let spine = try #require(Self.cases.firstIndex { $0.id == "position \(mark)" })
                    let drawn = try await Self.draw(engine, book: book, spine: spine, mode: mode)
                    let m = try Self.measure(drawn, vertical: mode.isVertical)
                    let label = "\(engine) \(script) \(mode.rawValue) \(mark) cross=\(m.crossOffset) inline=\(m.inlineOffset) route=\(drawn.route)"
                    let centred = abs(m.crossOffset) <= 0.12 && abs(m.inlineOffset) <= 0.12
                    // A pause mark in Mainland or Japanese text sits in the corner after the
                    // text it follows: top right in vertical, bottom left in horizontal. Both
                    // read as "across positive, along negative" here.
                    let cornered = m.crossOffset >= 0.12 && m.inlineOffset <= -0.12
                    let isPause = ["。", "，", "、"].contains(mark)
                    withKnownIssue("Task 6", isIntermittent: true) {
                        switch (script.name, isPause) {
                        case ("traditional", _): #expect(centred, "\(label)")
                        case (_, true): #expect(cornered, "\(label)")
                        case ("japanese", false): #expect(centred, "\(label)")
                        default: break // Mainland ：？ follow PingFang SC; no fixed place here.
                        }
                    }
                    print("⟐VT position \(label)")
                }
            }
        }
    }

    @Test(arguments: Engine.allCases)
    func adjacentPunctuation(engine: Engine) async throws {
        for script in Self.scripts {
            let book = try await Self.open(script)
            for mode in [ReaderWritingMode.verticalRTL, .horizontal] {
                for (a, b) in Self.pairs {
                    let spine = try #require(Self.cases.firstIndex { $0.id == "pair \(a)\(b)" })
                    let drawn = try await Self.draw(engine, book: book, spine: spine, mode: mode)
                    let m = try Self.measure(drawn, vertical: mode.isVertical)
                    let label = "\(engine) \(script) \(mode.rawValue) \(a)\(b) advance=\(m.advance) overlap=\(m.overlap) route=\(drawn.route)"
                    withKnownIssue("Task 7", isIntermittent: true) {
                        #expect(m.overlap <= 1, "\(label)")
                        if script.name == "japanese" && (a == "：" || a == "？") {
                            #expect(m.advance >= 1.45 && m.advance <= 2.05, "\(label)")
                        } else {
                            #expect(abs(m.advance - 1.5) <= 0.06, "\(label)")
                        }
                    }
                    print("⟐VT pair \(label)")
                }
            }
        }
    }

    @Test(arguments: Engine.allCases)
    func orientationAndFonts(engine: Engine) async throws {
        for script in Self.scripts {
            let book = try await Self.open(script)
            let spine = try #require(Self.cases.firstIndex { $0.id == "orientation" })
            let drawn = try await Self.draw(engine, book: book, spine: spine, mode: .verticalRTL)
            let facts = Self.facts(of: drawn.text)
            func fact(_ character: String) -> GlyphFact? { facts.first { $0.character == character } }
            let label = "\(engine) \(script) " + facts.map { "\($0.character)\($0.upright ? "↑" : "→")\($0.font)" }.joined(separator: " ")
            print("⟐VT orientation \(label)")
            for character in ["漢", "字", "か", "な", "カ", "ナ", "年", "ー", "「", "」"] {
                #expect(fact(character)?.upright == true, "\(character) upright: \(label)")
            }
            for character in ["K", "i", "n", "d", "l", "e", "2", "0", "1", "4"] {
                #expect(fact(character)?.upright == false, "\(character) rotated: \(label)")
            }
            withKnownIssue("Task 5", isIntermittent: true) {
                #expect(fact("漢")?.font == script.hanFont, "Han font: \(label)")
                if script.name == "japanese" {
                    #expect(fact("か")?.font == "HiraginoSans-W3", "kana font: \(label)")
                }
            }
        }
    }

    @Test(arguments: Engine.allCases)
    func rotatedRunsSitOnTheColumn(engine: Engine) async throws {
        for script in Self.scripts {
            let book = try await Self.open(script)
            for id in ["latin", "dash", "ellipsis"] {
                let spine = try #require(Self.cases.firstIndex { $0.id == id })
                let drawn = try await Self.draw(engine, book: book, spine: spine, mode: .verticalRTL)
                let m = try Self.measure(drawn, vertical: true)
                let label = "\(engine) \(script) \(id) cross=\(m.crossOffset) crossExtent=\(m.targetCrossExtent) route=\(drawn.route)"
                print("⟐VT rotated \(label)")
                if engine == .legacy {
                    // Legacy draws Han from the system font's fallback, which CoreText sets
                    // off the baseline in vertical text; Task 5 names the CJK font outright.
                    withKnownIssue("Task 5", isIntermittent: true) {
                        #expect(abs(m.crossOffset) <= (id == "latin" ? 0.05 : 0.1), "\(label)")
                    }
                } else {
                    #expect(abs(m.crossOffset) <= (id == "latin" ? 0.05 : 0.1), "\(label)")
                }
                if id != "latin" {
                    // A dash or an ellipsis turned along the column is narrow across it.
                    #expect(m.targetCrossExtent <= 0.3, "\(label)")
                }
            }
        }
    }

    @Test(arguments: Engine.allCases)
    func authoredTateChuYoko(engine: Engine) async throws {
        for script in Self.scripts {
            let book = try await Self.open(script)
            let spine = try #require(Self.cases.firstIndex { $0.id == "tcy" })
            let drawn = try await Self.draw(engine, book: book, spine: spine, mode: .verticalRTL)
            let m = try Self.measure(drawn, vertical: true)
            let label = "\(engine) \(script) tcy inline=\(m.targetInlineExtent) cross=\(m.targetCrossExtent) offset=\(m.crossOffset) route=\(drawn.route)"
            print("⟐VT tcy \(label)")
            withKnownIssue("Task 8", isIntermittent: true) {
                // Upright and side by side, 「12」 is wider across the column than along it;
                // turned on its side, as text without 縦中横 is, it is the other way round.
                #expect(m.targetCrossExtent > m.targetInlineExtent, "\(label)")
                #expect(m.targetInlineExtent <= 1.05, "\(label)")
                #expect(m.targetCrossExtent <= 1.0, "\(label)")
                #expect(abs(m.crossOffset) <= 0.1, "\(label)")
                if engine == .browser { #expect(drawn.route == "browser", "\(label)") }
            }
            #expect(drawn.text.string.contains("12"), "the text keeps both digits: \(label)")
        }
    }
}
