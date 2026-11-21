@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Browser font demand", .serialized)
@MainActor
struct BrowserFontDemandTests {
    @Test func scanCoversShapedFontsIncludingRubyInitialsAndReaderBold() throws {
        let input = CSSFrontendInput.currentCompatibility(html: """
        <body><p>A<strong>B</strong><em>C</em><ruby>D<rt>E</rt></ruby></p>
        <span class="hidden">unused</span></body>
        """, cssTexts: ["""
        body { font-family: Primary, Fallback }
        p::first-letter { font-family: Initial; font-weight: 300 }
        rt { font-family: Annotation; font-style: italic }
        .hidden { display: none; font-family: Hidden }
        .absent { font-family: Unmatched }
        """])
        for bold in [false, true] {
            var config = BrowserLayoutConfig(renderWidth: 320, renderHeight: 480, isBold: bold)
            let scan = BrowserLayoutCapabilityScanner.scan(input: input, configuration: config)
            #expect(scan.supported)
            #expect(!scan.fontRequests.contains { ["hidden", "unmatched"].contains($0.family) })
            #expect(scan.fontRequests.contains(BrowserFontRequest(
                family: "initial", weight: bold ? 700 : 300, italic: false)))
            #expect(scan.fontRequests.contains(BrowserFontRequest(
                family: "annotation", weight: bold ? 700 : 400, italic: true)))
            var shapedRequests: Set<BrowserFontRequest> = []
            config.fontResolver = { families, weight, italic, _ in
                shapedRequests.formUnion(families.map {
                    BrowserFontRequest(family: $0, weight: weight, italic: italic)
                })
                return nil
            }
            // Observe the real layout resolver, rather than replaying the collector.
            _ = try HTMLLayoutDocument(input: input, configuration: config).prepareContinuous()
            #expect(!shapedRequests.isEmpty)
            #expect(shapedRequests.isSubset(of: scan.fontRequests))
        }
    }

    @Test func ingestionDefersFontsAndDemandPreservesEagerLayoutGeometry() async throws {
        let registration = CountingFontRegistration()
        let session = try await PublicationSession.open(sourceURL: makeFontArchive())
        let lazy = EPUBBrowserLayoutResourceAdapter(session: session, fontRegistrationService: registration)
        let html = try await session.chapterHTML(at: 0)
        let input = await lazy.cssFrontendInput(forChapter: 0, html: html)
        #expect(registration.calls == 0)
        var config = BrowserLayoutConfig(renderWidth: 320, renderHeight: 480)
        let scan = BrowserLayoutCapabilityScanner.scan(input: input, configuration: config)
        #expect(scan.supported)
        await lazy.prepareFonts(requests: scan.fontRequests)
        // Regular + bold + italic, but no publication-wide unused face.
        #expect(registration.calls == 3)
        #expect(lazy.fontResolver()?(["Unused"], 400, false, 20) == nil)
        #expect(lazy.fontResolver()?(["Primary"], 400, false, 20) != nil)
        await lazy.prepareFonts(requests: scan.fontRequests)
        #expect(registration.calls == 3)
        config.fontResolver = lazy.fontResolver()
        let size = CGSize(width: 320, height: 480)
        let demandDocument = BrowserLayoutDocument(input: input, config: config)
        let demand = try demandDocument.makeLayout(containerSize: size)
        let demandPages = try await demandDocument.renderPages(containerSize: size)
        let eager = EPUBBrowserLayoutResourceAdapter(session: session)
        _ = await eager.processedCSS(forChapter: 0)
        config.fontResolver = eager.fontResolver()
        let baselineDocument = BrowserLayoutDocument(input: input, config: config)
        let baseline = try baselineDocument.makeLayout(containerSize: size)
        let baselinePages = try await baselineDocument.renderPages(containerSize: size)
        #expect(BrowserLayoutGeometryFingerprint.snapshot(pipeline: demand, pages: demandPages)
            == BrowserLayoutGeometryFingerprint.snapshot(pipeline: baseline, pages: baselinePages))
    }

    @Test(arguments: [false, true])
    func rejectedChapterNeverPreparesBrowserFonts(scroll: Bool) async throws {
        let resource = MockBrowserLayoutResource(chapters: [.init(
            title: "Chapter", href: "chapter.xhtml", html: "<p>Text</p>",
            css: ["p { display: grid; font-family: Unused }"])])
        let settings = EPUBTestFixtures.renderSettings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["Text"]),
            renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: directory))
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings,
            mode: .browserAuto, showDebugOverlay: false)
        defer { engine.cancelPendingWork() }
        if scroll {
            let result = try await engine.makeScrollChapter(at: 0, settings: settings,
                contentSize: CGSize(width: 320, height: 480))
            #expect(result == nil)
        } else {
            await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
            #expect(delegate.layouts[0] != nil)
        }
        #expect(engine.choice(for: 0)?.isBrowser == false)
        #expect(resource.preparedFontRequests.isEmpty)
    }

    @Test func acceptedScrollReloadsFontDemandWhenReaderBoldChanges() async throws {
        let resource = MockBrowserLayoutResource(chapters: [.init(
            title: "Chapter", href: "chapter.xhtml", html: "<p>Text</p>",
            css: ["p { font-family: Primary }"])])
        var settings = EPUBTestFixtures.renderSettings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["Text"]),
            renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: directory))
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings,
            mode: .browserAuto, showDebugOverlay: false)
        defer { engine.cancelPendingWork() }
        for bold in [false, true, false] {
            settings.isBold = bold
            let chapter = try await engine.makeScrollChapter(at: 0, settings: settings,
                contentSize: CGSize(width: 320, height: 480))
            _ = try #require(chapter)
            #expect(resource.preparedFontRequests.last?.contains(BrowserFontRequest(
                family: "primary", weight: bold ? 700 : 400, italic: false)) == true)
        }
        for selected in ["Georgia", "UnavailableFixtureFont"] {
            settings.fontPostScriptName = selected
            _ = try await engine.makeScrollChapter(at: 0, settings: settings,
                contentSize: CGSize(width: 320, height: 480))
            #expect(resource.preparedFontRequests.last?.isEmpty == (selected == "Georgia"))
        }
        settings.fontPostScriptName = nil
        _ = try await engine.makeScrollChapter(at: 0, settings: settings,
            contentSize: CGSize(width: 320, height: 480))
        #expect(resource.preparedFontRequests.last?.contains(BrowserFontRequest(
            family: "primary", weight: 400, italic: false)) == true)
    }

    private func makeFontArchive() async throws -> URL {
        var entries = EPUBTestFixtures.proseSmoke().entries
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf"))
        let faces = ["regular", "bold", "italic", "unused"]
        var manifest = "<item id='css-fonts' href='Styles/fonts.css' media-type='text/css'/>"
        for face in faces {
            entries["OPS/Fonts/\(face).ttf"] = bytes
            manifest += "<item id='font-\(face)' href='Fonts/\(face).ttf' media-type='font/ttf'/>"
        }
        let opf = String(decoding: entries["OPS/package.opf"]!, as: UTF8.self)
        entries["OPS/package.opf"] = Data(opf.replacingOccurrences(of: "</manifest>",
            with: manifest + "</manifest>").utf8)
        entries["OPS/Styles/fonts.css"] = Data("""
        @font-face { font-family: Primary; src: url('../Fonts/regular.ttf') }
        @font-face { font-family: Primary; font-weight:700; src: url('../Fonts/bold.ttf') }
        @font-face { font-family: Primary; font-style:italic; src: url('../Fonts/italic.ttf') }
        @font-face { font-family: Unused; src: url('../Fonts/unused.ttf') }
        body { font-family: Primary }
        """.utf8)
        entries["OPS/chapter1.xhtml"] = Data("""
        <html><head><link rel='stylesheet' href='Styles/fonts.css'></head>
        <body><p id='anchor'><a href='#anchor'>A<strong>B</strong><em>C</em></a></p></body></html>
        """.utf8)
        return try await EPUBTestFixtures.makeArchive(entries: entries)
    }
}

private final class CountingFontRegistration: FontRegistrationServicing {
    var calls = 0
    private let real = CoreTextFontRegistrationService()
    func registerFont(data: Data, alias: String, existingTempURL: URL?) -> FontRegistrationResult? {
        calls += 1
        return real.registerFont(data: data, alias: alias, existingTempURL: existingTempURL)
    }
    func cleanupTemporaryFile(at url: URL) { real.cleanupTemporaryFile(at: url) }
}
