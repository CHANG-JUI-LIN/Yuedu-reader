import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader page snapshot performance", .serialized)
@MainActor
struct ReaderPageSnapshotPerformanceTests {
    @Test("paired curl requests preserve pixels and report actual snapshot work")
    func pairedMiddlePageRequests() async throws {
        let engine = makeEngine()
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        #expect(engine.totalPages > 25)
        for pass in 0..<3 {
            var sharedPairs = 0
            var pixelPair: (UIImage, UIImage)?
            let started = SourcePerfTrace.now
            for page in 1...24 {
                let first = try #require(engine.renderSnapshot(forPage: page))
                let second = try #require(engine.renderSnapshot(forPage: page))
                if first === second { sharedPairs += 1 }
                if page == 1 { pixelPair = (first, second) }
            }
            let ms = (SourcePerfTrace.now - started) * 1000
            SourcePerfTrace.record("fixture.curlSnapshotPairs", "pass=\(pass) requests=48 sharedPairs=\(sharedPairs)",
                                   since: started, thresholdMs: 0)
            print(String(format: "SNAPSHOT_PERF pass=%d pairs=24 requests=48 sharedPairs=%d elapsedMs=%.3f", pass, sharedPairs, ms))
            #expect(sharedPairs == 24)
            let pair = try #require(pixelPair)
            #expect(pair.0.size == Self.size)
            #expect(pair.0.pngData() == pair.1.pngData())
        }
    }

    @Test("middle, first and last snapshots are reused and appearance invalidates all three")
    func appearanceInvalidatesAllPageKinds() async throws {
        let engine = makeEngine()
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        // Engine starts with dynamic UIKit colors; make both palettes explicit.
        engine.applyThemeChange(textColor: .black, backgroundColor: .white)
        let last = try #require(engine.lastPageIndex(ofChapter: 0))
        for page in [0, 1, last] {
            let first = try #require(engine.renderSnapshot(forPage: page))
            #expect(engine.renderSnapshot(forPage: page) === first)
            let staleKey = try #require(engine.snapshotKey(spineIndex: 0, localPage: page))
            engine.applyThemeChange(textColor: .white, backgroundColor: .black)
            #expect(!engine.storeSnapshotIfCurrent(first, key: staleKey, spineIndex: 0, localPage: page))
            let dark = try #require(engine.renderSnapshot(forPage: page))
            #expect(dark !== first)
            #expect(dark.pngData() != first.pngData())
            #expect(engine.renderSnapshot(forPage: page) === dark)
            engine.applyThemeChange(textColor: .black, backgroundColor: .white)
        }
    }

    @Test("refetched content rejects old asynchronous boundary and middle-page results")
    func contentReplacementInvalidatesSnapshots() async throws {
        let builder = SnapshotFixtureBuilder()
        let engine = makeEngine(builder: builder)
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        let oldFirst = try #require(engine.renderSnapshot(forPage: 0))
        let oldMiddle = try #require(engine.renderSnapshot(forPage: 1))
        let firstKey = try #require(engine.snapshotKey(spineIndex: 0, localPage: 0))
        let middleKey = try #require(engine.snapshotKey(spineIndex: 0, localPage: 1))
        await builder.replaceText(String(repeating: "遠處海面升起朝陽，新的旅程從此開始。\n", count: 1200))
        await engine.notifyChapterDataChanged(at: 0)
        await engine.preloadChapter(at: 0)
        #expect(!engine.storeSnapshotIfCurrent(oldFirst, key: firstKey, spineIndex: 0, localPage: 0))
        #expect(!engine.storeSnapshotIfCurrent(oldMiddle, key: middleKey, spineIndex: 0, localPage: 1))
        let first = try #require(engine.renderSnapshot(forPage: 0))
        let middle = try #require(engine.renderSnapshot(forPage: 1))
        #expect(first.pngData() != oldFirst.pngData())
        #expect(middle.pngData() != oldMiddle.pngData())
        #expect(engine.renderSnapshot(forPage: 1) === middle)
    }

    @Test("viewport relayout rejects old snapshot results and renders the new dimensions")
    func resizedLayoutInvalidatesSnapshots() async throws {
        let engine = makeEngine()
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        let old = try #require(engine.renderSnapshot(forPage: 1))
        let oldKey = try #require(engine.snapshotKey(spineIndex: 0, localPage: 1))
        let resized = CGSize(width: 420, height: 620)
        await engine.invalidateLayout(newSize: resized)
        await engine.preloadChapter(at: 0)
        #expect(!engine.storeSnapshotIfCurrent(old, key: oldKey, spineIndex: 0, localPage: 1))
        let current = try #require(engine.renderSnapshot(forPage: 1))
        #expect(current.size == resized)
        #expect(current !== old)
        #expect(engine.renderSnapshot(forPage: 1) === current)
    }

    private func makeEngine(builder: SnapshotFixtureBuilder = SnapshotFixtureBuilder()) -> CoreTextPageEngine {
        CoreTextPageEngine(attributedBuilder: builder, renderSettings: Self.settings,
                           offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent("SnapshotFixture-\(UUID().uuidString)")))
    }

    private static let size = CGSize(width: 360, height: 560)
    private static let settings = ReaderRenderSettings(
        theme: "light", textColor: .black, backgroundColor: .white,
        fontSize: 18, lineHeightMultiple: 1.4, lineSpacing: 4, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 24, marginV: 16, footerHeight: 16,
        contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
    )
}

private actor SnapshotFixtureBuilder: AttributedStringBuilding {
    nonisolated var chapterCount: Int { 1 }
    nonisolated var prefersLazyByteScan: Bool { true }
    private var text = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。\n", count: 1200)
    nonisolated func chapterTitle(at index: Int) -> String { "Fixture" }
    func chapterDataSize(at index: Int) -> Int { text.utf8.count }
    func replaceText(_ value: String) { text = value }
    func buildChapter(at index: Int, settings: ReaderRenderSettings,
                      themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize),
            .foregroundColor: themeTextColor, .backgroundColor: themeBackgroundColor
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}
