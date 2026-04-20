# Known TOC Jump Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make any chapter whose URL already exists in `book.onlineChapters` enter a deterministic loading / retry flow when jumped to, without white pages or multi-source state guessing.

**Architecture:** Introduce small pure reader-presentation helpers for overlay and refresh decisions, then move chapter fetch-process state into `ReaderViewModel`. `ReaderView` becomes a navigation-and-rendering shell: it jumps immediately, asks the view model to ensure the target chapter is ready, and refreshes only the current chapter when the state becomes `.ready`. To preserve the `.jump` contract, extend the fetch protocol with per-chapter cancellation so an in-flight lower-priority request can be restarted as `.jump`.

**Tech Stack:** SwiftUI, Swift Testing, UIKit/CoreText reader engine, `ChapterFetchManager`, `NotificationCenter`

---

## File structure

- `yuedu app/Models/Reader/ChapterLoadState.swift`  
  Shared fetch-process enum used by `ReaderViewModel` and presentation helpers.
- `yuedu app/Models/Reader/ReaderChapterPresentation.swift`  
  Pure helper functions for overlay state and current-chapter refresh decisions.
- `yuedu app/ViewModels/ReaderViewModel.swift`  
  Single source of truth for `chapterStates`, retry, dedupe, and `.jump` promotion.
- `yuedu app/Models/App/AppDependencies.swift`  
  Protocol surface for per-chapter cancellation.
- `yuedu app/Models/Online/OnlineReadingPipeline.swift`  
  `ChapterFetchManager` implementation for per-chapter cancellation.
- `yuedu app/Views/Reader/ReaderView.swift`  
  Remove local loading/error sets, route every jump through `ReaderViewModel`, and consume presentation helpers.
- `yuedu appTests/ReaderChapterPresentationTests.swift`  
  Unit tests for overlay and refresh rules.
- `yuedu appTests/ReaderViewModelChapterStateTests.swift`  
  Unit tests for fetch state transitions, dedupe, retry, and `.jump` promotion.

## Task 1: Add explicit reader presentation models

**Files:**
- Create: `yuedu app/Models/Reader/ChapterLoadState.swift`
- Create: `yuedu app/Models/Reader/ReaderChapterPresentation.swift`
- Test: `yuedu appTests/ReaderChapterPresentationTests.swift`

- [ ] **Step 1: Write the failing presentation tests**

```swift
import Testing
@testable import yuedu_app

struct ReaderChapterPresentationTests {

    @Test("cached content suppresses loading and failure overlays")
    func contentAvailabilityWins() {
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: true,
                loadState: .idle
            ) == .hidden
        )
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: true,
                loadState: .failed(reason: "timeout")
            ) == .hidden
        )
    }

    @Test("missing content shows loading for idle and loading states")
    func missingContentShowsLoading() {
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: false,
                loadState: .idle
            ) == .loading
        )
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: false,
                loadState: .loading
            ) == .loading
        )
    }

    @Test("missing content shows retry overlay for failures")
    func missingContentShowsFailure() {
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: false,
                loadState: .failed(reason: "503")
            ) == .failed(message: "503")
        )
    }

    @Test("ready on the current chapter refreshes only the visible chapter")
    func refreshActionIsScopedToCurrentChapter() {
        #expect(
            ReaderChapterPresentation.refreshAction(
                changedChapterIndex: 9,
                currentChapterIndex: 9,
                usesCoreText: true,
                newState: .ready,
                isContentAvailable: true
            ) == .notifyChapterDataChanged(9)
        )

        #expect(
            ReaderChapterPresentation.refreshAction(
                changedChapterIndex: 9,
                currentChapterIndex: 9,
                usesCoreText: false,
                newState: .ready,
                isContentAvailable: true
            ) == .rebuildPages
        )

        #expect(
            ReaderChapterPresentation.refreshAction(
                changedChapterIndex: 9,
                currentChapterIndex: 7,
                usesCoreText: true,
                newState: .ready,
                isContentAvailable: true
            ) == .none
        )
    }
}
```

- [ ] **Step 2: Run the focused test target and confirm it fails**

Run:

```bash
xcodebuild test -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'platform=iOS Simulator,id=57CA92D6-AA6A-4357-BF41-8EC14974DC93' -only-testing:'yuedu appTests/ReaderChapterPresentationTests'
```

Expected: compile failure because `ChapterLoadState`, `ReaderChapterPresentation`, and the overlay / refresh enums do not exist yet.

- [ ] **Step 3: Add the minimal presentation types**

`yuedu app/Models/Reader/ChapterLoadState.swift`

```swift
import Foundation

enum ChapterLoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(reason: String)
}
```

`yuedu app/Models/Reader/ReaderChapterPresentation.swift`

```swift
import Foundation

enum ReaderChapterOverlayState: Equatable {
    case hidden
    case loading
    case failed(message: String)
}

enum ReaderChapterRefreshAction: Equatable {
    case none
    case notifyChapterDataChanged(Int)
    case rebuildPages
}

enum ReaderChapterPresentation {
    static func overlayState(
        isContentAvailable: Bool,
        loadState: ChapterLoadState?
    ) -> ReaderChapterOverlayState {
        guard !isContentAvailable else { return .hidden }

        switch loadState ?? .idle {
        case .idle, .loading, .ready:
            return .loading
        case .failed(let reason):
            return .failed(message: reason)
        }
    }

    static func refreshAction(
        changedChapterIndex: Int,
        currentChapterIndex: Int,
        usesCoreText: Bool,
        newState: ChapterLoadState?,
        isContentAvailable: Bool
    ) -> ReaderChapterRefreshAction {
        guard changedChapterIndex == currentChapterIndex else { return .none }
        guard newState == .ready, isContentAvailable else { return .none }
        return usesCoreText ? .notifyChapterDataChanged(changedChapterIndex) : .rebuildPages
    }
}
```

- [ ] **Step 4: Run the tests again**

Run:

```bash
xcodebuild test -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'platform=iOS Simulator,id=57CA92D6-AA6A-4357-BF41-8EC14974DC93' -only-testing:'yuedu appTests/ReaderChapterPresentationTests'
```

Expected: PASS for all `ReaderChapterPresentationTests`.

- [ ] **Step 5: Commit**

```bash
git add 'yuedu app/Models/Reader/ChapterLoadState.swift' 'yuedu app/Models/Reader/ReaderChapterPresentation.swift' 'yuedu appTests/ReaderChapterPresentationTests.swift'
git commit -m "feat: add reader chapter presentation state"
```

## Task 2: Move fetch-process state into `ReaderViewModel`

**Files:**
- Modify: `yuedu app/Models/App/AppDependencies.swift:63-72,164-183`
- Modify: `yuedu app/Models/Online/OnlineReadingPipeline.swift:73-117,255-320,337-362`
- Modify: `yuedu app/ViewModels/ReaderViewModel.swift:1-70`
- Test: `yuedu appTests/ReaderViewModelChapterStateTests.swift`

- [ ] **Step 1: Write the failing view-model tests**

```swift
import Foundation
import Testing
@testable import yuedu_app

@Suite("ReaderViewModel chapter states")
struct ReaderViewModelChapterStateTests {

    private actor FetchGate {
        private var continuation: CheckedContinuation<ChapterPackage, Error>?

        func wait() async throws -> ChapterPackage {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func succeed(with package: ChapterPackage) {
            continuation?.resume(returning: package)
            continuation = nil
        }

        func fail(with error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private final class SpyChapterFetcher: ChapterFetching {
        let gate = FetchGate()
        var requestedPriorities: [ChapterFetchPriority] = []
        var cancelledRequests: [(UUID, Int)] = []

        func fetchChapter(
            book: ReadingBook,
            chapterIndex: Int,
            priority: ChapterFetchPriority,
            store: BookStore?
        ) async throws -> ChapterPackage {
            requestedPriorities.append(priority)
            return try await gate.wait()
        }

        func cancel(bookId: UUID, chapterIndex: Int) async {
            cancelledRequests.append((bookId, chapterIndex))
        }

        func cancelAll(for bookId: UUID) async {}
    }

    private final class StubBookSourceFetcher: BookSourceFetching {
        var cachedPackages: [Int: ChapterPackage] = [:]

        func fetchBookInfoPackage(url: String, source: BookSource, runtimeVariables: [String : String]?) async throws -> BookInfoPackage {
            throw NSError(domain: "StubBookSourceFetcher", code: 1)
        }

        func fetchTOCPackage(
            tocUrl: String,
            source: BookSource,
            runtimeVariables: [String : String]?,
            onFirstPageReady: (([OnlineChapterRef]) -> Void)?
        ) async throws -> TOCPackage {
            throw NSError(domain: "StubBookSourceFetcher", code: 2)
        }

        func isChapterCached(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> Bool {
            cachedPackages[chapterIndex] != nil
        }

        func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
        func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }

        func loadChapterPackageSync(
            bookId: UUID,
            chapterIndex: Int,
            expectedSourceURL: String?,
            expectedTOCTitle: String?
        ) -> ChapterPackage? {
            cachedPackages[chapterIndex]
        }
    }

    private func makeBook() -> ReadingBook {
        var book = ReadingBook(title: "線上書", author: "作者", source: "https://example.com", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "第一章", url: "https://example.com/1"),
            OnlineChapterRef(index: 1, title: "第二章", url: "https://example.com/2")
        ]
        return book
    }

    private func package(bookId: UUID, chapterIndex: Int, state: ChapterPackageState = .cached, content: String = "正文") -> ChapterPackage {
        ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: "https://example.com/\(chapterIndex + 1)",
            tocTitle: "第\(chapterIndex + 1)章",
            canonicalTitle: "第\(chapterIndex + 1)章",
            content: content,
            contentChecksum: "checksum",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: state,
            failureReason: state == .failed ? "empty" : nil
        )
    }

    @Test("idle to loading to ready")
    @MainActor
    func transitionsToReady() async throws {
        let viewModel = ReaderViewModel()
        let fetcher = SpyChapterFetcher()
        let cache = StubBookSourceFetcher()
        let store = BookStore()
        let book = makeBook()

        viewModel.ensureChapterReady(
            book: book,
            chapterIndex: 0,
            priority: .jump,
            store: store,
            chapterFetcher: fetcher,
            bookSourceFetcher: cache
        )

        #expect(viewModel.chapterStates[0] == .loading)

        await fetcher.gate.succeed(with: package(bookId: book.id, chapterIndex: 0))
        await Task.yield()

        #expect(viewModel.chapterStates[0] == .ready)
    }

    @Test("idle to loading to failed and retry re-enters loading")
    @MainActor
    func failureCanRetry() async throws {
        let viewModel = ReaderViewModel()
        let fetcher = SpyChapterFetcher()
        let cache = StubBookSourceFetcher()
        let store = BookStore()
        let book = makeBook()

        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)
        await fetcher.gate.fail(with: NSError(domain: "ReaderViewModelTests", code: 503, userInfo: [
            NSLocalizedDescriptionKey: "503"
        ]))
        await Task.yield()
        #expect(viewModel.chapterStates[0] == .failed(reason: "503"))

        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)
        #expect(viewModel.chapterStates[0] == .loading)
    }

    @Test("duplicate requests do not start a second fetch")
    @MainActor
    func dedupesInflightRequests() {
        let viewModel = ReaderViewModel()
        let fetcher = SpyChapterFetcher()
        let cache = StubBookSourceFetcher()
        let store = BookStore()
        let book = makeBook()

        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)
        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)

        #expect(fetcher.requestedPriorities == [.immediate])
    }

    @Test("jump cancels an in-flight lower-priority fetch and restarts it")
    @MainActor
    func jumpPromotesInflightImmediateRequest() async {
        let viewModel = ReaderViewModel()
        let fetcher = SpyChapterFetcher()
        let cache = StubBookSourceFetcher()
        let store = BookStore()
        let book = makeBook()

        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)
        viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: store, chapterFetcher: fetcher, bookSourceFetcher: cache)
        await Task.yield()

        #expect(fetcher.cancelledRequests.count == 1)
        #expect(fetcher.requestedPriorities == [.immediate, .jump])
        #expect(viewModel.chapterStates[0] == .loading)
    }
}
```

- [ ] **Step 2: Run the focused view-model tests and confirm they fail**

Run:

```bash
xcodebuild test -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'platform=iOS Simulator,id=57CA92D6-AA6A-4357-BF41-8EC14974DC93' -only-testing:'yuedu appTests/ReaderViewModelChapterStateTests'
```

Expected: compile failure because `ReaderViewModel()` has no parameterless initializer, `chapterStates` is missing, `ensureChapterReady` is missing, and `ChapterFetching` does not support per-chapter cancellation yet.

- [ ] **Step 3: Implement the state machine and per-chapter cancellation**

`yuedu app/Models/App/AppDependencies.swift`

```swift
protocol ChapterFetching {
    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage

    func cancel(bookId: UUID, chapterIndex: Int) async
    func cancelAll(for bookId: UUID) async
}

struct LiveChapterFetcher: ChapterFetching {
    let chapterFetchManager: ChapterFetchManager

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        try await chapterFetchManager.fetchChapter(
            book: book,
            chapterIndex: chapterIndex,
            priority: priority,
            store: store
        )
    }

    func cancel(bookId: UUID, chapterIndex: Int) async {
        await chapterFetchManager.cancel(bookId: bookId, chapterIndex: chapterIndex)
    }

    func cancelAll(for bookId: UUID) async {
        await chapterFetchManager.cancelAll(for: bookId)
    }
}
```

`yuedu app/Models/Online/OnlineReadingPipeline.swift`

```swift
func cancel(bookId: UUID, chapterIndex: Int) {
    let taskKey = key(bookId: bookId, chapterIndex: chapterIndex)
    tasks[taskKey]?.cancel()
    tasks.removeValue(forKey: taskKey)
    generationTokens.removeValue(forKey: taskKey)
    states[taskKey] = .missing
}
```

`yuedu app/ViewModels/ReaderViewModel.swift`

```swift
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapterStates: [Int: ChapterLoadState] = [:]

    private var inFlightPriorities: [Int: ChapterFetchPriority] = [:]
    private var requestTokens: [Int: UUID] = [:]

    func resetChapterState(for chapterIndex: Int) {
        chapterStates[chapterIndex] = .idle
    }

    func ensureChapterReady(
        book: ReadingBook?,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore,
        chapterFetcher: ChapterFetching,
        bookSourceFetcher: BookSourceFetching
    ) {
        guard let book, let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else { return }

        if hasReadableContent(book: book, chapterIndex: chapterIndex, bookSourceFetcher: bookSourceFetcher) {
            chapterStates[chapterIndex] = .ready
            return
        }

        let currentPriority = inFlightPriorities[chapterIndex]
        if chapterStates[chapterIndex] == .loading,
           let currentPriority,
           priority.rawValue > currentPriority.rawValue {
            let token = UUID()
            requestTokens[chapterIndex] = token
            inFlightPriorities[chapterIndex] = priority
            chapterStates[chapterIndex] = .loading

            Task {
                await chapterFetcher.cancel(bookId: book.id, chapterIndex: chapterIndex)
                await runFetch(
                    book: book,
                    chapterIndex: chapterIndex,
                    priority: priority,
                    store: store,
                    chapterFetcher: chapterFetcher,
                    token: token
                )
            }
            return
        }

        if chapterStates[chapterIndex] == .loading {
            return
        }

        let token = UUID()
        requestTokens[chapterIndex] = token
        inFlightPriorities[chapterIndex] = priority
        chapterStates[chapterIndex] = .loading

        Task {
            await runFetch(
                book: book,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store,
                chapterFetcher: chapterFetcher,
                token: token
            )
        }
    }

    private func hasReadableContent(
        book: ReadingBook,
        chapterIndex: Int,
        bookSourceFetcher: BookSourceFetching
    ) -> Bool {
        guard let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else { return false }
        let ref = refs[chapterIndex]
        guard let package = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ) else { return false }
        return package.state == .cached && !package.content.isEmpty
    }

    private func runFetch(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore,
        chapterFetcher: ChapterFetching,
        token: UUID
    ) async {
        do {
            let package = try await chapterFetcher.fetchChapter(
                book: book,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store
            )
            guard requestTokens[chapterIndex] == token else { return }
            inFlightPriorities[chapterIndex] = nil
            chapterStates[chapterIndex] =
                package.state == .cached && !package.content.isEmpty
                ? .ready
                : .failed(reason: package.failureReason ?? "內容為空")
        } catch is CancellationError {
            guard requestTokens[chapterIndex] == token else { return }
            inFlightPriorities[chapterIndex] = nil
        } catch {
            guard requestTokens[chapterIndex] == token else { return }
            inFlightPriorities[chapterIndex] = nil
            chapterStates[chapterIndex] = .failed(reason: error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run the focused view-model tests again**

Run:

```bash
xcodebuild test -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'platform=iOS Simulator,id=57CA92D6-AA6A-4357-BF41-8EC14974DC93' -only-testing:'yuedu appTests/ReaderViewModelChapterStateTests'
```

Expected: PASS for the new `ReaderViewModelChapterStateTests`.

- [ ] **Step 5: Commit**

```bash
git add 'yuedu app/Models/App/AppDependencies.swift' 'yuedu app/Models/Online/OnlineReadingPipeline.swift' 'yuedu app/ViewModels/ReaderViewModel.swift' 'yuedu appTests/ReaderViewModelChapterStateTests.swift'
git commit -m "feat: centralize reader chapter loading state"
```

## Task 3: Wire `ReaderView` to the new state model

**Files:**
- Modify: `yuedu app/Views/Reader/ReaderView.swift:113-115,475-489,622-636,669,814,849,869,1028,1473-1493,1580-1588,1659-1729,1902-1911`
- Reuse tests: `yuedu appTests/ReaderChapterPresentationTests.swift`, `yuedu appTests/ReaderViewModelChapterStateTests.swift`
- Regression tests: `yuedu appTests/ReaderPageTransitionQueueTests.swift`, `yuedu appTests/ProgrammaticPageTransitionPerformerTests.swift`

- [ ] **Step 1: Replace the local fetch state with a view model instance**

In `ReaderView.swift`, remove the three local `@State` properties and add a dedicated view model:

```swift
@StateObject private var readerViewModel = ReaderViewModel()

private var currentChapterLoadState: ChapterLoadState {
    readerViewModel.chapterStates[currentChapterIndex] ?? .idle
}
```

Also remove these properties:

```swift
@State private var fetchingChapters: Set<Int> = []
@State private var failedChapters: Set<Int> = []
@State private var lastChapterError: String = ""
```

- [ ] **Step 2: Add the current-chapter availability and overlay computation**

```swift
private func hasReadableContent(at chapterIndex: Int) -> Bool {
    guard let b = book, let refs = b.onlineChapters, refs.indices.contains(chapterIndex) else { return false }
    let ref = refs[chapterIndex]
    guard let package = dependencies.bookSourceFetcher.loadChapterPackageSync(
        bookId: b.id,
        chapterIndex: chapterIndex,
        expectedSourceURL: ref.url,
        expectedTOCTitle: ref.title
    ) else { return false }
    return package.state == .cached && !package.content.isEmpty
}

private var currentOverlayState: ReaderChapterOverlayState {
    ReaderChapterPresentation.overlayState(
        isContentAvailable: hasReadableContent(at: currentChapterIndex),
        loadState: readerViewModel.chapterStates[currentChapterIndex]
    )
}
```

Render the overlay inside the main `ZStack`:

```swift
switch currentOverlayState {
case .hidden:
    EmptyView()
case .loading:
    VStack(spacing: 16) {
        ProgressView()
        Text(settings.t("正在努力抓取正文中..."))
            .font(.system(size: 14, design: .serif))
            .foregroundColor(readerTheme.textColor.opacity(0.6))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(readerTheme.backgroundColor)
case .failed(let message):
    VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 40))
            .foregroundColor(readerTheme.textColor.opacity(0.5))
        Text(settings.t("章節載入失敗"))
            .foregroundColor(readerTheme.textColor)
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(readerTheme.textColor.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
        Button(settings.t("點擊重試")) {
            ensureChapterReady(currentChapterIndex, priority: .jump)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(readerTheme.backgroundColor)
}
```

- [ ] **Step 3: Route every chapter fetch and retry through one helper**

Replace the private `fetchChapterIfNeeded` function with a thin wrapper:

```swift
private func ensureChapterReady(
    _ chapterIndex: Int,
    priority: ChapterFetchPriority = .immediate
) {
    readerViewModel.ensureChapterReady(
        book: book,
        chapterIndex: chapterIndex,
        priority: priority,
        store: store,
        chapterFetcher: dependencies.chapterFetcher,
        bookSourceFetcher: dependencies.bookSourceFetcher
    )
}
```

Update all current call sites:

```swift
fetchChapterIfNeeded(chapterIndex: newChapter)
```

to:

```swift
ensureChapterReady(newChapter)
```

Update `jumpToChapter` so it always switches first, then requests readiness:

```swift
private func jumpToChapter(_ idx: Int, charOffset: Int = 0) {
    guard chapters.indices.contains(idx) else { return }

    currentChapterIndex = idx
    ensureChapterReady(idx, priority: .jump)

    if let engine = epubRenderer.engine, usesCoreTextEPUB {
        Task { @MainActor in
            engine.cancelPendingWork()
            await engine.preloadChapter(at: idx)
            if idx > 0 { Task { await engine.preloadChapter(at: idx - 1) } }
            if idx < chapters.count - 1 { Task { await engine.preloadChapter(at: idx + 1) } }
            let targetPage = engine.pageIndex(forSpine: idx, charOffset: charOffset)
            currentPage = targetPage
            epubRenderer.currentEpubPage = targetPage
        }
    } else if let page = findChapterFirstPage(idx) {
        currentPage = page
    }
}
```

Update `refreshCurrentChapter()`:

```swift
private func refreshCurrentChapter() {
    guard let b = book, !(b.onlineChapters?.isEmpty ?? true) else { return }
    let idx = currentChapterIndex
    dependencies.bookSourceFetcher.clearChapterCache(bookId: b.id, chapterIndex: idx)
    store.clearCachedChapter(bookId: b.id, chapterIndex: idx)
    readerViewModel.resetChapterState(for: idx)
    ensureChapterReady(idx, priority: .jump)
}
```

- [ ] **Step 4: Refresh only the visible chapter when data becomes ready**

Replace the broad cache-update handling with presentation-driven refresh:

```swift
.onReceive(NotificationCenter.default.publisher(for: .onlineChapterCacheDidUpdate)) { notification in
    guard
        let updatedBookId = notification.userInfo?["bookId"] as? UUID,
        updatedBookId == bookId,
        let chapterIndex = notification.userInfo?["chapterIndex"] as? Int
    else {
        return
    }

    let action = ReaderChapterPresentation.refreshAction(
        changedChapterIndex: chapterIndex,
        currentChapterIndex: currentChapterIndex,
        usesCoreText: usesCoreTextEPUB,
        newState: readerViewModel.chapterStates[chapterIndex],
        isContentAvailable: hasReadableContent(at: chapterIndex)
    )

    switch action {
    case .none:
        break
    case .notifyChapterDataChanged(let idx):
        if let engine = epubRenderer.engine {
            Task { await engine.notifyChapterDataChanged(at: idx) }
        }
    case .rebuildPages:
        rebuildPages()
    }
}
```

Add one more direct state observer so late success only refreshes if the user is still on that chapter:

```swift
.onChange(of: readerViewModel.chapterStates[currentChapterIndex]) { newState in
    let action = ReaderChapterPresentation.refreshAction(
        changedChapterIndex: currentChapterIndex,
        currentChapterIndex: currentChapterIndex,
        usesCoreText: usesCoreTextEPUB,
        newState: newState,
        isContentAvailable: hasReadableContent(at: currentChapterIndex)
    )

    switch action {
    case .none:
        break
    case .notifyChapterDataChanged(let idx):
        if let engine = epubRenderer.engine {
            Task { await engine.notifyChapterDataChanged(at: idx) }
        }
    case .rebuildPages:
        rebuildPages()
    }
}
```

- [ ] **Step 5: Run the focused reader regression suite and commit**

Run:

```bash
xcodebuild test -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'platform=iOS Simulator,id=57CA92D6-AA6A-4357-BF41-8EC14974DC93' -only-testing:'yuedu appTests/ReaderChapterPresentationTests' -only-testing:'yuedu appTests/ReaderViewModelChapterStateTests' -only-testing:'yuedu appTests/ReaderPageTransitionQueueTests' -only-testing:'yuedu appTests/ProgrammaticPageTransitionPerformerTests'
```

Expected: PASS for the new presentation and view-model tests, plus the existing paging regressions.

Commit:

```bash
git add 'yuedu app/Views/Reader/ReaderView.swift'
git commit -m "feat: wire reader chapter jump loading state"
```

## Self-review checklist

1. **Spec coverage**
   - Explicit `ChapterLoadState`: Task 1.
   - Single source of truth in `ReaderViewModel`: Task 2.
   - Known-TOC jump always enters loading / retry flow: Task 3.
   - Current-chapter-only refresh and no forced snap-back: Task 1 refresh helper + Task 3 state observation.
   - `.jump` vs lower-priority in-flight work: Task 2 per-chapter cancellation.

2. **Placeholder scan**
   - No `TODO`, `TBD`, or “implement later”.
   - Each task has exact file paths, code snippets, commands, and expected outcomes.

3. **Type consistency**
   - `ChapterLoadState`, `ReaderChapterPresentation`, `ReaderChapterOverlayState`, and `ReaderChapterRefreshAction` use the same names in tests and implementation.
   - `ensureChapterReady` is the only reader-facing fetch entrypoint after Task 3.
