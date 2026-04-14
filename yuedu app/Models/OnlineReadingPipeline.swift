import Foundation
import SwiftUI

enum OnlineChapterLoadState: String {
    case missing
    case loading
    case cached
    case failed
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
    static let shared = ChapterFetchManager()

    private let bookSourceFetcher: BookSourceFetcher
    private let webViewFetcher: WebViewFetcher
    private var tasks: [String: Task<ChapterPackage, Error>] = [:]
    private var states: [String: OnlineChapterLoadState] = [:]

    // MARK: - Generation Token（防止舊世代 fetch 結果汙染新 UI）
    // 每次新的 fetchChapter 呼叫都會更新 token；回傳前先確認 token 仍有效
    private var generationTokens: [String: UUID] = [:]

    // MARK: - 失敗計數 + Quarantine 觸發
    // 累積同一本書的章節取得失敗次數，超過門檻後標記為 quarantined
    private var bookFailureCounts: [UUID: Int] = [:]
    private let quarantineThreshold = AppConfig.chapterFetchQuarantineThreshold

    init(
        bookSourceFetcher: BookSourceFetcher = .shared,
        webViewFetcher: WebViewFetcher = .shared
    ) {
        self.bookSourceFetcher = bookSourceFetcher
        self.webViewFetcher = webViewFetcher
    }

    private func key(bookId: UUID, chapterIndex: Int) -> String {
        "\(bookId.uuidString)#\(chapterIndex)"
    }

    func chapterState(bookId: UUID, chapterIndex: Int) -> OnlineChapterLoadState {
        if bookSourceFetcher.isChapterCached(bookId: bookId, chapterIndex: chapterIndex) {
            return .cached
        }
        return states[key(bookId: bookId, chapterIndex: chapterIndex)] ?? .missing
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

        // 清理舊快取可能殘留的 HTML 片段 URL（如 <a href="...">第1章</a>）
        let sanitizedURL = DefaultWebNovelParserService.shared.sanitizeExtractedURL(refs[chapterIndex].url)

        if let cached = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: refs[chapterIndex].title
        ), cached.state == .cached, !cached.content.isEmpty {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return cached
        }
        // 若使用原始 URL 有快取（舊版存入的），也接受
        if sanitizedURL != refs[chapterIndex].url,
           let cached = bookSourceFetcher.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: refs[chapterIndex].url,
            expectedTOCTitle: refs[chapterIndex].title
        ), cached.state == .cached, !cached.content.isEmpty {
            states[key(bookId: book.id, chapterIndex: chapterIndex)] = .cached
            return cached
        }

        let taskKey = key(bookId: book.id, chapterIndex: chapterIndex)

        // 若已有相同章節的請求正在執行，直接共用該結果。
        // 不要在這裡刷新 generation token，否則會把 in-flight task 的合法結果判成舊世代。
        if let existing = tasks[taskKey] {
            let result = try await existing.value
            return result
        }

        // 只有建立新 task 時才生成 token，作為這次抓取結果的唯一有效世代。
        let myToken = UUID()
        generationTokens[taskKey] = myToken

        states[taskKey] = .loading
        var ref = refs[chapterIndex]
        // 將清理過的 URL 寫回 ref，確保下游所有程式碼使用乾淨的 URL
        ref.url = sanitizedURL
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

            let content = await fetchBrowserImportedChapter(
                urlString: ref.url,
                referer: book.bookInfoURL ?? book.source
            )
            if !content.isEmpty {
                _ = bookSourceFetcher.saveToCache(
                    content: content,
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    sourceURL: ref.url,
                    tocTitle: ref.title
                )
                return bookSourceFetcher.loadChapterPackageSync(
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: ref.url,
                    expectedTOCTitle: ref.title
                ) ?? ChapterPackage(
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    sourceURL: ref.url,
                    tocTitle: ref.title,
                    canonicalTitle: ref.title,
                    content: content,
                    contentChecksum: "",
                    rawHTMLFilename: nil,
                    normalizedHTMLFilename: nil,
                    savedAt: Date(),
                    state: .cached,
                    failureReason: nil
                )
            }
            return ChapterPackage(
                bookId: book.id,
                chapterIndex: chapterIndex,
                sourceURL: ref.url,
                tocTitle: ref.title,
                canonicalTitle: ref.title,
                content: "",
                contentChecksum: "",
                rawHTMLFilename: nil,
                normalizedHTMLFilename: nil,
                savedAt: Date(),
                state: .failed,
                failureReason: "empty"
            )
        }

        tasks[taskKey] = task

        do {
            let package = try await task.value

            // Generation Token 驗證：確保此結果仍屬於最新的請求
            guard generationTokens[taskKey] == myToken else {
                if tasks[taskKey] != nil {
                    tasks.removeValue(forKey: taskKey)
                }
                throw CancellationError()  // 舊世代結果，靜默丟棄
            }

            if package.state == .cached && !package.content.isEmpty {
                let filename = bookSourceFetcher.saveToCache(
                    content: package.content,
                    bookId: book.id,
                    chapterIndex: chapterIndex,
                    sourceURL: ref.url,
                    tocTitle: ref.title
                )
                await MainActor.run {
                    store?.updateCachedChapter(
                        bookId: book.id, chapterIndex: chapterIndex, filename: filename)
                }
                states[taskKey] = .cached
                // 成功：重置失敗計數
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
            tasks.removeValue(forKey: taskKey)
            if generationTokens[taskKey] == myToken {
                generationTokens.removeValue(forKey: taskKey)
            }
            return package
        } catch is CancellationError {
            // Generation token 失效或 Task 被取消：清理不記失敗
            tasks.removeValue(forKey: taskKey)
            if generationTokens[taskKey] == myToken {
                generationTokens.removeValue(forKey: taskKey)
            }
            throw CancellationError()
        } catch {
            states[taskKey] = .failed
            tasks.removeValue(forKey: taskKey)
            if generationTokens[taskKey] == myToken {
                generationTokens.removeValue(forKey: taskKey)
            }
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
        }
        generationTokens = generationTokens.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 取消低優先任務（background/prefetch），保留 immediate/jump 任務。
    /// 用於使用者跳頁時：先清除背景預取，再以最高優先搶先執行目標章節。
    func cancelLowPriority(for bookId: UUID, keepPriority: ChapterFetchPriority = .immediate) {
        let prefix = "\(bookId.uuidString)#"
        let keysToCancel = tasks.keys.filter { key in
            guard key.hasPrefix(prefix),
                Int(key.split(separator: "#").last ?? "") != nil
            else { return false }
            // 移除所有「非高優先」的任務（不影響已在跑的 immediate/jump）
            let state = states[key]
            return state == .loading  // 僅取消仍在 loading 的
        }
        for key in keysToCancel {
            tasks[key]?.cancel()
            tasks.removeValue(forKey: key)
        }
    }

    // MARK: - 內部：失敗處理 + Quarantine 觸發
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

        // 累積失敗計數
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

        // 超過 quarantine 門檻：自動標記整本書
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

    @MainActor
    private func fetchBrowserImportedChapter(urlString: String, referer: String?) async
        -> String
    {
        if let direct = try? await bookSourceFetcher.fetchWebContent(
            url: urlString,
            referer: referer
        ), !direct.isEmpty {
            return direct
        }

        guard let firstURL = URL(string: urlString) else { return "" }
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
                }
                if let next = result.nextPageURL, let nextURL = URL(string: next) {
                    currentURL = nextURL
                } else {
                    currentURL = nil
                }
            } catch {
                break
            }
        }
        return allContent
    }
}

actor BookDownloadManager {
    static let shared = BookDownloadManager()

    private let chapterFetchManager: ChapterFetchManager

    init(chapterFetchManager: ChapterFetchManager = .shared) {
        self.chapterFetchManager = chapterFetchManager
    }

    func downloadBook(book: ReadingBook, store: BookStore?) async {
        guard let refs = book.onlineChapters, !refs.isEmpty else { return }
        await MainActor.run {
            store?.setOfflineDownloadState(
                bookId: book.id, state: .downloading, downloadedChapterCount: 0)
        }
        ReaderTelemetry.shared.log(
            "book_download_start",
            attributes: [
                "bookId": book.id.uuidString,
                "chapterCount": "\(refs.count)",
                "pipelineKind": "online",
            ]
        )

        var completed = 0
        for idx in refs.indices {
            do {
                _ = try await chapterFetchManager.fetchChapter(
                    book: book,
                    chapterIndex: idx,
                    priority: .download,
                    store: store
                )
                completed += 1
                let completedNow = completed
                await MainActor.run {
                    store?.setOfflineDownloadState(
                        bookId: book.id, state: .downloading, downloadedChapterCount: completedNow)
                }
                ReaderTelemetry.shared.log(
                    "book_download_progress",
                    attributes: [
                        "bookId": book.id.uuidString,
                        "chapterIndex": "\(idx)",
                        "completed": "\(completedNow)",
                    ]
                )
            } catch {
                let completedNow = completed
                await MainActor.run {
                    store?.setOfflineDownloadState(
                        bookId: book.id, state: .failed, downloadedChapterCount: completedNow)
                }
                ReaderTelemetry.shared.log(
                    "book_download_end",
                    attributes: [
                        "bookId": book.id.uuidString,
                        "completed": "\(completedNow)",
                        "result": "failed",
                    ]
                )
                return
            }
        }

        let completedNow = completed
        await MainActor.run {
            store?.setOfflineDownloadState(
                bookId: book.id, state: .available, downloadedChapterCount: completedNow)
        }
        ReaderTelemetry.shared.log(
            "book_download_end",
            attributes: [
                "bookId": book.id.uuidString,
                "completed": "\(completedNow)",
                "result": "success",
            ]
        )
    }
}

final class OnlineBookCoordinator {
    static let shared = OnlineBookCoordinator()

    // MARK: - 可注入依賴（默認使用 shared 單例，支援測試替換）
    let bookSourceFetcher: BookSourceFetcher
    let chapterFetchManager: ChapterFetchManager
    let webViewFetcher: WebViewFetcher

    init(
        bookSourceFetcher: BookSourceFetcher = BookSourceFetcher.shared,
        chapterFetchManager: ChapterFetchManager = ChapterFetchManager.shared,
        webViewFetcher: WebViewFetcher = WebViewFetcher.shared
    ) {
        self.bookSourceFetcher = bookSourceFetcher
        self.chapterFetchManager = chapterFetchManager
        self.webViewFetcher = webViewFetcher
    }

    private static let chapterPlaceholderBody = "載入章節中…"

    /// 每本書的穩定 basePath（避免每次 buildPackage 都產生新 UUID 目錄，
    /// 導致 reloadWithUpdatedPackage 檢測到 basePath 不同而觸發完整重載）
    private var stableBasePaths: [UUID: URL] = [:]

    /// 取得或建立一本書的穩定 basePath
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
        let title = book.title.isEmpty ? "網頁書籍" : book.title
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

    private func buildConvertedBook(
        for book: ReadingBook,
        refs: [OnlineChapterRef],
        reuseBasePath: URL? = nil
    ) throws -> XHTMLBookBuilder.ConvertedBook {
        let bsf = bookSourceFetcher
        let xhtmlChapters = refs.enumerated().map { idx, ref in
            let sanitizedURL = DefaultWebNovelParserService.shared.sanitizeExtractedURL(ref.url)
            // 嘗試用清理後的 URL 查找快取，若找不到再嘗試原始 URL（相容舊版快取）
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
            // 只有當 fetchChapter 成功取得真實內容時才回傳 package
            guard pkg.state == .cached, !pkg.content.isEmpty else {
                return nil
            }
            await prefetchAround(book: book, center: chapterIndex, store: store)
            return try buildPackage(for: book, preferredChapter: chapterIndex)
        } catch {
            return nil
        }
    }

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
        let range = (max(0, center - 2)...min(refs.count - 1, center + 2)).filter { $0 != center }
        await chapterFetchManager.prefetchChapters(
            book: book,
            indices: Array(range),
            priority: .prefetch,
            store: store
        )
    }

    func chapterState(bookId: UUID, chapterIndex: Int) async -> OnlineChapterLoadState {
        await chapterFetchManager.chapterState(bookId: bookId, chapterIndex: chapterIndex)
    }

    func downloadBook(_ book: ReadingBook, store: BookStore?) {
        Task {
            await BookDownloadManager.shared.downloadBook(book: book, store: store)
        }
    }

    // MARK: - 健全性檢查

    /// 章節標題正則：匹配「第N章/回/卷/節/篇/部」（支援中文數字 + 阿拉伯數字）
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
        let cleanedTOC = tocTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let artifactTitle = artifactTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !artifactTitle.isEmpty
        else {
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

    /// 驗證快取的章節內容與 TOC 標題是否匹配。
    /// 若內容首行看起來是另一個章節的標題（與 TOC 不同），記錄警告。
    private static func validateContentMatchesTOCTitle(
        content: String, tocTitle: String,
        chapterIndex: Int, bookId: UUID
    ) -> Bool {
        // 取內容首個非空行
        let firstLine: String? =
            content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let firstLine, !firstLine.isEmpty else { return true }
        let trimmedFirst = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // 只有當首行本身看起來像章節標題時才做檢查（短行 + 匹配章節格式）
        guard trimmedFirst.count < 60 else { return true }
        let nsRange = NSRange(trimmedFirst.startIndex..., in: trimmedFirst)
        let looksLikeChapterTitle =
            chapterHeadingRegex?.firstMatch(in: trimmedFirst, range: nsRange) != nil

        guard looksLikeChapterTitle else { return true }

        // 正規化比較：去空白 + 小寫
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
            // 內容的章節標題與 TOC 不一致 → 可能是內容錯位
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
