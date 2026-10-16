import Combine
import SwiftUI
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ReaderContinuousProgressTests {
    @Test func chapterEffectsAreDeliveredOnceAndOrdinaryNavigationStillPublishes() {
        let state = ReaderChapterPresentationState()
        var publishes = 0
        let token = state.objectWillChange.sink { publishes += 1 }
        defer { token.cancel() }
        var effects = 0
        for chapter in [0, 1, 1, 0, 2, 2, 3] {
            let change = state.commitScrollChapter(chapter, controlsVisible: false)
            if change.visible { effects += 1 }
            #expect(state.currentChapter == chapter && state.visibleChapter == chapter)
            #expect(!state.consumeCurrentChapterChange())
            #expect(!state.consumeVisibleChapterChange(), "later root redraw must not replay scroll effects")
        }
        #expect(publishes == 0 && effects == 4)
        state.setCurrentChapter(4)
        #expect(publishes == 1 && state.consumeCurrentChapterChange())
        #expect(!state.consumeCurrentChapterChange())
        state.setVisibleChapter(4)
        #expect(publishes == 2 && state.consumeVisibleChapterChange())
        state.setVisibleChapter(4)
        #expect(publishes == 2)
        let visibleChange = state.commitScrollChapter(5, controlsVisible: true)
        #expect(visibleChange.any && publishes == 3)
        #expect(!state.consumeCurrentChapterChange() && !state.consumeVisibleChapterChange())
    }

    @Test func crossChapterScrollRefreshesOverlaysWithoutRebuildingReaderOwner() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let path = [0, 1, 1, 2, 1, 0, 3]
        for scoped in [false, true] {
            let state = ReaderChapterPresentationState()
            let probe = ChapterProbe()
            let refresh = ChapterRootRefresh()
            let coordinator = makeCoordinator("chapters-\(scoped)", positions: PositionStore())
            let host = UIHostingController(rootView: ChapterObservationRoot(chapters: state,
                session: coordinator.navigator.sessionStore, refresh: refresh, probe: probe))
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            let baseline = probe.rootBodies
            let start = SourcePerfTrace.now
            for (step, chapter) in path.enumerated() {
                if scoped {
                    let change = state.commitScrollChapter(chapter, controlsVisible: false)
                    if change.visible { probe.chapterEffects += 1 }
                } else {
                    state.setCurrentChapter(chapter)
                    state.setVisibleChapter(chapter)
                }
                coordinator.send(.scrollCommit(position: .init(spineIndex: chapter, charOffset: step * 37)))
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                #expect(probe.displayedChapter == chapter && probe.displayedOffset == step * 37)
                #expect(probe.displayedFailedChapter == (chapter == 2), "failure overlay must follow live chapter")
            }
            let readingBodies = probe.rootBodies - baseline
            #expect(scoped ? readingBodies == 0 : readingBodies >= 5)
            #expect(probe.chapterEffects == 5)
            // Opening controls/settings later must see the latest chapter, but
            // must not replay background audio/TTS/save side effects.
            refresh.value += 1
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            #expect(probe.rootChapter == 3 && probe.chapterEffects == 5)
            print("[ScrollChapterPublication] scoped=\(scoped) commits=7 rootBodies=\(readingBodies) overlayBodies=\(probe.overlayBodies) effects=\(probe.chapterEffects)")
            SourcePerfTrace.record("test.scroll.chapterPublication", "scoped=\(scoped) rootBodies=\(readingBodies)",
                                   since: start, thresholdMs: 0)
        }
    }

    @Test func explicitNavigationBackToLastRenderedChapterStillDeliversEffects() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = ReaderChapterPresentationState()
        let probe = ChapterProbe()
        let coordinator = makeCoordinator("return-after-scroll", positions: PositionStore())
        let host = UIHostingController(rootView: ChapterObservationRoot(chapters: state,
            session: coordinator.navigator.sessionStore, refresh: ChapterRootRefresh(), probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let rootBodies = probe.rootBodies
        let change = state.commitScrollChapter(2, controlsVisible: false)
        if change.visible { probe.chapterEffects += 1 }
        coordinator.send(.scrollCommit(position: .init(spineIndex: 2, charOffset: 500)))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        #expect(probe.rootBodies == rootBodies && probe.chapterEffects == 1)
        // Root last rendered chapter zero. onChange(of: chapter) would miss this
        // real navigation back to zero; its explicit revision must deliver it.
        state.setCurrentChapter(0)
        state.setVisibleChapter(0)
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        #expect(probe.rootChapter == 0 && probe.chapterEffects == 2)
        #expect(!state.consumeVisibleChapterChange())
    }

    /// Nor on the writing direction: vertical writing, once left out, overwrote the shelf's
    /// progress with its chapter number at every exit.
    @Test func publicationScopeDependsOnTheScrollHostNotTheSourceFormat() {
        #expect(ReaderProgressSyncPolicy.usesSessionLocalScrollProgress(
            isScrollMode: true, hasScrollEngine: true))
        for route in [(false, true), (true, false)] {
            #expect(!ReaderProgressSyncPolicy.usesSessionLocalScrollProgress(
                isScrollMode: route.0, hasScrollEngine: route.1))
        }
    }

    @Test(arguments: [BookPipelineKind.epub, .txt, .html])
    func everyContinuousSourceUsesSessionProgress(kind: BookPipelineKind) async throws {
        let local = ReaderProgressSyncPolicy.usesSessionLocalScrollProgress(
            isScrollMode: true, hasScrollEngine: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = folder.appendingPathComponent("books.json")
        let library = BookStore(metadataFileURL: metadata)
        var book = ReadingBook(title: "Progress", author: "Test", contentFilename: "book." + kind.rawValue)
        book.contentPipelineKind = kind
        library.books = [book]
        let positions = PositionStore()
        let coordinator = makeCoordinator(book.id.uuidString, positions: positions)
        var notifications = 0
        let token = library.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        for position in [CoreTextReadingPosition(spineIndex: 2, charOffset: 300),
                         CoreTextReadingPosition(spineIndex: 1, charOffset: 900)] {
            coordinator.send(.scrollCommit(position: position))
            library.updatePosition(bookId: book.id, position: Double(position.spineIndex) / 10,
                                   notifyLibraryViews: !local)
        }
        #expect(local, "Every continuous source must use session-local progress")
        #expect(notifications == 0)
        #expect(coordinator.navigator.sessionStore.state.location.charOffset == 900)
        await coordinator.navigator.flush()
        #expect(await positions.load(for: book.id.uuidString) == .init(spineIndex: 1, charOffset: 900))
        coordinator.synchronizeLibraryProgress(to: library, bookId: book.id, forceSave: true) {
            (Double($0.spineIndex) + Double($0.charOffset) / 1000) / 10
        }
        #expect(notifications == 1, "leaving the reader still publishes its latest summary")
        #expect(abs((BookStore(metadataFileURL: metadata).readingBook(id: book.id)?.currentPosition ?? 0) - 0.19) < 0.000001)
        #expect(!ReaderProgressSyncPolicy.canPublishIndexPosition(isTXT: true, indexReady: false))
    }

    @Test func reverseAndCrossChapterProgressPersistsWithoutLibraryFanout() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = folder.appendingPathComponent("books.json")
        let library = BookStore(metadataFileURL: metadata)
        let book = ReadingBook(title: "Progress fixture", author: "Test", contentFilename: "test.epub")
        library.books = [book]
        let positions = PositionStore()
        let coordinator = makeCoordinator(book.id.uuidString, positions: positions)
        var notifications = 0
        let token = library.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        var publishedPositions: [Double] = []
        let dataToken = library.shelfPublisher.dropFirst().sink { books in
            publishedPositions.append(books.first?.currentPosition ?? -1)
        }
        defer { dataToken.cancel() }
        let revisionBeforeReading = library.mutationRevision
        let path = [(2, 180), (2, 300), (2, 210), (1, 900), (2, 20)]
        for (spine, offset) in path {
            let position = CoreTextReadingPosition(spineIndex: spine, charOffset: offset)
            coordinator.send(.scrollCommit(position: position))
            coordinator.synchronizeLibraryProgress(to: library, bookId: book.id, forceSave: false) {
                (Double($0.spineIndex) + Double($0.charOffset) / 1000) / 10
            }
            #expect(coordinator.state.location.coreTextPosition == position)
            #expect(abs((library.readingBook(id: book.id)?.currentPosition ?? -1)
                        - (Double(spine) + Double(offset) / 1000) / 10) < 0.000001)
        }
        #expect(notifications == 0)
        #expect(publishedPositions.count == path.count, "sync still receives every data update")
        #expect(library.mutationRevision == revisionBeforeReading + UInt64(path.count))
        #expect(!library.replaceBooksFromSync([book], expectedMutationRevision: revisionBeforeReading),
                "an old sync snapshot must not overwrite silent progress updates")
        // The same flush used by saveProgress must beat an older pending save.
        await coordinator.navigator.flush()
        let latest = CoreTextReadingPosition(spineIndex: 2, charOffset: 20)
        #expect(await positions.load(for: book.id.uuidString) == latest)
        var resolved: CoreTextReadingPosition?
        coordinator.synchronizeLibraryProgress(to: library, bookId: book.id, forceSave: true) { position in
            resolved = position
            return (Double(position.spineIndex) + Double(position.charOffset) / 1000) / 10
        }
        #expect(resolved == latest)
        #expect(notifications == 1)
        let reopenedLibrary = BookStore(metadataFileURL: metadata)
        #expect(abs((reopenedLibrary.readingBook(id: book.id)?.currentPosition ?? 0) - 0.202) < 0.000001)
        let reopened = makeCoordinator(book.id.uuidString, positions: positions)
        #expect(reopened.restoreSync().coreTextPosition == latest)
    }

    @Test func silentProgressUsesNormalPersistenceAndOrdinaryChangesStillPublish() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = folder.appendingPathComponent("books.json")
        let library = BookStore(metadataFileURL: metadata)
        let a = ReadingBook(title: "A", author: "Test", contentFilename: "a.epub")
        let b = ReadingBook(title: "B", author: "Test", contentFilename: "b.epub")
        library.books = [a, b]
        var notifications = 0
        let token = library.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        for (id, progress) in [(a.id, 0.5), (b.id, 0.7), (a.id, 0.2)] {
            library.updatePosition(bookId: id, position: progress, forceSave: true, notifyLibraryViews: false)
            #expect(BookStore(metadataFileURL: metadata).readingBook(id: id)?.currentPosition == progress,
                    "disk persistence must not depend on publishing library UI")
        }
        #expect(notifications == 0)
        #expect(library.readingBook(id: b.id)?.currentPosition == 0.7)
        library.updatePosition(bookId: a.id, position: 0.2, forceSave: true)
        #expect(notifications == 1, "lifecycle publication works even if position is unchanged")
        library.books = [a]
        #expect(notifications == 2, "ordinary library mutations retain observation")
    }

    @Test func realSwiftUIProgressObservationDoesNotRebuildTheLibraryRoot() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var rootCounts: [Bool: Int] = [:]
        for localProgress in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let library = BookStore(metadataFileURL: folder.appendingPathComponent("books.json"))
            let book = ReadingBook(title: "SwiftUI fixture", author: "Test", contentFilename: "test.epub")
            library.books = [book]
            let coordinator = makeCoordinator(book.id.uuidString, positions: PositionStore())
            let probe = ProgressProbe()
            let host = UIHostingController(rootView: ProgressRoot(
                library: library, session: coordinator.navigator.sessionStore, probe: probe))
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let baseline = probe.rootBodies
            let start = SourcePerfTrace.now
            for step in 1...20 {
                coordinator.send(.scrollCommit(position: .init(spineIndex: 2, charOffset: step * 17)))
                library.updatePosition(bookId: book.id, position: Double(step) / 1000,
                                       notifyLibraryViews: !localProgress)
                // Process the queued observation delivery; no timer or fixed delay.
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                CATransaction.flush()
            }
            rootCounts[localProgress] = probe.rootBodies - baseline
            #expect(probe.lastOffset == 340, "the isolated overlay must display the latest position")
            #expect(library.readingBook(id: book.id)?.currentPosition == 0.02)
            SourcePerfTrace.record("test.scroll.progressPublication",
                "local=\(localProgress) commits=20 rootBodies=\(probe.rootBodies - baseline) overlayBodies=\(probe.overlayBodies)",
                since: start, thresholdMs: 0)
            print("[ScrollProgress] local=\(localProgress) rootBodies=\(probe.rootBodies - baseline) overlayBodies=\(probe.overlayBodies) elapsedMs=\((SourcePerfTrace.now - start) * 1000)")
        }
        #expect(try #require(rootCounts[false]) >= 20)
        #expect(rootCounts[true] == 0)
    }

    @Test func identicalSessionValuesDoNotPublishAndChangesStillDo() {
        let coordinator = makeCoordinator("session-dedup", positions: PositionStore())
        let session = coordinator.navigator.sessionStore
        let initial = session.state
        var count = 0
        let token = session.objectWillChange.sink { count += 1 }
        defer { token.cancel() }
        session.move(to: initial.location)
        session.updateAppearance(initial.appearance)
        session.updateViewport(initial.viewportSize)
        session.updateDirection(initial.direction)
        session.updateSpreadMode(initial.spreadMode)
        session.switchPagingStyle(initial.pagingStyle)
        #expect(count == 0)
        var appearance = initial.appearance
        appearance.fontSize += 1
        session.updateAppearance(appearance)
        session.updateViewport(CGSize(width: 333, height: 777))
        session.move(to: .init(spineIndex: 1, charOffset: 45))
        #expect(count == 3)
        #expect(session.state.appearance == appearance)
    }

    @Test func statisticsStayCurrentWithoutInvalidatingTheirSwiftUIOwner() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let statistics = ReaderReadingStatistics()
        statistics.tracker = ReadingStatsSessionTracker(bookId: "statistics", bookTitle: "Book",
            startPosition: .spine(0, characterOffset: 0))
        let coordinator = makeCoordinator("statistics", positions: PositionStore())
        let probe = ProgressProbe()
        let host = UIHostingController(rootView: StatisticsRoot(statistics: statistics,
            session: coordinator.navigator.sessionStore, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let baseline = probe.rootBodies
        for index in 1...20 {
            statistics.tracker?.updateVisiblePosition(.spine(0, characterOffset: index * 10))
            coordinator.send(.scrollCommit(position: .init(spineIndex: 0, charOffset: index * 10)))
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        #expect(probe.rootBodies == baseline)
        #expect(probe.lastOffset == 200, "the session-driven bar must read the latest statistics")
        #expect(statistics.tracker?.finish()?.charactersRead == 200)
        print("[ScrollStatistics] commits=20 rootBodies=\(probe.rootBodies - baseline) barBodies=\(probe.overlayBodies) characters=\(probe.lastOffset)")
    }

    private func makeCoordinator(_ id: String, positions: PositionStore) -> ReaderSessionCoordinator {
        ReaderSessionCoordinator(navigator: ReaderNavigator(initialState: ReaderPresentationState(
            location: .chapterStart(0), direction: .ltr, spreadMode: .singlePage,
            viewportSize: CGSize(width: 392, height: 810),
            appearance: ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
                lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
                footerHeight: 20, writingMode: .horizontal), pagingStyle: .slide),
            positionStore: positions, bookId: id))
    }
}

@MainActor private final class ProgressProbe {
    var rootBodies = 0
    var overlayBodies = 0
    var lastOffset = -1
}

@MainActor private struct ProgressRoot: View {
    @ObservedObject var library: BookStore
    let session: ReaderSessionStore
    let probe: ProgressProbe
    var body: some View {
        let _ = { probe.rootBodies += 1 }()
        VStack {
            Text(library.books.first?.title ?? "")
            ReaderSessionProgressView(session: session) { location in
                let _ = { probe.overlayBodies += 1; probe.lastOffset = location.charOffset }()
                Text("\(location.charOffset)")
            }
        }
    }
}

private final class PositionStore: ReadingPositionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CoreTextReadingPosition] = [:]
    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        lock.withLock { values[bookId] = position }
    }
    func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
    func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { values[bookId] } }
    func flush(for bookId: String) async {}
}

@MainActor private struct StatisticsRoot: View {
    @State var statistics: ReaderReadingStatistics
    let session: ReaderSessionStore
    let probe: ProgressProbe
    var body: some View {
        let _ = { probe.rootBodies += 1 }()
        ReaderSessionProgressView(session: session) { _ in
            let value = statistics.tracker?.currentMetrics().charactersRead ?? -1
            let _ = { probe.overlayBodies += 1; probe.lastOffset = value }()
            Text("\(value)")
        }
    }
}

@MainActor private final class ChapterProbe {
    var rootBodies = 0
    var overlayBodies = 0
    var rootChapter = -1
    var displayedChapter = -1
    var displayedOffset = -1
    var displayedFailedChapter = false
    var chapterEffects = 0
}

@MainActor private final class ChapterRootRefresh: ObservableObject {
    @Published var value = 0
}

@MainActor private struct ChapterObservationRoot: View {
    @StateObject var chapters: ReaderChapterPresentationState
    let session: ReaderSessionStore
    @ObservedObject var refresh: ChapterRootRefresh
    let probe: ChapterProbe
    var body: some View {
        let _ = { probe.rootBodies += 1; probe.rootChapter = chapters.currentChapter }()
        VStack {
            Text("\(refresh.value):\(chapters.currentChapter)")
            ReaderSessionProgressView(session: session) { location in
                let _ = {
                    probe.overlayBodies += 1
                    probe.displayedChapter = chapters.currentChapter
                    probe.displayedOffset = location.charOffset
                    probe.displayedFailedChapter = chapters.currentChapter == 2
                }()
                Text("\(chapters.currentChapter):\(location.charOffset)")
            }
        }
        .onChange(of: chapters.currentChangeRevision) { _, _ in
            _ = chapters.consumeCurrentChapterChange()
        }
        .onChange(of: chapters.visibleChangeRevision) { _, _ in
            if chapters.consumeVisibleChapterChange() { probe.chapterEffects += 1 }
        }
    }
}
