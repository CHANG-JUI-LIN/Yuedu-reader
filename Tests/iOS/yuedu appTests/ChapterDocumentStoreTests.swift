import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Chapter document store", .serialized)
struct ChapterDocumentStoreTests {
    @Test("Page and scroll requests share one in-flight chapter build")
    @MainActor
    func concurrentConsumersShareOneBuild() async throws {
        let probe = ChapterDocumentBuildProbe(holdsBuilds: true)
        let builder = ChapterDocumentTestBuilder(probe: probe)
        let store = ChapterDocumentStore(builder: builder)
        let request = makeRequest(spineIndex: 2)

        async let pageDocument = store.document(for: request)
        async let scrollDocument = store.document(for: request)

        await probe.waitUntilBuildCount(1)
        await probe.releaseBuilds()
        let (page, scroll) = try await (pageDocument, scrollDocument)

        #expect(await probe.buildCount == 1)
        #expect(page.revision == scroll.revision)
        #expect(page.attributedString.string == "chapter-2")
    }

    @Test("Paged and scroll engines consume the same chapter document")
    @MainActor
    func readerEnginesShareTheInjectedStore() async throws {
        let probe = ChapterDocumentBuildProbe()
        let builder = ChapterDocumentTestBuilder(probe: probe, chapterCount: 1)
        let store = ChapterDocumentStore(builder: builder)
        let settings = makeRequest().settings
        let offsetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterDocumentStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: offsetDirectory) }
        let pageEngine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: settings,
            chapterDocumentStore: store,
            offsetStore: CharOffsetStore(directoryURL: offsetDirectory)
        )
        let scrollEngine = CoreTextScrollEngine(
            builder: builder,
            renderSettings: settings,
            chapterDocumentStore: store
        )

        await pageEngine.start(
            renderSize: CGSize(width: 320, height: 480),
            bookId: "chapter-document-store-test"
        )
        await scrollEngine.start(initialChapter: 0, contentWidth: 288)

        #expect(await probe.buildCount == 1)
    }

    @Test("Paged chapter data change rebuilds the chapter document")
    @MainActor
    func pagedChapterDataChangeRebuildsDocument() async throws {
        let probe = ChapterDocumentBuildProbe()
        let builder = ChapterDocumentTestBuilder(probe: probe, chapterCount: 1)
        let store = ChapterDocumentStore(builder: builder)
        let offsetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterDocumentRefreshTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: offsetDirectory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: makeRequest().settings,
            chapterDocumentStore: store,
            offsetStore: CharOffsetStore(directoryURL: offsetDirectory)
        )

        await engine.start(
            renderSize: CGSize(width: 320, height: 480),
            bookId: "chapter-document-refresh-test"
        )
        #expect(await probe.buildCount == 1)

        await engine.notifyChapterDataChanged(at: 0)

        #expect(await probe.buildCount == 2)
    }

    @Test("Scroll chapter refresh rebuilds the chapter document during reslice")
    @MainActor
    func scrollChapterRefreshRebuildsDocument() async throws {
        let probe = ChapterDocumentBuildProbe()
        let builder = ChapterDocumentTestBuilder(probe: probe, chapterCount: 1)
        let store = ChapterDocumentStore(builder: builder)
        let engine = CoreTextScrollEngine(
            builder: builder,
            renderSettings: makeRequest().settings,
            chapterDocumentStore: store
        )

        await engine.start(initialChapter: 0, contentWidth: 288)
        #expect(await probe.buildCount == 1)

        engine.invalidateChapterDocument(at: 0)
        await engine.reslice(restoreAt: 0, contentWidth: 288)

        #expect(await probe.buildCount == 2)
    }

    @Test("Layout-affecting settings create a distinct chapter document")
    @MainActor
    func layoutSettingsInvalidateIdentity() async throws {
        let probe = ChapterDocumentBuildProbe()
        let store = ChapterDocumentStore(builder: ChapterDocumentTestBuilder(probe: probe))

        let first = try await store.document(for: makeRequest(fontSize: 18))
        let second = try await store.document(for: makeRequest(fontSize: 22))

        #expect(await probe.buildCount == 2)
        #expect(first.revision != second.revision)
    }

    @Test("Bounded document cache evicts the least recently used request")
    @MainActor
    func boundedCacheUsesLRUEviction() async throws {
        let probe = ChapterDocumentBuildProbe()
        let store = ChapterDocumentStore(
            builder: ChapterDocumentTestBuilder(probe: probe),
            capacity: 2
        )
        let first = makeRequest(spineIndex: 0)
        let second = makeRequest(spineIndex: 1)
        let third = makeRequest(spineIndex: 2)

        _ = try await store.document(for: first)
        _ = try await store.document(for: second)
        _ = try await store.document(for: first)
        _ = try await store.document(for: third)
        _ = try await store.document(for: second)

        #expect(await probe.buildCount == 4)
    }

    @Test("Explicit invalidation cancels ownership and rebuilds on demand")
    @MainActor
    func invalidationRebuildsDocument() async throws {
        let probe = ChapterDocumentBuildProbe()
        let store = ChapterDocumentStore(builder: ChapterDocumentTestBuilder(probe: probe))
        let request = makeRequest()

        let first = try await store.document(for: request)
        store.invalidateAll()
        let second = try await store.document(for: request)

        #expect(await probe.buildCount == 2)
        #expect(first.revision != second.revision)
    }

    @Test("Chapter invalidation rebuilds only the requested spine")
    @MainActor
    func chapterInvalidationIsTargeted() async throws {
        let probe = ChapterDocumentBuildProbe()
        let store = ChapterDocumentStore(builder: ChapterDocumentTestBuilder(probe: probe))
        let firstRequest = makeRequest(spineIndex: 0)
        let secondRequest = makeRequest(spineIndex: 1)

        let firstBefore = try await store.document(for: firstRequest)
        let secondBefore = try await store.document(for: secondRequest)

        store.invalidate(spineIndex: 0)

        let firstAfter = try await store.document(for: firstRequest)
        let secondAfter = try await store.document(for: secondRequest)

        #expect(await probe.buildCount == 3)
        #expect(firstBefore.revision != firstAfter.revision)
        #expect(secondBefore.revision == secondAfter.revision)
    }

    private func makeRequest(
        spineIndex: Int = 0,
        fontSize: CGFloat = 18
    ) -> ChapterDocumentRequest {
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: fontSize,
            lineHeightMultiple: 1.4,
            lineSpacing: 2,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 16,
            marginV: 12,
            footerHeight: 0,
            contentInsets: .zero
        )
        return ChapterDocumentRequest(
            spineIndex: spineIndex,
            settings: settings,
            themeTextColor: settings.textColor,
            themeBackgroundColor: settings.backgroundColor
        )
    }
}

private actor ChapterDocumentBuildProbe {
    private(set) var buildCount = 0
    private let holdsBuilds: Bool
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(holdsBuilds: Bool = false) {
        self.holdsBuilds = holdsBuilds
    }

    func beginBuild() async {
        buildCount += 1
        let ready = countWaiters.filter { buildCount >= $0.count }
        countWaiters.removeAll { buildCount >= $0.count }
        ready.forEach { $0.continuation.resume() }

        guard holdsBuilds else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBuildCount(_ count: Int) async {
        guard buildCount < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func releaseBuilds() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct ChapterDocumentTestBuilder: AttributedStringBuilding {
    let probe: ChapterDocumentBuildProbe
    var chapterCount = 3

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    func chapterDataSize(at index: Int) async -> Int { 9 }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        await probe.beginBuild()
        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: "chapter-\(index)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
