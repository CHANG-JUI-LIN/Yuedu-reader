import Foundation
import SwiftUI

extension Notification.Name {
    static let onlineChapterCacheDidUpdate = Notification.Name("onlineChapterCacheDidUpdate")
}

enum OnlineChapterLoadState: String {
    case missing
    case loading
    case cached
    case failed
}

enum OnlineChapterCacheWritePolicy {
    static func shouldReusePersistedRenderArtifacts(
        package: ChapterPackage,
        hasBookSource: Bool
    ) -> Bool {
        hasBookSource && (package.rawHTMLFilename != nil || package.normalizedHTMLFilename != nil)
    }

    static func shouldRefetchStrippedRenderArtifacts(
        package: ChapterPackage,
        hasBookSource: Bool
    ) -> Bool {
        hasBookSource && package.rawHTMLFilename == nil && package.normalizedHTMLFilename != nil
    }

    static func contentFilename(chapterIndex: Int) -> String {
        "\(chapterIndex).txt"
    }
}

enum ChapterFetchPriority: Int {
    case background = 0
    case prefetch = 1
    case immediate = 2
    case jump = 3
    case download = 4

    var taskPriority: TaskPriority {
        switch self {
        case .background: return .background
        case .prefetch: return .utility
        case .immediate: return .userInitiated
        case .jump: return .high
        case .download: return .medium
        }
    }
}

actor ChapterFetchManager {
    // Safe: always first accessed from @MainActor context (AppDependencies.live or @MainActor tests).
    static let shared = ChapterFetchManager(webViewFetcher: MainActor.assumeIsolated { WebViewFetcher.shared })

    private let bookSourceFetcher: BookSourceFetcher
    private let webViewFetcher: WebViewFetcher
    private var tasks: [String: Task<ChapterPackage, Error>] = [:]
    private var states: [String: OnlineChapterLoadState] = [:]
    private var priorities: [String: ChapterFetchPriority] = [:]

    // MARK: - Generation Token
    // Each new fetchChapter call updates the token; results are validated before use
    // to prevent stale generation results from contaminating the UI.
    private var generationTokens: [String: UUID] = [:]

    // MARK: - Failure Count + Quarantine
    // Accumulates per-book chapter fetch failures; books exceeding the threshold
    // are marked as quarantined.
    private var bookFailureCounts: [UUID: Int] = [:]
    private let quarantineThreshold = AppConfig.chapterFetchQuarantineThreshold

    init(
        bookSourceFetcher: BookSourceFetcher = .shared,
        webViewFetcher: WebViewFetcher
    ) {
        self.bookSourceFetcher = bookSourceFetcher
        self.webViewFetcher = webViewFetcher
    }

    private func key(bookId: UUID, chapterIndex: Int) -> String {
        "\(bookId.uuidString)#\(chapterIndex)"
    }

    fileprivate func isTokenValid(taskKey: String, token: UUID) -> Bool {
        generationTokens[taskKey] == token
    }

    /// Determines whether cached chapter content is suspiciously abnormal
    /// (excessively long, or containing multiple chapter titles).
    /// Used to reject bad caches where multiple chapters were merged,
    /// triggering a re-fetch.
    ///
    /// A previous rule that looked for "chapter complete / to be continued"
    /// markers was removed because some sites (e.g. 69shuba) naturally include
    /// those markers multiple times within a single chapter body (as inter-chapter
    /// ads / pagination hints), causing entire books to get stuck as placeholders.
    /// Multi-chapter merges always include multiple chapter title headers, which
    /// the chapterMarkers rule already detects sufficiently.
    // Over this character count, a merge is nearly certain
    private static let suspiciousContentLengthThreshold = 150_000
    // If the content contains this many "Chapter N / Volume N" headings, treat as multi-chapter merge
    private static let suspiciousChapterHeadingThreshold = 3
    private static let chapterHeadingRegex = try! NSRegularExpression(
        pattern: #"第\s*[\d零一二三四五六七八九十百千萬万]+\s*[章回卷節节篇部]"#
    )

    static func isSuspiciousChapterContent(_ content: String) -> Bool {
        // Measure prose only: 段評-heavy chapters embed 100s of KB of legitimate base64 SVG bubbles
        // (a 起点 大热章节 is 260KB+, ~all bubbles). Counting that bulk tripped the merge heuristic →
        // the cache was rejected → endless re-fetch (chapter never rendered). Exclude the payloads.
        let proseLength = ReaderHTMLUtilities.lengthExcludingBase64Payloads(content)
        if proseLength > suspiciousContentLengthThreshold {
            AppLogger.parse("⟐ suspiciousContent length", context: ["len": content.count, "prose": proseLength, "threshold": suspiciousContentLengthThreshold])
            return true
        }
        let range = NSRange(content.startIndex..., in: content)
        let headingCount = chapterHeadingRegex.numberOfMatches(in: content, range: range)
        if headingCount >= suspiciousChapterHeadingThreshold {
            AppLogger.parse("⟐ suspiciousContent headings", context: ["len": content.count, "headingCount": headingCount, "threshold": suspiciousChapterHeadingThreshold])
        }
        return headingCount >= suspiciousChapterHeadingThreshold
    }

    static func isCollapsedBrowserImportedChapterContent(_ content: String) -> Bool {
        ReaderHTMLUtilities.isLikelyCollapsedChapterText(content)
    }

    private func isReusableCachedPackage(_ package: ChapterPackage, for book: ReadingBook) -> Bool {
        guard package.state == .cached, !package.content.isEmpty else { return false }
        if Self.isSuspiciousChapterContent(package.content) { return false }
        if book.bookSourceId == nil, Self.isCollapsedBrowserImportedChapterContent(package.content) {
            return false
        }
        if OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
            package: package,
            hasBookSource: book.bookSourceId != nil
        ) {
            return false
        }
        return true
    }

    func chapterState(bookId: UUID, chapterIndex: Int) -> OnlineChapterLoadState {
        if bookSourceFetcher.isChapterCached(bookId: bookId, chapterIndex: chapterIndex) {
            return .cached
        }
        return states[key(bookId: bookId, chapterIndex: chapterIndex)] ?? .missing
    }

    func isChapterCached(book: ReadingBook, chapterIndex: Int) -> Bool {
        guard let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            return false
        }

        if refs[chapterIndex].shouldRenderAsVolumeSeparator {
            return true
        }

        let sanitizedURL = RuleEngine.sanitizeExtractedURL(refs[chapterIndex].url)
        var shouldClearCachedChapter = false

        if let cached = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: refs[chapterIndex].title
        ), isReusableCachedPackage(cached, for: book) {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return true
        } else if bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: refs[chapterIndex].title
        ) != nil {
            shouldClearCachedChapter = true
        }

        if sanitizedURL != refs[chapterIndex].url,
            let cached = bookSourceFetcher.loadChapterPackageSync(
                bookId: book.id,
                chapterIndex: chapterIndex,
                expectedSourceURL: refs[chapterIndex].url,
                expectedTOCTitle: refs[chapterIndex].title
            ), isReusableCachedPackage(cached, for: book)
        {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return true
        } else if sanitizedURL != refs[chapterIndex].url,
                  bookSourceFetcher.loadChapterPackageSync(
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: refs[chapterIndex].url,
                    expectedTOCTitle: refs[chapterIndex].title
                  ) != nil {
            shouldClearCachedChapter = true
        }

        if shouldClearCachedChapter {
            bookSourceFetcher.clearChapterCache(bookId: book.id, chapterIndex: chapterIndex)
        }

        return false
    }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        guard let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            throw NSError(
                domain: "OnlineReadingPipeline", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "找不到章節"])
        }

        // Clean up HTML fragment URLs that may remain from old caches (e.g. <a href="...">Chapter 1</a>)
        var ref = refs[chapterIndex]
        let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)
        ref.url = sanitizedURL

        if ref.hasVolumeSeparatorTitle || ref.isVolume {
            AppLogger.parse("⟐ chapterFetch gate", context: [
                "index": chapterIndex,
                "title": ref.title,
                "isVolume": ref.isVolume,
                "volumeTitle": ref.hasVolumeSeparatorTitle,
                "shouldSkip": ref.shouldRenderAsVolumeSeparator,
                "urlLen": sanitizedURL.count,
                "urlHead": String(sanitizedURL.prefix(120))
            ])
        }
        if ref.shouldRenderAsVolumeSeparator {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            throw FetchError.volumeSeparator(ref.title)
        }

        var shouldClearCachedChapter = false

        if let cached = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ), isReusableCachedPackage(cached, for: book)
        {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return cached
        } else if bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ) != nil {
            shouldClearCachedChapter = true
        }
        // Also accept caches stored under the original URL (legacy path)
        if sanitizedURL != refs[chapterIndex].url,
           let cached = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: refs[chapterIndex].url,
            expectedTOCTitle: ref.title
        ), isReusableCachedPackage(cached, for: book)
        {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return cached
        } else if sanitizedURL != refs[chapterIndex].url,
                  bookSourceFetcher.loadChapterPackageSync(
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: refs[chapterIndex].url,
                    expectedTOCTitle: ref.title
                  ) != nil {
            shouldClearCachedChapter = true
        }

        if shouldClearCachedChapter {
            bookSourceFetcher.clearChapterCache(bookId: book.id, chapterIndex: chapterIndex)
        }

        let taskKey = key(bookId: book.id, chapterIndex: chapterIndex)

        // If an in-flight request already exists for this chapter, share its result.
        // Do not refresh the generation token here, or the in-flight task's result
        // would be treated as a stale generation.
        if let existing = tasks[taskKey] {
            if let existingPriority = priorities[taskKey],
                priority == .jump,
                existingPriority.rawValue < priority.rawValue
            {
                existing.cancel()
                tasks.removeValue(forKey: taskKey)
                priorities.removeValue(forKey: taskKey)
                generationTokens.removeValue(forKey: taskKey)
                states[taskKey] = .missing
            } else {
                let result = try await existing.value
                return result
            }
        }

        // Only generate a token when creating a new task, as the unique valid
        // generation for this fetch result.
        let myToken = UUID()
        generationTokens[taskKey] = myToken

        // High-priority preemption: on a jump, cancel other in-flight fetches for
        // the same book to free WKWebView slots.
        if priority == .jump {
            let prefix = "\(book.id.uuidString)#"
            for (otherKey, otherTask) in tasks where otherKey != taskKey && otherKey.hasPrefix(prefix) {
                otherTask.cancel()
                tasks.removeValue(forKey: otherKey)
                generationTokens.removeValue(forKey: otherKey)
                states[otherKey] = .missing
            }
        }

        states[taskKey] = .loading
        if let bookRuntime = book.runtimeVariables, !bookRuntime.isEmpty {
            var mergedRuntime = bookRuntime
            if let chapterRuntime = ref.runtimeVariables {
                for (key, value) in chapterRuntime {
                    mergedRuntime[key] = value
                }
            }
            ref.runtimeVariables = mergedRuntime
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let bookId = book.id
        ReaderTelemetry.shared.log(
            "chapter_fetch_start",
            attributes: [
                "bookId": book.id.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "pipelineKind": book.isOnline ? "online" : "txt",
                "priority": "\(priority.rawValue)",
            ]
        )

        let task = Task(priority: priority.taskPriority) { () throws -> ChapterPackage in
            if let sourceId = book.bookSourceId {
                guard
                    let source = await MainActor.run(body: {
                        BookSourceStore.shared.sources.first(where: { $0.id == sourceId })
                    })
                else {
                    throw NSError(
                        domain: "OnlineReadingPipeline", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "找不到書源"])
                }
                return try await bookSourceFetcher.fetchChapterPackage(
                    ref: ref,
                    bookId: book.id,
                    source: source,
                    chapterReferer: book.tocURL ?? book.bookInfoURL ?? book.source
                )
            }

            let bsf = bookSourceFetcher
            let capturedStore = store
            let selfRef = self
            let content: String
            do {
                content = try await fetchBrowserImportedChapter(
                    urlString: ref.url,
                    referer: book.bookInfoURL ?? book.source,
                    progressHandler: { @MainActor partial in
                        Task {
                            guard await selfRef.isTokenValid(taskKey: taskKey, token: myToken) else { return }
                            do {
                                let filename = try bsf.saveToCache(
                                    content: partial,
                                    bookId: bookId,
                                    chapterIndex: chapterIndex,
                                    sourceURL: ref.url,
                                    tocTitle: ref.title,
                                    storeNormalizedHTML: false
                                )
                                await MainActor.run {
                                    capturedStore?.updateCachedChapter(
                                        bookId: bookId,
                                        chapterIndex: chapterIndex,
                                        filename: filename
                                    )
                                    NotificationCenter.default.post(
                                        name: .onlineChapterCacheDidUpdate,
                                        object: nil,
                                        userInfo: ["bookId": bookId, "chapterIndex": chapterIndex]
                                    )
                                }
                            } catch {
                                AppLogger.error("Progressive chapter cache write failed", error: error)
                            }
                        }
                    }
                )
            } catch {
                bookSourceFetcher.clearChapterCache(
                    bookId: book.id,
                    chapterIndex: chapterIndex
                )
                throw error
            }
            if !content.isEmpty {
                _ = try bookSourceFetcher.saveToCache(
                    content: content,
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    sourceURL: ref.url,
                    tocTitle: ref.title,
                    storeNormalizedHTML: false
                )
                guard let persistedPackage = bookSourceFetcher.loadChapterPackageSync(
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: ref.url,
                    expectedTOCTitle: ref.title
                ) else {
                    throw ChapterCacheWriteError.verificationFailed
                }
                return persistedPackage
            }
            throw FetchError.emptyContent
        }

        tasks[taskKey] = task
        priorities[taskKey] = priority

        do {
            let package = try await task.value

            // Generation token validation: ensure this result is still from the latest request
            guard generationTokens[taskKey] == myToken else {
                throw CancellationError()  // Stale generation result, silently discard
            }

            if package.state == .cached && !package.content.isEmpty {
                let filename: String
                if OnlineChapterCacheWritePolicy.shouldReusePersistedRenderArtifacts(
                    package: package,
                    hasBookSource: book.bookSourceId != nil
                ) {
                    // BookSourceFetcher already persisted raw/normalized render artifacts.
                    // Re-saving from plain text here would strip HTML-only inline markers
                    // such as paragraph-review badges.
                    filename = OnlineChapterCacheWritePolicy.contentFilename(chapterIndex: chapterIndex)
                } else {
                    filename = try bookSourceFetcher.saveToCache(
                        content: package.content,
                        bookId: book.id,
                        chapterIndex: chapterIndex,
                        sourceURL: ref.url,
                        tocTitle: ref.title,
                        storeNormalizedHTML: book.bookSourceId != nil
                    )
                }
                await MainActor.run {
                    store?.updateCachedChapter(
                        bookId: book.id, chapterIndex: chapterIndex, filename: filename)
                }
                states[taskKey] = .cached
                // Success: reset failure counter
                bookFailureCounts[bookId] = 0
                ReaderTelemetry.shared.log(
                    "chapter_fetch_end",
                    attributes: [
                        "bookId": book.id.uuidString,
                        "chapterIndex": "\(chapterIndex)",
                        "pipelineKind": book.isOnline ? "online" : "txt",
                        "durationMs": "\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms",
                        "result": "success",
                    ]
                )
            } else {
                states[taskKey] = .failed
                await handleFetchFailure(
                    bookId: bookId, chapterIndex: chapterIndex, sourceURL: ref.url, tocTitle: ref.title, store: store, startedAt: startedAt,
                    reason: "empty", pipelineKind: book.isOnline ? "online" : "txt")
            }
            clearRequestTracking(for: taskKey, token: myToken)
            return package
        } catch is CancellationError {
            // Generation token invalidated or task cancelled: clean up without recording failure
            clearRequestTracking(for: taskKey, token: myToken)
            throw CancellationError()
        } catch {
            guard generationTokens[taskKey] == myToken else {
                throw CancellationError()
            }
            states[taskKey] = .failed
            clearRequestTracking(for: taskKey, token: myToken)
            await handleFetchFailure(
                bookId: bookId, chapterIndex: chapterIndex, sourceURL: ref.url, tocTitle: ref.title, store: store, startedAt: startedAt,
                reason: "error", pipelineKind: book.isOnline ? "online" : "txt")
            throw error
        }
    }

    func prefetchChapters(
        book: ReadingBook, indices: [Int], priority: ChapterFetchPriority, store: BookStore?
    ) {
        for idx in indices {
            let state = chapterState(bookId: book.id, chapterIndex: idx)
            guard state == .missing || state == .failed else { continue }
            Task(priority: priority.taskPriority) {
                _ = try? await fetchChapter(
                    book: book, chapterIndex: idx, priority: priority, store: store)
            }
        }
    }

    func cancelAll(for bookId: UUID) {
        let prefix = "\(bookId.uuidString)#"
        for (taskKey, task) in tasks where taskKey.hasPrefix(prefix) {
            task.cancel()
            tasks.removeValue(forKey: taskKey)
            priorities.removeValue(forKey: taskKey)
            states[taskKey] = .missing
        }
        generationTokens = generationTokens.filter { !$0.key.hasPrefix(prefix) }
    }

    func cancelFetch(bookId: UUID, chapterIndex: Int) {
        let taskKey = key(bookId: bookId, chapterIndex: chapterIndex)
        tasks[taskKey]?.cancel()
        tasks.removeValue(forKey: taskKey)
        priorities.removeValue(forKey: taskKey)
        generationTokens.removeValue(forKey: taskKey)
        states[taskKey] = .missing
    }

    /// Cancels low-priority tasks (background/prefetch) while preserving immediate/jump tasks.
    /// Used when the user jumps to a page: clears background prefetches, then runs the target
    /// chapter at maximum priority.
    func cancelLowPriority(for bookId: UUID, keepPriority: ChapterFetchPriority = .immediate) {
        let prefix = "\(bookId.uuidString)#"
        let keysToCancel = tasks.keys.filter { key in
            guard key.hasPrefix(prefix),
                Int(key.split(separator: "#").last ?? "") != nil
            else { return false }
            guard let priority = priorities[key] else { return false }
            return priority.rawValue < keepPriority.rawValue
        }
        for key in keysToCancel {
            tasks[key]?.cancel()
            tasks.removeValue(forKey: key)
            priorities.removeValue(forKey: key)
            states[key] = .missing
        }
    }

    // MARK: - Failure Handling + Quarantine Trigger

    private func handleFetchFailure(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String?,
        tocTitle: String?,
        store: BookStore?,
        startedAt: CFAbsoluteTime,
        reason: String,
        pipelineKind: String
    ) async {
        bookSourceFetcher.saveFailureMarker(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            reason: reason
        )

        let failCount = (bookFailureCounts[bookId] ?? 0) + 1
        bookFailureCounts[bookId] = failCount

        ReaderTelemetry.shared.log(
            "chapter_fetch_end",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "pipelineKind": pipelineKind,
                "durationMs": "\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms",
                "result": reason,
                "bookFailCount": "\(failCount)",
            ]
        )

        // Exceeds quarantine threshold: auto-mark the entire book
        if failCount >= quarantineThreshold {
            ReaderTelemetry.shared.log(
                "book_quarantined",
                attributes: [
                    "bookId": bookId.uuidString,
                    "failCount": "\(failCount)",
                ]
            )
            await MainActor.run {
                store?.setCompatibilityState(bookId: bookId, state: .quarantined)
            }
        }
    }

    private func clearRequestTracking(for taskKey: String, token: UUID) {
        guard generationTokens[taskKey] == token else { return }
        tasks.removeValue(forKey: taskKey)
        priorities.removeValue(forKey: taskKey)
        generationTokens.removeValue(forKey: taskKey)
    }

    @MainActor
    private func fetchBrowserImportedChapter(
        urlString: String,
        referer: String?,
        progressHandler: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        var directFailure: Error?
        do {
            let direct = try await bookSourceFetcher.fetchWebContent(
                url: urlString,
                referer: referer,
                onFirstPageReady: { partial in
                    Task { @MainActor in
                        progressHandler?(partial)
                    }
                }
            )
            if !direct.isEmpty { return direct }
        } catch {
            directFailure = error
        }

        // Browser-imported pages sometimes require JavaScript rendering. Enter
        // this fallback only when the primary fetch threw or returned no body.
        guard let firstURL = URL(string: urlString) else {
            throw directFailure ?? FetchError.invalidURL(urlString)
        }
        let headers = referer.map { ["Referer": $0] } ?? [:]
        var allContent = ""
        var currentURL: URL? = firstURL
        var visited = Set<String>()
        let maxSubPages = 10

        while let url = currentURL, visited.count < maxSubPages {
            let urlStr = url.absoluteString
            if visited.contains(urlStr) { break }
            visited.insert(urlStr)

            do {
                let result = try await webViewFetcher.fetchContentWithNextPage(
                    url: url,
                    headers: headers,
                    timeout: AppConfig.webViewFetchTimeout,
                    jsWait: 1.5
                )
                if !result.content.isEmpty {
                    let cleaned = BookSourceFetcher.cleanChapterContent(result.content)
                    if !allContent.isEmpty { allContent += "\n" }
                    allContent += cleaned
                    // First page obtained: notify reader immediately, don't wait for subsequent pages
                    if visited.count == 1 {
                        progressHandler?(allContent)
                    }
                }
                if let next = result.nextPageURL {
                    guard let nextURL = URL(string: next) else {
                        throw FetchError.invalidURL(next)
                    }
                    currentURL = nextURL
                } else {
                    currentURL = nil
                }
            } catch let err as FetchError {
                if case .cloudflareChallengeRequired(let urlStr) = err,
                    let challengeURL = URL(string: urlStr)
                {
                    // If the user cancels the CF challenge, give up immediately (avoid loop)
                    do {
                        _ = try await CloudflareChallengePresenter.present(url: challengeURL)
                    } catch {
                        throw error
                    }
                    do {
                        let result = try await webViewFetcher.fetchContentWithNextPage(
                            url: url,
                            headers: headers,
                            timeout: AppConfig.webViewFetchTimeout,
                            jsWait: 1.5
                        )
                        if !result.content.isEmpty {
                            let cleaned = BookSourceFetcher.cleanChapterContent(result.content)
                            if !allContent.isEmpty { allContent += "\n" }
                            allContent += cleaned
                            if visited.count == 1 { progressHandler?(allContent) }
                        }
                        if let next = result.nextPageURL {
                            guard let nextURL = URL(string: next) else {
                                throw FetchError.invalidURL(next)
                            }
                            currentURL = nextURL
                        } else {
                            currentURL = nil
                        }
                    } catch {
                        throw error
                    }
                } else {
                    throw err
                }
            } catch {
                throw error
            }
        }
        if currentURL != nil {
            throw NSError(
                domain: "OnlineReadingPipeline",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Browser chapter exceeded the 10-page safety limit"]
            )
        }
        guard !allContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw directFailure ?? FetchError.emptyContent
        }
        return allContent
    }
}

final class OnlineBookCoordinator {
    // MARK: - Injectable Dependencies (defaults to shared singletons, supports test substitution)

    let bookSourceFetcher: BookSourceFetcher
    let chapterFetchManager: ChapterFetchManager
    let webViewFetcher: WebViewFetcher

    init(
        bookSourceFetcher: BookSourceFetcher,
        chapterFetchManager: ChapterFetchManager,
        webViewFetcher: WebViewFetcher
    ) {
        self.bookSourceFetcher = bookSourceFetcher
        self.chapterFetchManager = chapterFetchManager
        self.webViewFetcher = webViewFetcher
    }

    private static let chapterPlaceholderBody = "載入章節中…"

    /// Per-book stable basePath. Avoids regenerating a new UUID directory on each
    /// buildPackage call, which would cause reloadWithUpdatedPackage to detect a
    /// basePath change and trigger a full reload.
    private var stableBasePaths: [UUID: URL] = [:]

    /// Returns or creates a stable basePath for a book.
    private func stableBasePath(for bookId: UUID) -> URL {
        if let existing = stableBasePaths[bookId] {
            return existing
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("online_xhtml_\(bookId.uuidString)")
        stableBasePaths[bookId] = path
        return path
    }

    private static func placeholderHTML(title: String, body: String) -> String {
        ReaderHTMLUtilities.normalizedChapterHTML(
            title: title,
            paragraphs: [body]
        )
    }

    private static func makePlaceholderPackage(for book: ReadingBook) throws -> BookPackage {
        let displayBookTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: book.title)
        let title = displayBookTitle.isEmpty ? "網頁書籍" : displayBookTitle
        let converted = try XHTMLBookBuilder.convert(
            xhtmlChapters: [
                XHTMLBookBuilder.XHTMLChapterInput(
                    title: title,
                    html: placeholderHTML(title: title, body: chapterPlaceholderBody),
                    href: "chapter_0.xhtml"
                )
            ],
            title: title,
            basePathPrefix: "online_xhtml"
        )
        return XHTMLBookBuilder.package(
            from: converted,
            title: title,
            author: book.author,
            pipelineKind: .html,
            originalSourceURL: book.bookInfoURL.flatMap(URL.init(string:))
        )
    }

    /// Converts all book chapters to XHTML format.
    /// O(N) operation (traverses all chapters). Only used for **offline download**
    /// reading. Online reading uses CoreTextPageEngine's incremental loading
    /// mechanism and does not go through this method.
    private func buildConvertedBook(
        for book: ReadingBook,
        refs: [OnlineChapterRef],
        reuseBasePath: URL? = nil
    ) throws -> XHTMLBookBuilder.ConvertedBook {
        let bsf = bookSourceFetcher
        let xhtmlChapters = refs.enumerated().map { idx, ref in
            let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)
            // Try the cleaned URL first, then the original URL (legacy cache compat)
            var chapterPackage = bsf.loadChapterPackageSync(
                bookId: book.id,
                chapterIndex: ref.index,
                expectedSourceURL: sanitizedURL,
                expectedTOCTitle: ref.title
            )
            if chapterPackage == nil && sanitizedURL != ref.url {
                chapterPackage = bsf.loadChapterPackageSync(
                    bookId: book.id,
                    chapterIndex: ref.index,
                    expectedSourceURL: ref.url,
                    expectedTOCTitle: ref.title
                )
            }
            let hasLooseCache = bsf.isChapterCached(
                bookId: book.id,
                chapterIndex: ref.index
            )
            let displayTitle = Self.resolvedDisplayTitle(
                tocTitle: ref.title,
                artifactTitle: chapterPackage?.canonicalTitle
            )
            let html: String
            if let chapterPackage, chapterPackage.state == .cached, !chapterPackage.content.isEmpty {
                let contentMatches = Self.validateContentMatchesTOCTitle(
                    content: chapterPackage.content,
                    tocTitle: ref.title,
                    chapterIndex: ref.index,
                    bookId: book.id
                )
                if !contentMatches {
                    ReaderTelemetry.shared.log(
                        "chapter_title_mismatch_softened",
                        attributes: [
                            "bookId": book.id.uuidString,
                            "chapterIndex": "\(ref.index)",
                            "tocTitle": String(ref.title.prefix(60)),
                        ]
                    )
                }
                html =
                    bsf.loadNormalizedChapterHTMLSync(
                        bookId: book.id,
                        chapterIndex: ref.index,
                        expectedSourceURL: ref.url,
                        expectedTOCTitle: ref.title
                    )
                    ?? ChapterFetcher.shared.buildNormalizedHTML(
                        title: displayTitle,
                        content: chapterPackage.content
                    )
            } else if hasLooseCache {
                bsf.clearChapterCache(
                    bookId: book.id,
                    chapterIndex: ref.index
                )
                html = Self.placeholderHTML(
                    title: displayTitle,
                    body: Self.chapterPlaceholderBody
                )
            } else if let chapterPackage, chapterPackage.state == .failed {
                html = Self.placeholderHTML(
                    title: displayTitle,
                    body: Self.failurePlaceholder(for: displayTitle, reason: chapterPackage.failureReason)
                )
            } else {
                html = Self.placeholderHTML(
                    title: displayTitle,
                    body: Self.chapterPlaceholderBody
                )
            }
            return XHTMLBookBuilder.XHTMLChapterInput(
                title: displayTitle,
                html: html,
                href: "chapter_\(idx).xhtml"
            )
        }

        return try XHTMLBookBuilder.convert(
            xhtmlChapters: xhtmlChapters,
            title: book.title,
            basePathPrefix: "online_xhtml",
            reuseBasePath: reuseBasePath
        )
    }

    func buildInitialPackage(for book: ReadingBook) throws -> BookPackage {
        try buildPackage(for: book)
    }

    /// Builds a complete BookPackage for offline reading. Only called from the download flow.
    /// Online reading uses OnlineProviderAttributedStringBuilder + CoreTextPageEngine and
    /// does not go through this method.
    func buildPackage(for book: ReadingBook, preferredChapter: Int? = nil) throws -> BookPackage {
        guard let refs = book.onlineChapters, !refs.isEmpty else {
            return try Self.makePlaceholderPackage(for: book)
        }

        let focus = preferredChapter ?? 0
        let reusePath = stableBasePath(for: book.id)
        let converted = try buildConvertedBook(for: book, refs: refs, reuseBasePath: reusePath)
        let package = XHTMLBookBuilder.package(
            from: converted,
            title: book.title,
            author: book.author,
            pipelineKind: .html,
            originalSourceURL: book.bookInfoURL.flatMap(URL.init(string:))
        )

        ReaderTelemetry.shared.log(
            "progressive_package_update",
            attributes: [
                "bookId": book.id.uuidString,
                "pipelineKind": package.pipelineKind.rawValue,
                "focusChapter": "\(focus)",
                "cachedChapterCount":
                    "\(refs.filter { bookSourceFetcher.isChapterCached(bookId: book.id, chapterIndex: $0.index, expectedSourceURL: $0.url, expectedTOCTitle: $0.title) }.count)",
            ]
        )
        return package
    }

    /// Warms the download-flow chapter window. Only called from the download flow.
    func warmCurrentWindow(
        for book: ReadingBook,
        chapterIndex: Int,
        store: BookStore?
    ) async -> BookPackage? {
        do {
            let pkg = try await chapterFetchManager.fetchChapter(
                book: book,
                chapterIndex: chapterIndex,
                priority: .immediate,
                store: store
            )
            // Only return the package when fetchChapter actually obtained real content
            guard pkg.state == .cached, !pkg.content.isEmpty else {
                return nil
            }
            await prefetchAround(book: book, center: chapterIndex, store: store)
            return try buildPackage(for: book, preferredChapter: chapterIndex)
        } catch {
            return nil
        }
    }

    /// Jumps to a specific chapter and builds a BookPackage. Only for download/offline jump flow.
    func fetchJumpTarget(
        for book: ReadingBook,
        chapterIndex: Int,
        store: BookStore?
    ) async -> BookPackage? {
        await chapterFetchManager.cancelAll(for: book.id)
        ReaderTelemetry.shared.log(
            "jump_prefetch_promoted",
            attributes: [
                "bookId": book.id.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "pipelineKind": "online",
            ]
        )
        do {
            let pkg = try await chapterFetchManager.fetchChapter(
                book: book,
                chapterIndex: chapterIndex,
                priority: .jump,
                store: store
            )
            guard pkg.state == .cached, !pkg.content.isEmpty else {
                return nil
            }
            await prefetchAround(book: book, center: chapterIndex, store: store)
            return try buildPackage(for: book, preferredChapter: chapterIndex)
        } catch {
            return nil
        }
    }

    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {
        guard let refs = book.onlineChapters, !refs.isEmpty else { return }
        let last = refs.count - 1

        // Forward priority: N+1, N+2 use prefetch (user is far more likely to read forward)
        let forwardIndices = [center + 1, center + 2]
            .filter { $0 >= 0 && $0 <= last }
        // Backward fallback: N-1, N-2 use background (preserve back-navigation)
        let backwardIndices = [center - 1, center - 2]
            .filter { $0 >= 0 && $0 <= last }

        if !forwardIndices.isEmpty {
            await chapterFetchManager.prefetchChapters(
                book: book, indices: forwardIndices, priority: .prefetch, store: store)
        }
        if !backwardIndices.isEmpty {
            await chapterFetchManager.prefetchChapters(
                book: book, indices: backwardIndices, priority: .background, store: store)
        }
    }

    func chapterState(bookId: UUID, chapterIndex: Int) async -> OnlineChapterLoadState {
        await chapterFetchManager.chapterState(bookId: bookId, chapterIndex: chapterIndex)
    }

    // MARK: - Sanity Checks

    /// Chapter heading regex: matches "Chapter N / Part N / Volume N / Section N / Part N"
    /// (supports Chinese numerals + Arabic numerals).
    private static let chapterHeadingRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^第\s*[\d零一二三四五六七八九十百千萬万]+\s*[章回卷節节篇部]"#,
            options: .anchorsMatchLines
        )
    }()

    private static func failurePlaceholder(for title: String, reason: String?) -> String {
        let suffix: String
        if let reason, !reason.isEmpty {
            suffix = "章節載入失敗（\(reason)）\n請下拉刷新或重新進入本章。"
        } else {
            suffix = "章節載入失敗\n請下拉刷新或重新進入本章。"
        }
        return "\(title)\n\n\(suffix)"
    }

    private static func resolvedDisplayTitle(tocTitle: String, artifactTitle: String?) -> String {
        let cleanedTOC = ReaderHTMLUtilities.displayText(fromHTMLFragment: tocTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let artifactTitle = artifactTitle.map({
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }), !artifactTitle.isEmpty else {
            return cleanedTOC
        }

        let normalizedTOC =
            cleanedTOC.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let normalizedArtifact =
            artifactTitle.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()

        if normalizedTOC.isEmpty
            || (normalizedTOC != normalizedArtifact
                && !normalizedTOC.contains(normalizedArtifact)
                && !normalizedArtifact.contains(normalizedTOC))
        {
            return artifactTitle
        }
        return cleanedTOC
    }

    /// Validates that cached chapter content matches the TOC title.
    /// If the first line looks like a different chapter title, logs a warning.
    private static func validateContentMatchesTOCTitle(
        content: String, tocTitle: String,
        chapterIndex: Int, bookId: UUID
    ) -> Bool {
        let firstLine: String? =
            content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let firstLine, !firstLine.isEmpty else { return true }
        let trimmedFirst = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only check when the first line looks like a chapter title (short line + matches format)
        guard trimmedFirst.count < 60 else { return true }
        let nsRange = NSRange(trimmedFirst.startIndex..., in: trimmedFirst)
        let looksLikeChapterTitle =
            chapterHeadingRegex?.firstMatch(in: trimmedFirst, range: nsRange) != nil

        guard looksLikeChapterTitle else { return true }

        let normFirst =
            trimmedFirst
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let normTOC =
            tocTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()

        if !normFirst.isEmpty && !normTOC.isEmpty
            && !normFirst.contains(normTOC) && !normTOC.contains(normFirst)
        {
            ReaderTelemetry.shared.log(
                "chapter_title_mismatch",
                attributes: [
                    "bookId": bookId.uuidString,
                    "chapterIndex": "\(chapterIndex)",
                    "tocTitle": String(tocTitle.prefix(60)),
                    "contentFirstLine": String(trimmedFirst.prefix(60)),
                ]
            )
            return false
        }
        return true
    }
}

// MARK: - OnlineBookCoordinating Protocol Conformance
// downloadBook(_:store:) and prefetchAround(book:center:store:) match the protocol
// signature exactly; this extension only declares conformance.

extension OnlineBookCoordinator: OnlineBookCoordinating {}
