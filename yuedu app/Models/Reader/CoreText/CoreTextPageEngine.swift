import CoreText
import CoreGraphics
import UIKit
import ReadiumShared

struct FontRegistrationResult {
    let familyName: String
    let postScriptName: String
    let tempFileURL: URL?
}

protocol FontRegistrationServicing {
    func registerFont(data: Data, alias: String, existingTempURL: URL?) -> FontRegistrationResult?
    func cleanupTemporaryFile(at url: URL)
}

final class CoreTextFontRegistrationService: FontRegistrationServicing {
    static func cleanupStaleTemporaryFonts(maxAge: TimeInterval = 7 * 24 * 60 * 60) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-maxAge)

        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix("reader-font-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    func registerFont(data: Data, alias: String, existingTempURL: URL?) -> FontRegistrationResult? {
        let tempURL = existingTempURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("reader-font-\(alias)-\(UUID().uuidString)")
                .appendingPathExtension("ttf")

        var writableTempURL: URL? = tempURL

        do {
            try data.write(to: tempURL, options: .atomic)

            var registrationError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(tempURL as CFURL, .process, &registrationError)
            if !registered, let error = registrationError?.takeRetainedValue() {
                print("[CoreTextEngine] registerFont URL register warning: \(error)")
            }

            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(tempURL as CFURL) as? [[CFString: Any]],
               let descriptor = descriptors.first {
                let postScriptName = descriptor[kCTFontNameAttribute] as? String ?? ""
                let familyName = descriptor[kCTFontFamilyNameAttribute] as? String ?? ""
                if !familyName.isEmpty || !postScriptName.isEmpty {
                    return FontRegistrationResult(
                        familyName: familyName.isEmpty ? postScriptName : familyName,
                        postScriptName: postScriptName.isEmpty ? familyName : postScriptName,
                        tempFileURL: tempURL
                    )
                }
            }
        } catch {
            writableTempURL = nil
            print("[CoreTextEngine] registerFont temp write failed: \(error)")
        }

        guard
            let provider = CGDataProvider(data: data as CFData),
            let cgFont = CGFont(provider)
        else {
            print("[CoreTextEngine] registerFont CGFont provider failed header=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
            return nil
        }

        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterGraphicsFont(cgFont, &registrationError)
        if !registered, let error = registrationError?.takeRetainedValue() {
            print("[CoreTextEngine] registerFont graphics warning: \(error)")
        }

        let postScriptName = cgFont.postScriptName as String? ?? ""
        let font = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let familyName = CTFontCopyFamilyName(font) as String
        guard !familyName.isEmpty || !postScriptName.isEmpty else { return nil }

        return FontRegistrationResult(
            familyName: familyName.isEmpty ? postScriptName : familyName,
            postScriptName: postScriptName.isEmpty ? familyName : postScriptName,
            tempFileURL: writableTempURL
        )
    }

    func cleanupTemporaryFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class EmptyBookResourceProvider: BookResourceProvider {
    static let shared = EmptyBookResourceProvider()

    var customScheme: String { "reader-empty" }
    var chapters: [BookResourceChapterDescriptor] { [] }

    func cssResourceHrefs() -> [String] { [] }
    func resourceURL(for href: String) -> URL {
        URL(string: "reader-empty://book/\(href)")!
    }
    func chapterDataSize(at index: Int) async throws -> Int { 0 }
    func chapterIndex(for href: String) -> Int? {
        _ = href
        return nil
    }
    func chapterHTML(at index: Int) async throws -> String {
        _ = index
        throw PublicationSessionError.resourceNotFound("empty")
    }
    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        throw PublicationSessionError.resourceNotFound(requestURL.absoluteString)
    }
}

@MainActor
final class CoreTextPageEngine: PageRenderingProvider {

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0

    private(set) var layouts: [Int: CoreTextPaginator.ChapterLayout] = [:]
    private let chapterSnapshots: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        // 控制快照快取成本：取實體記憶體約 5%，並限制在 64MB~256MB。
        let budget = min(max(physicalMemory / 20, 64 * 1024 * 1024), 256 * 1024 * 1024)
        cache.totalCostLimit = Int(budget)
        // 保留小型 countLimit，避免短時間內寫入過多低成本快照。
        cache.countLimit = 12
        return cache
    }()
    private var spinePageOffsets: [Int] = []
    private(set) var renderSize: CGSize = .zero
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var layoutGeneration: Int = 0

    private let resourceProvider: any BookResourceProvider
    private let attributedBuilder: (any AttributedStringBuilding)?
    private let paginationManager: PaginationManager
    private let fontRegistrationService: any FontRegistrationServicing
    private let styleResolver: EPUBStyleResolver
    let offsetStore: CharOffsetStore

    private var renderSettings: ReaderRenderSettings

    private var currentBookId: String?
    private var pendingRestoreTarget: (spineIndex: Int, charOffset: Int)?
    private var chapterByteScanTask: Task<Void, Never>?
    private var startupBeganUptime: TimeInterval?
    private var didLogProgressFallback = false
    private var didLogProgressByteMode = false
    /// 各章節的原始 Data 大小（bytes），用於全書進度估算
    private var chapterByteSizes: [Int] = []

    private(set) var isRelaying = false

    private var themeTextColor: UIColor = .label
    private var themeBackgroundColor: UIColor = .systemBackground
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?

    deinit {
        chapterByteScanTask?.cancel()
        styleResolver.cleanupFontFiles()
        NotificationCenter.default.removeObserver(self)
    }

    private func subscribeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.chapterSnapshots.removeAllObjects()
            self?.cancelPreloadTasks()
        }
    }

    private func startupElapsedMs() -> String {
        guard let startupBeganUptime else { return "n/a" }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startupBeganUptime) * 1000
        return String(format: "%.1f", elapsedMs)
    }

    private func startupTrace(_ message: String) {
        let line = "[StartupTrace][CoreTextPageEngine][+\(startupElapsedMs())ms] \(message)"
        print(line)
        NSLog("%@", line)
    }

    init(
        resourceProvider: any BookResourceProvider,
        renderSettings: ReaderRenderSettings,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService(),
        paginationManager: PaginationManager? = nil,
        offsetStore: CharOffsetStore
    ) {
        self.resourceProvider = resourceProvider
        self.attributedBuilder = nil
        self.renderSettings = renderSettings
        self.fontRegistrationService = fontRegistrationService
        self.paginationManager = paginationManager ?? PaginationManager()
        self.offsetStore = offsetStore
        self.styleResolver = EPUBStyleResolver(
            resourceProvider: resourceProvider,
            fontRegistrationService: fontRegistrationService
        )
        subscribeMemoryWarning()
    }

    init(
        attributedBuilder: any AttributedStringBuilding,
        renderSettings: ReaderRenderSettings,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService(),
        paginationManager: PaginationManager? = nil,
        offsetStore: CharOffsetStore
    ) {
        self.resourceProvider = EmptyBookResourceProvider.shared
        self.attributedBuilder = attributedBuilder
        self.renderSettings = renderSettings
        self.fontRegistrationService = fontRegistrationService
        self.paginationManager = paginationManager ?? PaginationManager()
        self.offsetStore = offsetStore
        self.styleResolver = EPUBStyleResolver(
            resourceProvider: EmptyBookResourceProvider.shared,
            fontRegistrationService: fontRegistrationService
        )
        subscribeMemoryWarning()
    }

    convenience init(
        session: PublicationSession,
        renderSettings: ReaderRenderSettings,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService(),
        paginationManager: PaginationManager? = nil,
        offsetStore: CharOffsetStore
    ) {
        self.init(
            resourceProvider: ReadiumBookResourceAdapter(session: session),
            renderSettings: renderSettings,
            fontRegistrationService: fontRegistrationService,
            paginationManager: paginationManager,
            offsetStore: offsetStore
        )
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        renderSettings = settings
    }

    private var chapterCount: Int {
        attributedBuilder?.chapterCount ?? resourceProvider.chapters.count
    }

    private func chapterTitle(at index: Int) -> String {
        if let attributedBuilder {
            return attributedBuilder.chapterTitle(at: index)
        }
        guard resourceProvider.chapters.indices.contains(index) else { return "" }
        return resourceProvider.chapters[index].title
    }

    private func chapterSourceHref(at index: Int) -> String {
        if let attributedBuilder {
            return attributedBuilder.chapterSourceHref(at: index) ?? ""
        }
        guard resourceProvider.chapters.indices.contains(index) else { return "" }
        return resourceProvider.chapters[index].href
    }

    private func chapterIndex(for href: String) -> Int? {
        if let attributedBuilder {
            return attributedBuilder.chapterIndex(for: href)
        }
        return resourceProvider.chapterIndex(for: href)
    }

    func start(renderSize: CGSize, bookId: String) async {
        startupBeganUptime = ProcessInfo.processInfo.systemUptime
        self.renderSize = renderSize
        self.currentBookId = bookId
        didLogProgressFallback = false
        didLogProgressByteMode = false
        let totalChapters = chapterCount
        print("[CoreTextEngine] start renderSize=\(renderSize) chapters=\(totalChapters)")
        startupTrace("start bookId=\(bookId) renderSize=\(renderSize) chapters=\(totalChapters)")
        guard totalChapters > 0 else {
            totalPages = 0
            currentPage = 0
            return
        }

        // 1. 背景掃描全書章節 Data 大小（不阻塞開書主流程）
        chapterByteScanTask?.cancel()
        chapterByteSizes = []
        startupTrace("byteScan launch mode=background")
        chapterByteScanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanChapterByteSizes(for: bookId)
        }

        // 2. 讀存檔 → 決定優先載入哪些章節
        let record = offsetStore.load(bookId: bookId)
        let maxSpineIndex = max(0, totalChapters - 1)
        let savedSpine = max(0, min(record?.spineIndex ?? 0, maxSpineIndex))
        if let record {
            print("[ProgressTrace][CoreTextPageEngine] start loadRecord bookId=\(bookId) rawSpine=\(record.spineIndex) clampedSpine=\(savedSpine) charOffset=\(record.charOffset)")
        } else {
            print("[ProgressTrace][CoreTextPageEngine] start loadRecord bookId=\(bookId) none")
        }
        pendingRestoreTarget = record.map { _ in
            (savedSpine, max(0, record?.charOffset ?? 0))
        }

        // 3. 載入存檔鄰域 [n-1, n, n+1]（+ 第 0 章如果不在範圍內）
        var priority = Set<Int>()
        priority.insert(0) // 封面/目錄始終需要
        for i in max(0, savedSpine - 1)...min(savedSpine + 1, totalChapters - 1) {
            priority.insert(i)
        }
        startupTrace("preload priority=\(priority.sorted())")

        await withTaskGroup(of: Void.self) { group in
            for i in priority.sorted() {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }
        startupTrace("preload priority done totalPages=\(totalPages)")
        print("[CoreTextEngine] start done totalPages=\(totalPages)")

        // 4. 恢復位置（存檔章節已載入，不會 fallback 到 0）
        if pendingRestoreTarget != nil {
            applyPendingRestoreIfPossible()
        } else {
            migrateFromLegacyProgressIfNeeded(bookId: bookId)
        }
    }

    private func scanChapterByteSizes(for bookId: String) async {
        startupTrace("byteScan begin bookId=\(bookId) chapters=\(chapterCount) mode=\(attributedBuilder != nil ? "builder" : "resource")")

        // Lazy path: online books skip the full O(N) scan.
        // Sizes are filled incrementally via notifyChapterDataChanged.
        if let attributedBuilder, attributedBuilder.prefersLazyByteScan {
            guard !Task.isCancelled else { return }
            guard currentBookId == bookId else { return }
            chapterByteSizes = [Int](repeating: 0, count: attributedBuilder.chapterCount)
            startupTrace("byteScan lazy chapters=\(attributedBuilder.chapterCount)")
            rebuildPageOffsets()
            onChapterReady?(nil)
            return
        }

        // Fast path: use pre-scanned sizes from SpinesCache (no ZIP I/O)
        if let adapter = resourceProvider as? ReadiumBookResourceAdapter,
           let cached = adapter.cachedChapterByteSizes(),
           cached.count == chapterCount {
            guard !Task.isCancelled else { return }
            guard currentBookId == bookId else { return }
            chapterByteSizes = cached
            let totalBytes = cached.reduce(0, +)
            startupTrace("byteScan cached chapters=\(cached.count) totalBytes=\(totalBytes)")
            rebuildPageOffsets()
            onChapterReady?(nil)
            return
        }

        let sizes: [Int]
        if let attributedBuilder {
            var computed = [Int](repeating: 0, count: attributedBuilder.chapterCount)
            for i in 0..<attributedBuilder.chapterCount {
                if Task.isCancelled { return }
                computed[i] = await attributedBuilder.chapterDataSize(at: i)
                if i == 0 || i == attributedBuilder.chapterCount - 1 || i % 200 == 0 {
                    startupTrace("byteScan progress=\(i + 1)/\(attributedBuilder.chapterCount)")
                }
            }
            sizes = computed
        } else {
            sizes = await withTaskGroup(of: (Int, Int).self) { group in
                for i in resourceProvider.chapters.indices {
                    group.addTask {
                        if Task.isCancelled { return (i, 0) }
                        let size = (try? await self.resourceProvider.chapterDataSize(at: i)) ?? 0
                        return (i, size)
                    }
                }
                var computed = [Int](repeating: 0, count: resourceProvider.chapters.count)
                for await (idx, size) in group { computed[idx] = size }
                return computed
            }
        }

        guard !Task.isCancelled else { return }
        guard currentBookId == bookId else { return }
        chapterByteSizes = sizes
        let totalBytes = sizes.reduce(0, +)
        startupTrace("byteScan done chapters=\(sizes.count) totalBytes=\(totalBytes)")
        rebuildPageOffsets()
        onChapterReady?(nil)

        // Persist sizes to SpinesCache so next open skips the scan entirely
        if let adapter = resourceProvider as? ReadiumBookResourceAdapter {
            adapter.saveChapterByteSizes(sizes)
        }
    }

    /// 全書進度（0.0 ~ 1.0）= (前 N-1 章總 Bytes + 當前章 charOffset) / 全書總 Bytes
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        guard !chapterByteSizes.isEmpty else {
            let totalChapters = max(chapterCount, 1)
            let clampedSpine = min(max(spineIndex, 0), totalChapters - 1)
            if !didLogProgressFallback {
                didLogProgressFallback = true
                startupTrace("totalProgress mode=fallback spine=\(spineIndex) clamped=\(clampedSpine) totalChapters=\(totalChapters)")
            }
            return min(1.0, Double(clampedSpine) / Double(totalChapters))
        }
        if !didLogProgressByteMode {
            didLogProgressByteMode = true
            startupTrace("totalProgress mode=bytes chapterByteSizesReady count=\(chapterByteSizes.count)")
        }
        let total = chapterByteSizes.reduce(0, +)
        guard total > 0 else { return 0 }
        let prior = chapterByteSizes.prefix(spineIndex).reduce(0, +)

        // 當前章的 charOffset 要按比例轉換為 bytes
        let currentChapterBytes = chapterByteSizes.indices.contains(spineIndex) ? chapterByteSizes[spineIndex] : 0
        let currentChapterChars = layouts[spineIndex]?.attributedString.length ?? currentChapterBytes
        let scaledOffset: Int
        if currentChapterChars > 0 {
            scaledOffset = Int(Double(charOffset) / Double(currentChapterChars) * Double(currentChapterBytes))
        } else {
            scaledOffset = charOffset
        }
        return min(1.0, Double(prior + scaledOffset) / Double(total))
    }

    /// 全書進度（0.0 ~ 1.0）對應的 (spineIndex, charOffset)
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        let totalChapters = chapterCount
        guard totalChapters > 0 else { return (0, 0) }

        guard !chapterByteSizes.isEmpty else {
            let idx = Int(progress * Double(max(0, totalChapters - 1)))
            let clamped = max(0, min(idx, totalChapters - 1))
            return (clamped, 0)
        }

        let totalBytes = chapterByteSizes.reduce(0, +)
        guard totalBytes > 0 else { return (0, 0) }
        let targetByte = Int(progress * Double(totalBytes))

        var currentSum = 0
        for (i, size) in chapterByteSizes.enumerated() {
            if currentSum + size > targetByte {
                let byteOffsetInChapter = targetByte - currentSum
                let charLength = layouts[i]?.attributedString.length ?? size
                let charOffset = Int(Double(byteOffsetInChapter) / Double(max(1, size)) * Double(charLength))
                return (i, charOffset)
            }
            currentSum += size
        }
        return (max(0, totalChapters - 1), 0)
    }

    /// 釋放距離當前章超過 1 的 layout，記憶體只保留 [n-1, n, n+1]
    private func evictDistantChapters(currentSpine: Int) {
        guard chapterCount > 0 else { return }
        let keep = Set(max(0, currentSpine - 1)...min(currentSpine + 1, chapterCount - 1))
        for key in layouts.keys where !keep.contains(key) {
            layouts.removeValue(forKey: key)
            chapterSnapshots.removeObject(forKey: NSNumber(value: key))
        }
        rebuildPageOffsets()
    }

    private func cancelPreloadTasks() {
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()
    }

    private func shouldAbortPreload(generation: Int) -> Bool {
        if generation != layoutGeneration {
            return true
        }
        do {
            try Task.checkCancellation()
            return false
        } catch {
            return true
        }
    }

    private func makePreloadTask(spineIndex: Int, generation: Int) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preloadTasks.removeValue(forKey: spineIndex) }
            await self.preloadChapterInternal(at: spineIndex, generation: generation)
        }
    }

    private func schedulePreloadChapter(at spineIndex: Int) {
        guard (0..<chapterCount).contains(spineIndex),
              layouts[spineIndex] == nil,
              preloadTasks[spineIndex] == nil else { return }

        let generation = layoutGeneration
        preloadTasks[spineIndex] = makePreloadTask(spineIndex: spineIndex, generation: generation)
    }

    func cancelPendingWork() {
        layoutGeneration += 1
        cancelPreloadTasks()
    }

    func pageViewController(at index: Int) -> UIViewController {
        let (spineIndex, localPage) = localPosition(for: index)
        if let layout = layouts[spineIndex] {
            return configuredPageViewController(
                layout: layout,
                spineIndex: spineIndex,
                localPage: localPage,
                globalPage: index
            )
        }
        let title = chapterTitle(at: spineIndex)
        let readingPosition: CoreTextReadingPosition? = localPage == 0
            ? .chapterStart(spineIndex)
            : nil
        let placeholder = PlaceholderPageViewController(
            chapterTitle: title,
            globalPage: index,
            readingPosition: readingPosition
        )
        Task { [weak self] in
            guard let self else { return }
            await self.preloadChapter(at: spineIndex)
            guard self.layouts[spineIndex] != nil else { return }
            self.onChapterReady?(spineIndex)
        }
        return placeholder
    }

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        guard spinePageOffsets.indices.contains(spineIndex) else { return 0 }
        if let layout = layouts[spineIndex] {
            let localPage = layout.pageIndex(for: charOffset)
            return spinePageOffsets[spineIndex] + localPage
        } else {
            // 未載入時模糊估算：每 400 字一頁 (保守值)
            let estimatedLocal = max(0, charOffset / 400)
            return spinePageOffsets[spineIndex] + estimatedLocal
        }
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        CoreTextReadingPositionMapper.pageIndex(
            for: position,
            layouts: layouts,
            spinePageOffsets: spinePageOffsets
        )
    }

    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count else {
            return CoreTextReadingPosition.chapterStart(spineIndex)
        }
        return CoreTextReadingPosition(
            spineIndex: spineIndex,
            charOffset: Int(layout.pageRanges[localPage].location)
        )
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count else {
            return (spineIndex, 0)
        }
        return (spineIndex, Int(layout.pageRanges[localPage].location))
    }

    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        guard (0..<chapterCount).contains(position.spineIndex) else {
            return pageViewController(at: 0)
        }

        if let globalPage = pageIndex(for: position) {
            return pageViewController(at: globalPage)
        }

        let title = chapterTitle(at: position.spineIndex)
        let estimatedGlobalPage = estimatedGlobalPage(for: position)
        let placeholder = PlaceholderPageViewController(
            chapterTitle: title,
            globalPage: estimatedGlobalPage,
            readingPosition: position
        )
        Task { [weak self] in
            guard let self else { return }
            await self.preloadChapter(at: position.spineIndex)
            guard self.layouts[position.spineIndex] != nil else { return }
            self.onChapterReady?(position.spineIndex)
        }
        return placeholder
    }

    func preloadChapter(at spineIndex: Int) async {
        guard (0..<chapterCount).contains(spineIndex) else { return }
        if layouts[spineIndex] != nil { return }
        if let existing = preloadTasks[spineIndex] {
            await existing.value
            return
        }

        let generation = layoutGeneration
        let task = makePreloadTask(spineIndex: spineIndex, generation: generation)
        preloadTasks[spineIndex] = task
        await task.value
    }

    func notifyChapterDataChanged(at spineIndex: Int) async {
        guard (0..<chapterCount).contains(spineIndex) else { return }
        print("[FetchTrace] engine.notifyChapterDataChanged enter ch=\(spineIndex)")

        // 1. 清除舊 layout 與進行中的 preload task
        layouts[spineIndex] = nil
        preloadTasks[spineIndex]?.cancel()
        preloadTasks[spineIndex] = nil
        chapterSnapshots.removeObject(forKey: NSNumber(value: spineIndex))

        // 2. 增量更新該章節的 byte size（O(1)，不重掃全書）
        if let builder = attributedBuilder {
            let size = await builder.chapterDataSize(at: spineIndex)
            if spineIndex < chapterByteSizes.count {
                chapterByteSizes[spineIndex] = size
            } else if chapterByteSizes.count == spineIndex {
                chapterByteSizes.append(size)
            }
        }

        // 3. 重新載入該章節（preloadChapter 會檢查 layouts[spineIndex] == nil 後執行）
        await preloadChapter(at: spineIndex)

        // 4. 通知 ReaderView 刷新：舊的 CoreTextPageView 還渲染著 placeholder，
        //    必須換成新 layout 對應的 VC 才能看到真正內容。
        let layoutOK = layouts[spineIndex] != nil
        print("[FetchTrace] engine.notifyChapterDataChanged done ch=\(spineIndex) layoutOK=\(layoutOK) hasCallback=\(onChapterReady != nil)")
        if layoutOK {
            onChapterReady?(spineIndex)
        }
    }

    private func preloadChapterInternal(at spineIndex: Int, generation: Int) async {
        guard (0..<chapterCount).contains(spineIndex),
              layouts[spineIndex] == nil else { return }
        guard !shouldAbortPreload(generation: generation) else { return }

        if let attributedBuilder {
            guard let buildResult = try? await attributedBuilder.buildChapter(
                at: spineIndex,
                settings: renderSettings,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            ) else {
                print("[CoreTextEngine] preloadChapter[\(spineIndex)] FAILED to build attributed string")
                return
            }
            guard !shouldAbortPreload(generation: generation) else { return }

            let request = PaginationRequest(
                spineIndex: spineIndex,
                attributedString: buildResult.attributedString,
                imagePage: buildResult.imagePage,
                pageBackgroundImage: buildResult.pageBackgroundImage,
                anchorOffsets: buildResult.anchorOffsets,
                renderSize: renderSize,
                fontSize: renderSettings.fontSize,
                lineSpacing: renderSettings.lineSpacing,
                paragraphSpacing: renderSettings.paragraphSpacing,
                letterSpacing: renderSettings.letterSpacing,
                contentInsets: currentContentInsets()
            )
            let layout = await paginationManager.paginate(request).layout
            guard !shouldAbortPreload(generation: generation) else { return }

            layouts[spineIndex] = layout.withUpdatedColors(textColor: themeTextColor, backgroundColor: themeBackgroundColor)
            generateSnapshot(for: spineIndex)
            rebuildPageOffsets()
            applyPendingRestoreIfPossible()
            return
        }

        if spineIndex == 0 {
            let cssHrefs = resourceProvider.cssResourceHrefs()
            print("[CoreTextEngine] Publication CSS hrefs: \(cssHrefs)")
        }

        guard let html = try? await resourceProvider.chapterHTML(at: spineIndex) else {
            print("[CoreTextEngine] preloadChapter[\(spineIndex)] FAILED to get HTML")
            return
        }
        guard !shouldAbortPreload(generation: generation) else { return }

        let chapterHref = chapterSourceHref(at: spineIndex)
        let localBuilder = HTMLAttributedStringBuilder()
        localBuilder.resolvedFont = { [weak self] families, weight, italic, size in
            self?.styleResolver.resolveRegisteredFont(
                families: families,
                weight: weight,
                italic: italic,
                size: size
            )
        }
        localBuilder.resolvedFontFamily = { [weak self] rawName in
            guard let self else { return nil }
            let normalized = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .lowercased()
            return self.styleResolver.registeredFontFaces[normalized]?.postScriptName
                ?? self.styleResolver.registeredFontFaces[normalized]?.familyName
        }
        localBuilder.imageLoader = { [weak self] src in
            guard let self else { return nil }
            return await self.loadImageResource(from: src, chapterHref: chapterHref)
        }
        localBuilder.cssLoader = { [weak resourceProvider] href in
            guard let resourceProvider else { return nil }
            let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
            let url = resourceProvider.resourceURL(for: resolved)
            print("[CoreTextEngine] cssLoader href=\(href) → resolved=\(resolved) → url=\(url)")
            do {
                let response = try await resourceProvider.response(for: url)
                let cssText = String(data: response.data, encoding: .utf8) ?? ""
                let processed = await self.styleResolver.processStylesheet(cssText, cssHref: resolved, chapterHref: chapterHref)
                print("[CoreTextEngine] cssLoader OK len=\(processed.count)")
                return processed.isEmpty ? nil : processed
            } catch {
                print("[CoreTextEngine] cssLoader ERROR: \(error)")
                return nil
            }
        }
        let config = currentBuilderConfig()
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] htmlLen=\(html.count) fontSize=\(config.fontSize) renderSize=\(renderSize)")
        let buildResult = await localBuilder.build(html: html, config: config)
        guard !shouldAbortPreload(generation: generation) else { return }
        let attrStr = buildResult.attributedString
        let pageBackgroundImage = await resolvedPageBackgroundImage(
            initial: buildResult.pageBackgroundImage,
            source: buildResult.pageBackgroundImageSource,
            chapterHref: chapterHref
        )
        guard !shouldAbortPreload(generation: generation) else { return }
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] attrStrLen=\(attrStr.length)")
        let request = PaginationRequest(
            spineIndex: spineIndex,
            attributedString: attrStr,
            imagePage: buildResult.imagePage,
            pageBackgroundImage: pageBackgroundImage,
            anchorOffsets: buildResult.anchorOffsets,
            renderSize: renderSize,
            fontSize: config.fontSize,
            lineSpacing: renderSettings.lineSpacing,
            paragraphSpacing: renderSettings.paragraphSpacing,
            letterSpacing: renderSettings.letterSpacing,
            contentInsets: currentContentInsets()
        )
        let layout = await paginationManager.paginate(request).layout
        guard !shouldAbortPreload(generation: generation) else { return }
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] pageCount=\(layout.pageRanges.count)")
        // 套用當前主題色（防止預載 Task 在主題切換前開始、切換後完成，導致舊色覆蓋新色）
        layouts[spineIndex] = layout.withUpdatedColors(textColor: themeTextColor, backgroundColor: themeBackgroundColor)
        generateSnapshot(for: spineIndex)
        rebuildPageOffsets()
        applyPendingRestoreIfPossible()
    }

    private func resolvedPageBackgroundImage(
        initial: UIImage?,
        source: String?,
        chapterHref: String
    ) async -> UIImage? {
        if let initial {
            return initial
        }
        guard let source, !source.isEmpty else { return nil }
        if let image = await loadImageResource(from: source, chapterHref: chapterHref) {
            return image
        }
        print("[CoreTextEngine] page background load FAILED source=\(source) chapter=\(chapterHref)")
        return nil
    }

    private func loadImageResource(from source: String, chapterHref: String) async -> UIImage? {
        let candidates = imageCandidateHrefs(for: source, chapterHref: chapterHref)
        print("[ImageLoader] src=\(source) chapter=\(chapterHref) candidates=\(candidates)")
        for candidate in candidates {
            if let absolute = URL(string: candidate), absolute.scheme != nil {
                if let response = try? await resourceProvider.response(for: absolute),
                   let image = UIImage(data: response.data) {
                    print("[ImageLoader] ✅ loaded via absolute URL: \(candidate)")
                    return image
                }
                if absolute.scheme == resourceProvider.customScheme {
                    let fallbackHref = absolute.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let fallbackURL = resourceProvider.resourceURL(for: fallbackHref)
                    if let response = try? await resourceProvider.response(for: fallbackURL),
                       let image = UIImage(data: response.data) {
                        print("[ImageLoader] ✅ loaded via scheme fallback: \(fallbackHref)")
                        return image
                    }
                    print("[ImageLoader] ❌ scheme fallback failed: \(fallbackHref)")
                } else {
                    print("[ImageLoader] ❌ absolute URL failed: \(candidate)")
                }
            } else if let response = try? await resourceProvider.response(for: resourceProvider.resourceURL(for: candidate)),
                      let image = UIImage(data: response.data) {
                print("[ImageLoader] ✅ loaded via relative path: \(candidate)")
                return image
            } else {
                let url = resourceProvider.resourceURL(for: candidate)
                if let response = try? await resourceProvider.response(for: url) {
                    print("[ImageLoader] ❌ UIImage decode failed for: \(candidate) dataLen=\(response.data.count) url=\(url)")
                } else {
                    print("[ImageLoader] ❌ session.response failed for: \(candidate) url=\(url)")
                }
            }
        }
        print("[ImageLoader] ❌ ALL candidates failed for src=\(source)")
        return nil
    }

    private func imageCandidateHrefs(for source: String, chapterHref: String) -> [String] {
        guard !source.isEmpty else { return [] }
        var candidates: [String] = []

        if source.hasPrefix(resourceProvider.customScheme + "://") || source.hasPrefix("http://") || source.hasPrefix("https://") {
            candidates.append(source)
            if let absolute = URL(string: source), absolute.scheme == resourceProvider.customScheme {
                let fallbackHref = absolute.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !fallbackHref.isEmpty {
                    candidates.append(fallbackHref)
                }
            }
        } else {
            candidates.append(EPUBStyleResolver.resolveImageHref(source, chapterHref: chapterHref))
            let raw = source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !raw.isEmpty {
                candidates.append(raw)
            }
            let basename = (raw as NSString).lastPathComponent
            if !basename.isEmpty {
                candidates.append(basename)
            }
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    func invalidateLayout(newSize: CGSize) async {
        cancelPendingWork()
        isRelaying = true
        renderSize = newSize
        paginationManager.invalidate(reason: .viewSizeChanged)

        // 只重排目前記憶體中有的章節
        let loadedSpines = Array(layouts.keys.sorted())
        layouts.removeAll()
        chapterSnapshots.removeAllObjects()

        await withTaskGroup(of: Void.self) { group in
            for i in loadedSpines {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }

        // 重新掃描 byte sizes 不需要（不隨字號變化）
        // 恢復 currentPage（charOffset 不變，但頁碼可能不同）
        if let bookId = currentBookId, let record = offsetStore.load(bookId: bookId) {
            let maxSpineIndex = max(0, chapterCount - 1)
            pendingRestoreTarget = (
                max(0, min(record.spineIndex, maxSpineIndex)),
                max(0, record.charOffset)
            )
            applyPendingRestoreIfPossible()
        }
        isRelaying = false
        onChapterReady?(nil)
    }

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let targetSpine: Int
        if rawPath.isEmpty {
            targetSpine = spineIndex
        } else {
            let resolvedHref = EPUBStyleResolver.resolveImageHref(rawPath, chapterHref: chapterSourceHref(at: spineIndex))
            guard let matchedIndex = chapterIndex(for: resolvedHref) ?? chapterIndex(for: rawPath) else {
                return nil
            }
            targetSpine = matchedIndex
        }

        await preloadChapter(at: targetSpine)
        guard let layout = layouts[targetSpine] else { return nil }
        let charOffset: Int
        if let fragment, !fragment.isEmpty {
            charOffset = layout.anchorOffsets[fragment] ?? 0
        } else {
            charOffset = 0
        }
        return pageIndex(forSpine: targetSpine, charOffset: charOffset)
    }

    func warmUpNext(currentGlobalPage: Int) {
        let (spineIndex, localPage) = localPosition(for: currentGlobalPage)

        // 翻頁時呼叫釋放遠端章節
        evictDistantChapters(currentSpine: spineIndex)

        guard let layout = layouts[spineIndex] else { return }
        let total = layout.pageRanges.count
        // Trigger at 20% remaining (minimum 3 pages) so snapshot is ready before chapter boundary
        let threshold = max(3, Int(Double(total) * 0.20))
        let remaining = total - localPage
        if remaining <= threshold {
            let nextSpine = spineIndex + 1
            if nextSpine < chapterCount {
                schedulePreloadChapter(at: nextSpine)
            }
        }
        // 接近章節開頭時預載上一章，確保向後翻跨章能正確定位最後一頁
        if localPage < threshold && spineIndex > 0 && layouts[spineIndex - 1] == nil {
            schedulePreloadChapter(at: spineIndex - 1)
        }
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        let (spineIndex, localPage) = localPosition(for: index)
        // 快照只用於章節邊界接力。第 0 頁 key 為 (spineIndex << 1)
        guard localPage == 0,
              let snapshot = chapterSnapshots.object(forKey: NSNumber(value: (spineIndex << 1))) else { return nil }
        let bgColor: UIColor
        if let layout = layouts[spineIndex],
           layout.attributedString.length > 0,
           let color = layout.attributedString.attribute(
               .backgroundColor, at: 0, effectiveRange: nil
           ) as? UIColor {
            bgColor = color
        } else {
            bgColor = .systemBackground
        }
        return SnapshotPageViewController(
            image: snapshot,
            globalPage: index,
            backgroundColor: bgColor,
            readingPosition: readingPosition(forPage: index)
        )
    }

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        themeTextColor = textColor
        themeBackgroundColor = backgroundColor
        // 顏色不影響換行，直接同步更新 attributedString + framesetter，保留 blockAttachments 等所有結構
        for spineIndex in layouts.keys {
            layouts[spineIndex] = layouts[spineIndex]?.withUpdatedColors(textColor: textColor, backgroundColor: backgroundColor)
        }
        chapterSnapshots.removeAllObjects()
        onChapterReady?(nil)
        // 在背景重建各章節的邊界快照（用於跨章節動畫）
        for spineIndex in layouts.keys {
            generateSnapshot(for: spineIndex)
        }
    }

    /// 離屏渲染任意全局頁為 UIImage，供 cover 動畫即時快照使用。
    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        let (spineIndex, localPage) = localPosition(for: globalPage)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count,
              renderSize.width > 0, renderSize.height > 0 else { return nil }
        
        // 優先從邊界快取中尋找 (Key: (spine << 1) | isLastPage)
        let isLastPage = localPage == (layout.pageRanges.count - 1)
        if localPage == 0 || isLastPage {
            let key = NSNumber(value: (spineIndex << 1) | (isLastPage ? 1 : 0))
            if let cached = chapterSnapshots.object(forKey: key) {
                return cached
            }
        }
        
        let bgColor: UIColor
        if layout.attributedString.length > 0,
           let color = layout.attributedString.attribute(
               .backgroundColor, at: 0, effectiveRange: nil
           ) as? UIColor {
            bgColor = color
        } else {
            bgColor = .systemBackground
        }

        return Self.renderImage(layout: layout, pageIndex: localPage, size: renderSize, bgColor: bgColor.cgColor)
    }

    // MARK: - Private helpers

    /// 將章節第 0 頁和最後一頁預渲染成 UIImage，存入 chapterSnapshots 以供跨章節動畫接力。
    /// 使用 Task.detached 在背景執行緒渲染，避免阻塞主執行緒。
    private func generateSnapshot(for spineIndex: Int) {
        guard let layout = layouts[spineIndex],
              !layout.pageRanges.isEmpty,
              renderSize.width > 0, renderSize.height > 0 else { return }
        
        let size = renderSize
        let bgColor: UIColor
        if layout.attributedString.length > 0,
           let color = layout.attributedString.attribute(
               .backgroundColor, at: 0, effectiveRange: nil
           ) as? UIColor {
            bgColor = color
        } else {
            bgColor = .systemBackground
        }
        
        // 將 UIColor 轉為 CGColor 以便在非隔離環境傳遞
        let bgCGColor = bgColor.cgColor
        
        // 第 0 頁快照 (Key: (spine << 1))
        let firstKey = NSNumber(value: (spineIndex << 1))
        if chapterSnapshots.object(forKey: firstKey) == nil {
            Task {
                let img = await Task.detached(priority: .userInitiated) {
                    Self.renderImage(layout: layout, pageIndex: 0, size: size, bgColor: bgCGColor)
                }.value
                self.chapterSnapshots.setObject(img, forKey: firstKey, cost: Self.imageCost(img))
            }
        }

        // 最後一頁快照 (Key: (spine << 1) | 1)
        let lastIdx = layout.pageRanges.count - 1
        if lastIdx > 0 {
            let lastKey = NSNumber(value: (spineIndex << 1) | 1)
            if chapterSnapshots.object(forKey: lastKey) == nil {
                Task {
                    let img = await Task.detached(priority: .userInitiated) {
                        Self.renderImage(layout: layout, pageIndex: lastIdx, size: size, bgColor: bgCGColor)
                    }.value
                    self.chapterSnapshots.setObject(img, forKey: lastKey, cost: Self.imageCost(img))
                }
            }
        }
    }

    private nonisolated static func imageCost(_ image: UIImage) -> Int {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        let bytesPerPixel = 4
        return max(width * height * bytesPerPixel, 1)
    }

    private nonisolated static func renderImage(
        layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int,
        size: CGSize,
        bgColor: CGColor
    ) -> UIImage {
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(bgColor)
            c.fill(CGRect(origin: .zero, size: size))
            CoreTextPageView.renderPage(
                layout: layout,
                pageIndex: pageIndex,
                in: c,
                bounds: CGRect(origin: .zero, size: size)
            )
        }
    }

    /// 回傳指定章節最後一頁的全局頁碼。章節未載入時回傳 nil。
    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        guard let layout = layouts[spineIndex],
              spinePageOffsets.indices.contains(spineIndex) else { return nil }
        return spinePageOffsets[spineIndex] + max(0, layout.pageRanges.count - 1)
    }

    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
        guard !spinePageOffsets.isEmpty else { return (0, globalPage) }
        var lo = 0
        var hi = spinePageOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spinePageOffsets[mid] <= globalPage { lo = mid } else { hi = mid - 1 }
        }
        let localPage = globalPage - spinePageOffsets[lo]
        return (lo, max(0, localPage))
    }

    private func rebuildPageOffsets() {
        let anchoredPosition = readingPosition(forPage: currentPage) ?? .chapterStart(0)
        let oldOffsets = spinePageOffsets
        let oldPage = currentPage
        var offset = 0
        
        // 取得估算用的每頁位元組數 (假設中文環境 600 bytes 一頁)
        let avgBytesPerPage = 600 

        spinePageOffsets = (0..<chapterCount).map { i in
            let start = offset
            if let layout = layouts[i] {
                offset += layout.pageRanges.count
            } else if i < chapterByteSizes.count && chapterByteSizes[i] > 0 {
                // 根據 Byte 大小估算頁數
                offset += max(1, chapterByteSizes[i] / avgBytesPerPage)
            } else {
                // 未載入且無 Byte 資訊時估 1 頁，確保 spinePageOffsets 和 totalPages 不崩壞
                offset += 1
            }
            return start
        }
        totalPages = offset

        if let correctedPage = pageIndex(for: anchoredPosition) {
            currentPage = max(0, min(correctedPage, max(totalPages - 1, 0)))
        }

        if currentPage != oldPage {
            onNavigateToPage?(currentPage)
        }
        
        if !oldOffsets.isEmpty, oldOffsets != spinePageOffsets {
            onChapterReady?(nil)
        }
    }

    private func configuredPageViewController(
        layout: CoreTextPaginator.ChapterLayout,
        spineIndex: Int,
        localPage: Int,
        globalPage: Int
    ) -> UIViewController {
        let vc = CoreTextPageViewController()
        vc.onInternalLinkTap = { [weak self] href in
            guard let self else { return }
            Task { @MainActor in
                guard let targetPage = await self.resolveInternalLink(href, fromSpineIndex: spineIndex) else {
                    return
                }
                self.onNavigateToPage?(targetPage)
            }
        }
        let readingPosition = CoreTextReadingPosition(
            spineIndex: spineIndex,
            charOffset: Int(layout.pageRanges[localPage].location)
        )
        vc.configure(
            layout: layout,
            localPage: localPage,
            globalPage: globalPage,
            readingPosition: readingPosition,
            fallbackBackgroundColor: themeBackgroundColor
        )
        return vc
    }

    private func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int {
        guard spinePageOffsets.indices.contains(position.spineIndex) else { return 0 }
        return spinePageOffsets[position.spineIndex]
    }

    private func resolvedPageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int? {
        guard spinePageOffsets.indices.contains(spineIndex),
              let layout = layouts[spineIndex] else { return nil }
        let localPage = layout.pageIndex(for: charOffset)
        return spinePageOffsets[spineIndex] + localPage
    }

    private func applyPendingRestoreIfPossible() {
        guard let target = pendingRestoreTarget else { return }
        guard let resolved = resolvedPageIndex(forSpine: target.spineIndex, charOffset: target.charOffset) else {
            print("[ProgressTrace][CoreTextPageEngine] pendingRestore waiting spine=\(target.spineIndex) charOffset=\(target.charOffset) layoutsReady=\(layouts[target.spineIndex] != nil)")
            return
        }
        print("[ProgressTrace][CoreTextPageEngine] pendingRestore applied spine=\(target.spineIndex) charOffset=\(target.charOffset) resolvedPage=\(resolved)")
        let previousPage = currentPage
        currentPage = resolved
        if previousPage != resolved {
            onNavigateToPage?(resolved)
        }
        pendingRestoreTarget = nil
    }

    private func currentContentInsets() -> UIEdgeInsets {
        renderSettings.contentInsets
    }

    private func currentBuilderConfig() -> HTMLAttributedStringBuilder.Config {
        let fontSize = renderSettings.fontSize
        let horizontalInsets = renderSettings.contentInsets.left + renderSettings.contentInsets.right
        return HTMLAttributedStringBuilder.Config(
            fontSize: fontSize,
            lineHeightMultiple: renderSettings.lineHeightMultiple,
            lineSpacing: renderSettings.lineSpacing,
            paragraphSpacing: renderSettings.paragraphSpacing,
            firstLineIndent: fontSize * 2,
            textColor: currentTextColor(),
            backgroundColor: currentBackgroundColor(),
            fontFamilyName: nil,
            renderWidth: max(1, renderSize.width - horizontalInsets)
        )
    }

    /// Returns appropriate text color. GlobalSettings does not expose a theme enum,
    /// so we fall back to the system adaptive label color which respects dark/light mode.
    private func currentTextColor() -> UIColor { themeTextColor }
    private func currentBackgroundColor() -> UIColor { themeBackgroundColor }


    /// 取得某頁的純文字內容（供 TTS / 書籤摘錄使用）
    func plainText(forPage page: Int) -> String {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count else { return "" }
        let range = layout.pageRanges[localPage]
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location != NSNotFound, nsRange.length > 0,
              nsRange.location + nsRange.length <= layout.attributedString.length else { return "" }
        return (layout.attributedString.string as NSString).substring(with: nsRange)
    }

    private func migrateFromLegacyProgressIfNeeded(bookId: String) {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let progressDir = docsURL.appendingPathComponent("epub_progress/\(bookId)")
        let legacyStore = EPUBProgressStore(directoryURL: progressDir)
        guard let locator = legacyStore.loadLastRecord() else { return }

        let spineIndex = locator.chapterIndex
        guard let layout = layouts[spineIndex] else {
            pendingRestoreTarget = (spineIndex, 0)
            return
        }
        let progression = locator.chapterProgression ?? locator.progression
        let charOffset = Int(progression * Double(layout.attributedString.length))
        pendingRestoreTarget = (spineIndex, charOffset)
        applyPendingRestoreIfPossible()
    }
}
