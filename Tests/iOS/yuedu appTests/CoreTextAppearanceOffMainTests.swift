import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreTextTypography
@testable import yuedu_app

/// Crashlytics 27c07ad8 (3.0.1 build 146): an online 西遊記 that arrives as one chapter
/// was paginated off the main thread and then given the reader's appearance on it —
/// `ChapterLayout.withUpdatedAppearance` builds a framesetter over the whole chapter and
/// a `CTFrame` for every page. The main thread was blocked ≥12.4 s and the watchdog
/// killed the app.
///
/// The chapter here is a quarter of the one that reproduced it (1.2 M CJK characters,
/// 1,376 pages at 390×844), to keep the suite fast. Measured on the full chapter (Debug,
/// simulator): the main thread ran 23784 ms while the chapter preloaded before — the
/// appearance step twice, once for the first page and once for the full layout — and
/// 1661 ms after, in a 96 s preload during which an idle test host spends about as much;
/// longest unanswered main-queue ping 12350 ms → 143 ms.
@Suite("Chapter appearance is applied off the main thread", .serialized)
@MainActor
struct CoreTextAppearanceOffMainTests {
    static let renderSize = CGSize(width: 390, height: 844)

    /// Paragraphs of varying length, fixed seed: every run lays out the same text.
    static func wholeBookChapter(characters: Int) -> String {
        let sentences = [
            "詩曰：混沌未分天地亂，茫茫渺渺無人見。",
            "自從盤古破鴻濛，開闢從茲清濁辨。",
            "覆載群生仰至仁，發明萬物皆成善。",
            "欲知造化會元功，須看西遊釋厄傳。",
            "蓋聞天地之數，有十二萬九千六百歲為一元。",
            "將一元分為十二會，乃子、丑、寅、卯、辰、巳、午、未、申、酉、戌、亥之十二支也。",
        ]
        var state: UInt64 = 1
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var text = ""
        text.reserveCapacity(characters * 3)
        var count = 0
        while count < characters {
            for _ in 0..<(2 + next(7)) {
                let sentence = sentences[next(sentences.count)]
                text += sentence
                count += sentence.count
            }
            text += "\n"
            count += 1
        }
        return text
    }

    private func makeEngine(texts: [String]) -> (CoreTextPageEngine, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: texts),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        return (engine, directory)
    }

    /// The assertion is on the main thread's CPU time (see `MainThreadWatchdog`): the test
    /// host blocks its own main thread for up to ~600 ms at random, so the longest
    /// unanswered ping is printed for diagnosis only.
    @Test func preloadingAWholeBookChapterDoesNotFrameItsPagesOnTheMainThread() async throws {
        let (engine, directory) = makeEngine(texts: ["開場。", Self.wholeBookChapter(characters: 300_000)])
        defer { try? FileManager.default.removeItem(at: directory) }
        await engine.start(renderSize: Self.renderSize, bookId: UUID().uuidString)

        let watchdog = MainThreadWatchdog()
        watchdog.start()
        let start = ContinuousClock.now
        let cpuStart = MainThreadWatchdog.mainThreadCPUSeconds()
        await engine.preloadChapter(at: 1)
        let mainCPU = MainThreadWatchdog.mainThreadCPUSeconds() - cpuStart
        let elapsed = ContinuousClock.now - start
        let longest = watchdog.stop()
        let layout = try #require(engine.layouts[1])
        print("⏱ wholeBookChapter preload=\(elapsed) mainThreadCPU=\(Int(mainCPU * 1000)) ms "
              + "longestMainBlock=\(Int(longest * 1000)) ms pages=\(layout.pageRanges.count)")
        #expect(!layout.isPartial)
        #expect(layout.pageRanges.count > 300)
        #expect(layout.pageArtifacts.count == layout.pageRanges.count)
        // This quarter-size chapter: 74 ms of main-thread CPU in a 4.2 s preload. One
        // appearance step over it is 554 ms and the main thread used to run two.
        #expect(mainCPU < 0.5, "the main thread typeset the chapter again for its appearance")
    }

    /// What the appearance step costs and where. On the full chapter: 9401 ms, of which
    /// the framesetter (typesetting the whole chapter again) is 8252 ms and the page
    /// frames 1269 ms — so building frames lazily per page would not have removed it. The
    /// typesetting is worse than linear: this quarter-size chapter takes 554 ms.
    @Test func appearanceCostBreakdown() async throws {
        let text = Self.wholeBookChapter(characters: 300_000)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.black,
        ])
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: attributed, renderSize: Self.renderSize, fontSize: 17
        )
        func ms(_ body: () -> Void) -> Int {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        var updated = layout
        let whole = ms {
            updated = layout.withUpdatedAppearance(textColor: .white, backgroundColor: .black, readerBackgroundImage: nil)
        }
        var framesetter: CTFramesetter?
        let framesetterMs = ms { framesetter = CoreTextFramesetterFactory.make(for: updated.attributedString) }
        let framesMs = ms {
            _ = CoreTextPaginator.makePageArtifacts(
                framesetter: try! #require(framesetter),
                pageRanges: layout.pageRanges,
                contentPathRect: CoreTextPaginator.coreTextContentPathRect(
                    renderSize: layout.renderSize, contentInsets: layout.contentInsets,
                    fontSize: layout.fontSize, writingMode: layout.writingMode
                ),
                writingMode: layout.writingMode
            )
        }
        print("⏱ appearance chars=\(attributed.length) pages=\(layout.pageRanges.count) "
              + "withUpdatedAppearance=\(whole) ms framesetter=\(framesetterMs) ms pageFrames=\(framesMs) ms")
        #expect(updated.pageRanges.map(\.location) == layout.pageRanges.map(\.location))
        #expect(updated.pageArtifacts.count == layout.pageArtifacts.count)
    }
}
