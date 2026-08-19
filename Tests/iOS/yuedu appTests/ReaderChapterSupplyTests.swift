import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// The chapter-supply contract, guarded at the engine.
///
/// Two rules, both violated in ways that looked identical to the user — a 載入中 placeholder
/// that never went away and could only be cleared by leaving the book or re-entering the
/// chapter from another one:
///
/// 1. Installing a layout and announcing it are one act. Consumers of `layouts` learn a
///    chapter became renderable only through `onChapterReady`; two of the three exits that
///    installed a layout used to return without firing it.
/// 2. Joining an in-flight pagination must not report success when that pagination was
///    abandoned. Returning "done, no layout" made callers stop asking forever.
@MainActor
@Suite("Reader chapter supply")
struct ReaderChapterSupplyTests {

    @Test("a completed pagination announces the chapter it laid out")
    func completedPaginationAnnouncesChapter() async throws {
        let builder = ControllableChapterBuilder(chapterCount: 2)
        let engine = makeEngine(builder: builder)
        await engine.start(renderSize: Self.renderSize, bookId: UUID().uuidString)

        let announced = AnnouncementLog()
        engine.onChapterReady = { announced.record($0) }

        await engine.preloadChapter(at: 1)

        #expect(engine.layouts[1] != nil)
        #expect(announced.spines.contains(1))
    }

    @Test("joining an abandoned pagination lays the chapter out instead of giving up")
    func joiningAbandonedPaginationRetries() async throws {
        let builder = ControllableChapterBuilder(chapterCount: 2)
        let engine = makeEngine(builder: builder)
        await engine.start(renderSize: Self.renderSize, bookId: UUID().uuidString)

        await builder.gateNextBuild(chapter: 1)

        // Owner: installs the preload task, then parks inside the build.
        let owner = Task { await engine.preloadChapter(at: 1) }
        await builder.waitUntilBuilding(chapter: 1)

        // Joiner: shares the owner's task rather than starting its own.
        let joiner = Task { await engine.preloadChapter(at: 1) }
        await Task.yield()

        // The owner's task is abandoned — this is what a refresh transaction did to a
        // neighbouring chapter's supply on every online book open.
        engine.cancelPendingWork()
        await builder.releaseGate(chapter: 1)

        await owner.value
        await joiner.value

        // Neither caller was cancelled, so both are still owed a layout.
        #expect(engine.layouts[1] != nil)
    }

    @Test("a chapter whose content is not available yet fails fast instead of looping")
    func unavailableChapterDoesNotLoop() async throws {
        let builder = ControllableChapterBuilder(chapterCount: 2)
        let engine = makeEngine(builder: builder)
        await engine.start(renderSize: Self.renderSize, bookId: UUID().uuidString)

        // An online chapter whose fetch has not landed: the builder has nothing to build.
        await builder.failBuilds(chapter: 1)

        await engine.preloadChapter(at: 1)

        // No layout, and no retry — nothing superseded us, so asking again would only
        // spin. Getting the content here is the fetch's job, not pagination's.
        #expect(engine.layouts[1] == nil)
        #expect(await builder.buildCount(chapter: 1) == 1)
    }

    // MARK: - Support

    private static let renderSize = CGSize(width: 360, height: 560)

    private func makeEngine(builder: ControllableChapterBuilder) -> CoreTextPageEngine {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderChapterSupply-\(UUID().uuidString)")
        return CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: Self.renderSettings,
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
    }

    private static let renderSettings = ReaderRenderSettings(
        theme: "light",
        textColor: .black,
        backgroundColor: .white,
        fontSize: 18,
        lineHeightMultiple: 1.4,
        lineSpacing: 4,
        paragraphSpacing: 6,
        letterSpacing: 0,
        marginH: 24,
        marginV: 16,
        footerHeight: 16,
        contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
    )
}

/// Records what the engine announced. A plain captured local would be shared mutable state
/// across the escaping callback; this keeps the reads on the main actor with the test.
@MainActor
private final class AnnouncementLog {
    private(set) var spines: [Int] = []
    private(set) var globalAnnouncements = 0

    func record(_ spineIndex: Int?) {
        if let spineIndex {
            spines.append(spineIndex)
        } else {
            globalAnnouncements += 1
        }
    }
}

/// Chapter source whose builds can be parked or failed per chapter, so a test can reproduce
/// the orderings that used to strand a placeholder.
private actor ControllableChapterBuilder: AttributedStringBuilding {
    nonisolated let chapterCount: Int

    private var gatedChapters: Set<Int> = []
    private var failingChapters: Set<Int> = []
    private var buildCounts: [Int: Int] = [:]
    private var gateContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var buildingWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var building: Set<Int> = []

    init(chapterCount: Int) {
        self.chapterCount = chapterCount
    }

    /// The next build of `chapter` parks until `releaseGate`. One-shot: later builds run.
    func gateNextBuild(chapter: Int) {
        gatedChapters.insert(chapter)
    }

    func releaseGate(chapter: Int) {
        gatedChapters.remove(chapter)
        gateContinuations.removeValue(forKey: chapter)?.resume()
    }

    func failBuilds(chapter: Int) {
        failingChapters.insert(chapter)
    }

    func buildCount(chapter: Int) -> Int {
        buildCounts[chapter, default: 0]
    }

    func waitUntilBuilding(chapter: Int) async {
        guard !building.contains(chapter) else { return }
        await withCheckedContinuation { continuation in
            buildingWaiters[chapter, default: []].append(continuation)
        }
    }

    private func markBuilding(_ chapter: Int) {
        building.insert(chapter)
        buildingWaiters.removeValue(forKey: chapter)?.forEach { $0.resume() }
    }

    // MARK: AttributedStringBuilding

    nonisolated func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    nonisolated func chapterSourceHref(at index: Int) -> String? { "Text/chapter\(index).xhtml" }
    nonisolated func chapterIndex(for href: String) -> Int? {
        (0..<chapterCount).first { chapterSourceHref(at: $0) == href }
    }
    func chapterDataSize(at index: Int) async -> Int { Self.chapterText.utf8.count }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        buildCounts[index, default: 0] += 1
        markBuilding(index)

        if gatedChapters.contains(index) {
            await withCheckedContinuation { continuation in
                gateContinuations[index] = continuation
            }
        }
        if failingChapters.contains(index) {
            throw AttributedStringBuildingError.contentNotCached(index)
        }

        let attributed = NSAttributedString(
            string: Self.chapterText,
            attributes: [
                .font: UIFont.systemFont(ofSize: settings.fontSize),
                .foregroundColor: themeTextColor,
                .backgroundColor: themeBackgroundColor,
            ]
        )
        return AttributedChapterBuildResult(
            attributedString: attributed,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    static let chapterText = String(repeating: "斯是陋室，惟吾德馨。苔痕上階綠，草色入簾青。", count: 40)
}
