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
                AppLogger.render("[CoreTextEngine] registerFont URL register warning: \(error)")
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
            AppLogger.render("[CoreTextEngine] registerFont temp write failed: \(error)")
        }

        guard
            let provider = CGDataProvider(data: data as CFData),
            let cgFont = CGFont(provider)
        else {
            AppLogger.render("[CoreTextEngine] registerFont CGFont provider failed header=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
            return nil
        }

        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
        if CFArrayGetCount(descriptors) == 0 {
            AppLogger.render("[CoreTextEngine] registerFont warning: failed to register font from data")
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

@MainActor
final class CoreTextPageEngine: PageRenderingProvider {

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0

    private let _layouts = LayoutCache<CoreTextPaginator.ChapterLayout>()
    var layouts: [Int: CoreTextPaginator.ChapterLayout] {
        _layouts.asDictionary
    }
    private let chapterSnapshots: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        // Control snapshot cache cost: ~5% of physical memory, clamped to 64MB–256MB.
        let budget = min(max(physicalMemory / 20, 64 * 1024 * 1024), 256 * 1024 * 1024)
        cache.totalCostLimit = Int(budget)
        // Keep a modest countLimit to avoid flooding the cache with many low-cost snapshots.
        cache.countLimit = 12
        return cache
    }()
    private var spinePageOffsets: [Int] = []
    private(set) var renderSize: CGSize = .zero
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var layoutGeneration: Int = 0

    private let attributedBuilder: any AttributedStringBuilding
    private let paginationManager: PaginationManager
    let offsetStore: CharOffsetStore

    private(set) var renderSettings: ReaderRenderSettings

    private var currentBookId: String?
    private var chapterByteScanTask: Task<Void, Never>?
    private var startupBeganUptime: TimeInterval?
    private var didLogProgressFallback = false
    private var didLogProgressByteMode = false
    /// Raw data size (bytes) per chapter, used for global progress estimation
    private var chapterByteSizes: [Int] = []
    /// Prefix-summed byte units for stable O(1) reading metrics. Unlike layouts,
    /// this metadata is not evicted by the chapter LRU.
    private var contentUnitMap: ReaderContentUnitMap?

    private(set) var isRelaying = false

    private var themeTextColor: UIColor = .label
    private var themeBackgroundColor: UIColor = .systemBackground
    private var cachedReaderBackgroundImageURL: URL?
    private var cachedReaderBackgroundImage: UIImage?
    private var textAnnotations: [CoreTextTextAnnotation] = []
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?
    /// Fired when a tapped in-content link (TOC table, cross-reference) resolves to a page.
    /// Distinct from `onNavigateToPage`, which is a binding-level offset-correction channel:
    /// the host's executor model never turns a bare binding write into a visible page change,
    /// so a link tap must come through here to actually move the page view controller.
    var onLinkNavigate: ((Int) -> Void)?
    /// Fired instead of `onNavigateToPage` when a tapped internal link resolves to a duokan
    /// popup footnote (`FootnoteStore`) — the note text, ready to show in place.
    var onFootnoteTap: ((String) -> Void)?

    deinit {
        chapterByteScanTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func subscribeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.chapterSnapshots.removeAllObjects()
                self?.cancelPreloadTasks()
            }
        }

        // A requested CJK font (楷体/宋体/…) finished downloading — re-paginate loaded chapters so
        // the real typeface replaces the PingFang fallback rendered on the first pass.
        NotificationCenter.default.addObserver(
            forName: CJKFontInstaller.didInstallNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.renderSize != .zero, !self.isRelaying else { return }
                Task { await self.invalidateLayout(newSize: self.renderSize) }
            }
        }
    }

    private func startupElapsedMs() -> String {
        guard let startupBeganUptime else { return "n/a" }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startupBeganUptime) * 1000
        return String(format: "%.1f", elapsedMs)
    }

    private func startupTrace(_ message: String) {
        let line = "[StartupTrace][CoreTextPageEngine][+\(startupElapsedMs())ms] \(message)"
        AppLogger.render(line)
        NSLog("%@", line)
    }

    init(
        attributedBuilder: any AttributedStringBuilding,
        renderSettings: ReaderRenderSettings,
        paginationManager: PaginationManager? = nil,
        offsetStore: CharOffsetStore
    ) {
        self.attributedBuilder = attributedBuilder
        self.renderSettings = renderSettings
        self.paginationManager = paginationManager ?? PaginationManager()
        self.offsetStore = offsetStore
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
            attributedBuilder: EPUBAttributedStringBuilder(session: session, renderSize: .zero),
            renderSettings: renderSettings,
            paginationManager: paginationManager,
            offsetStore: offsetStore
        )
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        renderSettings = settings
    }

    private func currentReaderBackgroundImage() -> UIImage? {
        let url = renderSettings.readerBackgroundImageURL
        guard cachedReaderBackgroundImageURL != url else { return cachedReaderBackgroundImage }
        cachedReaderBackgroundImageURL = url
        cachedReaderBackgroundImage = url.flatMap { UIImage(contentsOfFile: $0.path) }
        return cachedReaderBackgroundImage
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
        onChapterReady?(nil)
    }

    private var chapterCount: Int {
        attributedBuilder.chapterCount
    }

    private func chapterTitle(at index: Int) -> String {
        attributedBuilder.chapterTitle(at: index)
    }

    private func chapterSourceHref(at index: Int) -> String {
        attributedBuilder.chapterSourceHref(at: index) ?? ""
    }

    private func chapterIndex(for href: String) -> Int? {
        attributedBuilder.chapterIndex(for: href)
    }

    func start(renderSize: CGSize, bookId: String) async {
        startupBeganUptime = ProcessInfo.processInfo.systemUptime
        self.renderSize = renderSize
        updateBuilderRenderSize(renderSize)
        self.currentBookId = bookId
        didLogProgressFallback = false
        didLogProgressByteMode = false
        let totalChapters = chapterCount
        AppLogger.render("[CoreTextEngine] start renderSize=\(renderSize) chapters=\(totalChapters)")
        startupTrace("start bookId=\(bookId) renderSize=\(renderSize) chapters=\(totalChapters)")
        guard totalChapters > 0 else {
            totalPages = 0
            currentPage = 0
            return
        }

        // 1. Background scan of all chapter data sizes (does not block the main open-book flow)
        chapterByteScanTask?.cancel()
        chapterByteSizes = []
        contentUnitMap = nil
        startupTrace("byteScan launch mode=background")
        chapterByteScanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanChapterByteSizes(for: bookId)
        }

        // 2. Load chapter 0. Restore targets are supplied by ReaderNavigator/ReaderView;
        // the engine no longer reads persisted position independently.
        var priority = Set<Int>()
        priority.insert(0) // Cover/TOC is always needed
        startupTrace("preload priority=\(priority.sorted())")

        await withTaskGroup(of: Void.self) { group in
            for i in priority.sorted() {
                group.addTask { await self.awaitFirstLayout(at: i) }
            }
        }
        startupTrace("preload priority done totalPages=\(totalPages)")
        AppLogger.render("[CoreTextEngine] start done totalPages=\(totalPages)")
    }

    /// Returns once the spine has ANY layout installed — a partial first page
    /// counts. Used by `start()` so the reader's first paint isn't gated on
    /// paginating a huge opening chapter fully; the running preload task keeps
    /// completing the layout in the background.
    private func awaitFirstLayout(at spineIndex: Int) async {
        guard (0..<chapterCount).contains(spineIndex) else { return }
        if _layouts[spineIndex] != nil { return }
        schedulePreloadChapter(at: spineIndex)
        // Installs happen on the main actor between awaits; poll at frame pace.
        while _layouts[spineIndex] == nil, preloadTasks[spineIndex] != nil {
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func scanChapterByteSizes(for bookId: String) async {
        startupTrace("byteScan begin bookId=\(bookId) chapters=\(chapterCount) mode=builder")

        // Lazy path: online books skip the full O(N) scan.
        // Sizes are filled incrementally via notifyChapterDataChanged.
        if attributedBuilder.prefersLazyByteScan {
            guard !Task.isCancelled else { return }
            guard currentBookId == bookId else { return }
            chapterByteSizes = [Int](repeating: 0, count: attributedBuilder.chapterCount)
            contentUnitMap = nil
            startupTrace("byteScan lazy chapters=\(attributedBuilder.chapterCount)")
            rebuildPageOffsets()
            onChapterReady?(nil)
            return
        }

        var sizes = [Int](repeating: 0, count: attributedBuilder.chapterCount)
        for i in 0..<attributedBuilder.chapterCount {
            if Task.isCancelled { return }
            sizes[i] = await attributedBuilder.chapterDataSize(at: i)
            if i == 0 || i == attributedBuilder.chapterCount - 1 || i % 200 == 0 {
                startupTrace("byteScan progress=\(i + 1)/\(attributedBuilder.chapterCount)")
            }
        }

        guard !Task.isCancelled else { return }
        guard currentBookId == bookId else { return }
        chapterByteSizes = sizes
        contentUnitMap = ReaderContentUnitMap(chapterUnitCounts: sizes)
        let totalBytes = sizes.reduce(0, +)
        startupTrace("byteScan done chapters=\(sizes.count) totalBytes=\(totalBytes)")
        rebuildPageOffsets()
        onChapterReady?(nil)
    }

    /// Global progress (0.0 ~ 1.0).
    ///
    /// - Online books (`prefersLazyByteScan == true`): uses `(spineIndex + intra-chapter page progress) / chapterCount`.
    ///   Because unfetched chapters have byteSize=0, byte-based summation would drift as fetching progresses
    ///   (e.g. chapter 4 shows 80% initially, then drops to 7% as more chapters are fetched). Chapter-index-based progress stays stable.
    /// - EPUB / TXT: all chapter byte sizes are known at open time, byte-based summation is more accurate (longer chapters have higher weight).
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        let totalChapters = max(chapterCount, 1)
        let clampedSpine = min(max(spineIndex, 0), totalChapters - 1)

        if attributedBuilder.prefersLazyByteScan {
            let layout = _layouts[clampedSpine]
            let charLen = layout?.attributedString.length ?? 0
            let chapterFraction: Double
            if charLen > 0 {
                chapterFraction = min(1.0, max(0.0, Double(charOffset) / Double(charLen)))
            } else {
                chapterFraction = 0
            }
            return min(1.0, (Double(clampedSpine) + chapterFraction) / Double(totalChapters))
        }

        if let metrics = contentMetrics(
            forSpine: clampedSpine,
            charOffset: charOffset,
            currentChapterCharacterCount: nil
        ) {
            return Double(metrics.currentUnitOffset) / Double(metrics.totalUnitCount)
        }

        guard !chapterByteSizes.isEmpty else {
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

        // Convert the current chapter's charOffset proportionally to bytes
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

    func contentMetrics(
        forSpine spineIndex: Int,
        charOffset: Int,
        currentChapterCharacterCount: Int?
    ) -> ReaderContentMetrics? {
        guard !attributedBuilder.prefersLazyByteScan,
              let contentUnitMap
        else {
            return nil
        }
        let characterCount = currentChapterCharacterCount
            ?? _layouts[spineIndex]?.attributedString.length
        return contentUnitMap.metrics(
            spineIndex: spineIndex,
            localCharacterOffset: charOffset,
            currentChapterCharacterCount: characterCount
        )
    }

    /// Maps global progress (0.0 ~ 1.0) to (spineIndex, charOffset)
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        let totalChapters = chapterCount
        guard totalChapters > 0 else { return (0, 0) }

        // Online books: align with totalProgress's chapter-index-based approach to avoid jumping to wrong chapters when dragging the slider
        if attributedBuilder.prefersLazyByteScan {
            let scaled = progress * Double(totalChapters)
            let idx = max(0, min(Int(scaled), totalChapters - 1))
            let chapterFraction = max(0.0, min(1.0, scaled - Double(idx)))
            let charLen = layouts[idx]?.attributedString.length ?? 0
            let charOffset = charLen > 0 ? Int(chapterFraction * Double(charLen)) : 0
            return (idx, charOffset)
        }

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

    /// Track current chapter for distance-based LRU eviction (capacity 8).
    private func evictDistantChapters(currentSpine: Int) {
        _layouts.setCurrentChapter(currentSpine)
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
        guard (0..<chapterCount).contains(spineIndex) else {
            AppLogger.render("[FlipTrace] schedulePreload skip outOfRange spine=\(spineIndex) chapterCount=\(chapterCount)")
            return
        }
        guard _layouts[spineIndex]?.isPartial != false else {
            AppLogger.render("[FlipTrace] schedulePreload skip loaded spine=\(spineIndex) layouts=\(_layouts.keys.sorted())")
            return
        }
        guard preloadTasks[spineIndex] == nil else {
            AppLogger.render("[FlipTrace] schedulePreload skip pending spine=\(spineIndex) pending=\(preloadTasks.keys.sorted())")
            return
        }

        let generation = layoutGeneration
        AppLogger.render("[FlipTrace] schedulePreload spine=\(spineIndex) generation=\(generation) layouts=\(_layouts.keys.sorted())")
        preloadTasks[spineIndex] = makePreloadTask(spineIndex: spineIndex, generation: generation)
    }

    func cancelPendingWork() {
        AppLogger.render("[FlipTrace] cancelPendingWork generation=\(layoutGeneration) pending=\(preloadTasks.keys.sorted()) layouts=\(_layouts.keys.sorted())")
        layoutGeneration += 1
        cancelPreloadTasks()
    }

    func pageViewController(at index: Int) -> UIViewController {
        let (spineIndex, localPage) = localPosition(for: index)
        // A partial layout only carries its leading page(s); later pages fall
        // through to the placeholder path until full pagination replaces it.
        if let layout = _layouts[spineIndex], localPage < layout.pageRanges.count {
            AppLogger.render("[FlipTrace] pageVC REAL page=\(index) spine=\(spineIndex) local=\(localPage) pages=\(layout.pageRanges.count)")
            return configuredPageViewController(
                layout: layout,
                spineIndex: spineIndex,
                localPage: localPage,
                globalPage: index
            )
        }
        let title = chapterTitle(at: spineIndex)
        let readingPosition = placeholderReadingPosition(
            spineIndex: spineIndex,
            localPage: localPage,
            globalPage: index
        )
        AppLogger.render("[FlipTrace] pageVC PLACEHOLDER page=\(index) spine=\(spineIndex) local=\(localPage) layouts=\(_layouts.keys.sorted()) pending=\(preloadTasks.keys.sorted())")
        let placeholder = PlaceholderPageViewController(
            chapterTitle: title,
            globalPage: index,
            readingPosition: readingPosition,
            themeBackgroundColor: themeBackgroundColor,
            themeTextColor: themeTextColor
        )
        Task { [weak self] in
            guard let self else { return }
            await self.preloadChapter(at: spineIndex)
            guard _layouts[spineIndex] != nil else { return }
            self.onChapterReady?(spineIndex)
        }
        return placeholder
    }

    /// Character offset of an anchor (`id`/fragment) within a spine, if that spine is laid out.
    /// Returns nil when the spine hasn't been paginated yet or the anchor is unknown, letting
    /// callers fall back to the spine start.
    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int? {
        _layouts[spineIndex]?.anchorOffsets[fragment]
    }

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        guard spinePageOffsets.indices.contains(spineIndex) else { return 0 }
        if let layout = _layouts[spineIndex] {
            let localPage = layout.pageIndex(for: charOffset)
            return spinePageOffsets[spineIndex] + localPage
        } else {
            // Rough estimate when not yet loaded: ~400 characters per page (conservative)
            let estimatedLocal = max(0, charOffset / 400)
            return spinePageOffsets[spineIndex] + estimatedLocal
        }
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        // While a chapter is only partially paginated, offsets beyond the covered
        // range (including .chapterEnd's .max) cannot be resolved yet — return
        // nil so callers take the placeholder path and wait for the full layout.
        if let layout = _layouts[position.spineIndex], layout.isPartial {
            let coveredEnd = layout.pageRanges.last.map { Int($0.location + $0.length) } ?? 0
            if position.charOffset >= coveredEnd { return nil }
        }
        return CoreTextReadingPositionMapper.pageIndex(
            for: position,
            layouts: layouts,
            spinePageOffsets: spinePageOffsets
        )
    }

    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = _layouts[spineIndex],
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
        guard let layout = _layouts[spineIndex],
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
            AppLogger.render("[FlipTrace] positionVC exact position=\(position) page=\(globalPage)")
            return pageViewController(at: globalPage)
        }

        let title = chapterTitle(at: position.spineIndex)
        let estimated = estimatedGlobalPage(for: position) ?? 0
        AppLogger.render("[FlipTrace] positionVC PLACEHOLDER position=\(position) estimated=\(estimated) layouts=\(_layouts.keys.sorted()) pending=\(preloadTasks.keys.sorted())")
        let placeholder = PlaceholderPageViewController(
            chapterTitle: title,
            globalPage: estimated,
            readingPosition: position,
            themeBackgroundColor: themeBackgroundColor,
            themeTextColor: themeTextColor
        )
        Task { [weak self] in
            guard let self else { return }
            await self.preloadChapter(at: position.spineIndex)
            guard _layouts[position.spineIndex] != nil else { return }
            self.onChapterReady?(position.spineIndex)
        }
        return placeholder
    }

    func preloadChapter(at spineIndex: Int) async {
        guard (0..<chapterCount).contains(spineIndex) else { return }
        // A partial (first-page-only) layout does not count as loaded: callers
        // of this method need the FULL pagination (restore, link resolution …).
        if let existing = _layouts[spineIndex], !existing.isPartial {
            AppLogger.render("[FlipTrace] preload skip loaded spine=\(spineIndex) layouts=\(_layouts.keys.sorted())")
            return
        }
        if let existing = preloadTasks[spineIndex] {
            AppLogger.render("[FlipTrace] preload await existing spine=\(spineIndex) generation=\(layoutGeneration)")
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
        AppLogger.render("[FetchTrace] engine.notifyChapterDataChanged enter ch=\(spineIndex)")

        // 1. Clear the old layout and any in-progress preload task
_layouts[spineIndex] = nil
        preloadTasks[spineIndex]?.cancel()
        preloadTasks[spineIndex] = nil
        chapterSnapshots.removeObject(forKey: NSNumber(value: spineIndex))

        // 2. Incrementally update the chapter's byte size (O(1), no full rescan)
        let size = await attributedBuilder.chapterDataSize(at: spineIndex)
        if spineIndex < chapterByteSizes.count {
            chapterByteSizes[spineIndex] = size
        } else if chapterByteSizes.count == spineIndex {
            chapterByteSizes.append(size)
        }
        if !attributedBuilder.prefersLazyByteScan {
            contentUnitMap = ReaderContentUnitMap(chapterUnitCounts: chapterByteSizes)
        }

        // 3. Reload the chapter (preloadChapter checks layouts[spineIndex] == nil before executing)
        await preloadChapter(at: spineIndex)

        // 4. Notify ReaderView to refresh:
        //    - layoutOK=true → swap to the VC with the new layout, showing actual content
        //    - layoutOK=false → swap to PlaceholderVC (loading UI), so refresh can immediately
        //      clear old content and show loading, then notifyChapterDataChanged again once refetch completes.
        let layoutOK = layouts[spineIndex] != nil
        AppLogger.render("[FetchTrace] engine.notifyChapterDataChanged done ch=\(spineIndex) layoutOK=\(layoutOK) hasCallback=\(onChapterReady != nil)")
        onChapterReady?(spineIndex)
    }

    /// Chapters at or above this UTF-16 length take the two-phase path: a fast
    /// first-page pass is installed (and shown) while full pagination continues
    /// in the background. Short chapters paginate fully in one pass.
    private static let partialFirstPageThreshold = 20_000

    private func preloadChapterInternal(at spineIndex: Int, generation: Int) async {
        guard (0..<chapterCount).contains(spineIndex),
              _layouts[spineIndex]?.isPartial != false else { return }
        guard !shouldAbortPreload(generation: generation) else { return }
        AppLogger.render("[FlipTrace] preload begin spine=\(spineIndex) generation=\(generation) layouts=\(_layouts.keys.sorted())")

        guard let buildResult = try? await attributedBuilder.buildChapter(
            at: spineIndex,
            settings: renderSettings,
            themeTextColor: themeTextColor,
            themeBackgroundColor: themeBackgroundColor
        ) else {
            AppLogger.render("[CoreTextEngine] preloadChapter[\(spineIndex)] FAILED to build attributed string")
            return
        }
        guard !shouldAbortPreload(generation: generation) else { return }

        let request = PaginationRequest(
            spineIndex: spineIndex,
            attributedString: buildResult.attributedString,
            imagePage: buildResult.imagePage,
            pageBackgroundImage: buildResult.pageBackgroundImage,
            pageBackgroundColor: buildResult.pageBackgroundColor,
            anchorOffsets: buildResult.anchorOffsets,
            renderSize: renderSize,
            fontSize: renderSettings.fontSize,
            lineSpacing: renderSettings.lineSpacing,
            paragraphSpacing: renderSettings.paragraphSpacing,
            letterSpacing: renderSettings.letterSpacing,
            contentInsets: currentContentInsets(),
            writingMode: renderSettings.writingMode
        )

        // Two-phase open for long chapters (Legado TextChapterLayout idea): lay
        // out and publish page 1 immediately, then let the full pass replace it.
        let firstPageStart = ProcessInfo.processInfo.systemUptime
        if buildResult.attributedString.length >= Self.partialFirstPageThreshold,
           _layouts[spineIndex] == nil,
           let firstPageResult = await paginationManager.paginateFirstPage(request) {
            guard !shouldAbortPreload(generation: generation) else { return }
            let firstPageLayout = firstPageResult.layout.withUpdatedAppearance(
                textColor: themeTextColor,
                backgroundColor: themeBackgroundColor,
                readerBackgroundImage: currentReaderBackgroundImage(),
                dialogueColor: renderSettings.dialogueHighlightColor,
                dialogueBoxColor: renderSettings.dialogueBoxColor
            )
            _layouts[spineIndex] = firstPageLayout
            generateSnapshot(for: spineIndex)
            rebuildPageOffsets()
            if firstPageLayout.isPartial {
                SourcePerfTrace.record(
                    "coreText.firstPage", "spine=\(spineIndex)", since: firstPageStart
                )
                AppLogger.render("[FlipTrace] preload partial spine=\(spineIndex) estPages=\(firstPageLayout.displayPageCount) generation=\(generation)")
                onChapterReady?(spineIndex)
            } else {
                // Paginator cache hit — the layout is already complete.
                AppLogger.render("[FlipTrace] preload done spine=\(spineIndex) pages=\(firstPageLayout.pageRanges.count) generation=\(generation) source=cache")
                return
            }
        }

        let fullLayoutStart = ProcessInfo.processInfo.systemUptime
        let layout = await paginationManager.paginate(request).layout
        guard !shouldAbortPreload(generation: generation) else { return }
        SourcePerfTrace.record(
            "coreText.fullLayout",
            "spine=\(spineIndex) chars=\(buildResult.attributedString.length)",
            since: fullLayoutStart
        )

        _layouts[spineIndex] = layout.withUpdatedAppearance(
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor,
            readerBackgroundImage: currentReaderBackgroundImage(),
            dialogueColor: renderSettings.dialogueHighlightColor,
            dialogueBoxColor: renderSettings.dialogueBoxColor
        )
        AppLogger.render("[FlipTrace] preload done spine=\(spineIndex) pages=\(layout.pageRanges.count) generation=\(generation) layouts=\(_layouts.keys.sorted())")
        generateSnapshot(for: spineIndex)
        rebuildPageOffsets()
    }

    func invalidateLayout(newSize: CGSize) async {
        AppLogger.render("[FlipTrace] invalidateLayout newSize=\(newSize) oldSize=\(renderSize) loaded=\(_layouts.keys.sorted()) pending=\(preloadTasks.keys.sorted())")
        let restorePosition = readingPosition(forPage: currentPage)
        cancelPendingWork()
        isRelaying = true
        renderSize = newSize
        updateBuilderRenderSize(newSize)
        paginationManager.invalidate(reason: .viewSizeChanged)

        // Only re-layout chapters currently held in memory
        let loadedSpines = Array(_layouts.keys.sorted())
_layouts.removeAll()
        chapterSnapshots.removeAllObjects()

        await withTaskGroup(of: Void.self) { group in
            for i in loadedSpines {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }

        // Byte size rescan not needed (unaffected by font size changes)
        // Restore the in-memory location after re-pagination; do not read disk.
        if let restorePosition,
           let resolved = pageIndex(for: restorePosition) {
            currentPage = resolved
            onNavigateToPage?(resolved)
        } else {
            currentPage = max(0, min(currentPage, max(totalPages - 1, 0)))
        }
        isRelaying = false
        onChapterReady?(nil)
    }

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? {
        // Ignore special Kindle / device-specific links that can't be resolved to EPUB content
        if href.hasPrefix("kindle:") { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let targetSpine: Int
        if rawPath.isEmpty {
            targetSpine = spineIndex
        } else {
            let resolvedHref = EPUBStyleResolver.resolveImageHref(rawPath, chapterHref: chapterSourceHref(at: spineIndex))
            guard let matchedIndex = chapterIndex(for: resolvedHref) ?? chapterIndex(for: rawPath) else {
                AppLogger.render("⟐ link.resolve noChapter spine=\(spineIndex) raw=\(rawPath.prefix(80)) resolved=\(resolvedHref.prefix(96))")
                return nil
            }
            targetSpine = matchedIndex
        }

        await preloadChapter(at: targetSpine)
        guard let layout = _layouts[targetSpine] else { return nil }
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

        // Evict distant chapters on page turn
        evictDistantChapters(currentSpine: spineIndex)

        guard let layout = _layouts[spineIndex] else {
            AppLogger.render("[FlipTrace] warmUp skip missingCurrent page=\(currentGlobalPage) spine=\(spineIndex) local=\(localPage) layouts=\(_layouts.keys.sorted())")
            return
        }
        let total = layout.displayPageCount
        // Trigger at 20% remaining (minimum 3 pages) so snapshot is ready before chapter boundary
        let threshold = max(3, Int(Double(total) * 0.20))
        let remaining = total - localPage
        AppLogger.render("[FlipTrace] warmUp page=\(currentGlobalPage) spine=\(spineIndex) local=\(localPage) total=\(total) remaining=\(remaining) threshold=\(threshold) layouts=\(_layouts.keys.sorted())")
        if remaining <= threshold {
            let nextSpine = spineIndex + 1
            if nextSpine < chapterCount {
                schedulePreloadChapter(at: nextSpine)
            }
        }
        // Preload previous chapter when near the beginning, so backward cross-chapter navigation can correctly locate the last page
        if localPage < threshold && spineIndex > 0 && layouts[spineIndex - 1] == nil {
            schedulePreloadChapter(at: spineIndex - 1)
        }
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        let (spineIndex, localPage) = localPosition(for: index)
        // Snapshots are only used for chapter boundary handoff. Page 0 key is (spineIndex << 1)
        guard localPage == 0 else {
            AppLogger.render("[FlipTrace] snapshotVC MISS nonFirstPage page=\(index) spine=\(spineIndex) local=\(localPage)")
            return nil
        }
        let key = NSNumber(value: (spineIndex << 1))
        guard let snapshot = chapterSnapshots.object(forKey: key) else {
            AppLogger.render("[FlipTrace] snapshotVC MISS noSnapshot page=\(index) spine=\(spineIndex) key=\(key) layouts=\(_layouts.keys.sorted())")
            return nil
        }
        AppLogger.render("[FlipTrace] snapshotVC HIT page=\(index) spine=\(spineIndex) key=\(key)")
        let bgColor = _layouts[spineIndex]?.backgroundColor ?? .systemBackground
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
        let readerBackgroundImage = currentReaderBackgroundImage()
        // Color changes don't affect line breaking; directly update attributedString + framesetter synchronously, preserving all blockAttachments etc.
        for spineIndex in _layouts.keys {
            _layouts[spineIndex] = _layouts[spineIndex]?.withUpdatedAppearance(
                textColor: textColor,
                backgroundColor: backgroundColor,
                readerBackgroundImage: readerBackgroundImage,
                dialogueColor: renderSettings.dialogueHighlightColor,
                dialogueBoxColor: renderSettings.dialogueBoxColor
            )
        }
        chapterSnapshots.removeAllObjects()
        onChapterReady?(nil)
        // Rebuild chapter boundary snapshots in the background (for cross-chapter animation)
        for spineIndex in _layouts.keys {
            generateSnapshot(for: spineIndex)
        }
    }

    /// Offscreen renders any global page as a UIImage for use as an immediate snapshot during cover animation.
    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        let (spineIndex, localPage) = localPosition(for: globalPage)
        guard let layout = _layouts[spineIndex] else {
            AppLogger.render("[FlipTrace] renderSnapshot MISS noLayout page=\(globalPage) spine=\(spineIndex) local=\(localPage) layouts=\(_layouts.keys.sorted())")
            return nil
        }
        guard localPage < layout.pageRanges.count else {
            AppLogger.render("[FlipTrace] renderSnapshot MISS pageOutOfRange page=\(globalPage) spine=\(spineIndex) local=\(localPage) pages=\(layout.pageRanges.count)")
            return nil
        }
        guard renderSize.width > 0, renderSize.height > 0 else {
            AppLogger.render("[FlipTrace] renderSnapshot MISS invalidSize page=\(globalPage) spine=\(spineIndex) size=\(renderSize)")
            return nil
        }
        
        // Prefer the boundary cache (Key: (spine << 1) | isLastPage)
        let isLastPage = localPage == (layout.pageRanges.count - 1)
        if localPage == 0 || isLastPage {
            let key = NSNumber(value: (spineIndex << 1) | (isLastPage ? 1 : 0))
            if let cached = chapterSnapshots.object(forKey: key) {
                AppLogger.render("[FlipTrace] renderSnapshot HIT cached page=\(globalPage) spine=\(spineIndex) local=\(localPage) key=\(key)")
                return cached
            }
        }
        AppLogger.render("[FlipTrace] renderSnapshot render page=\(globalPage) spine=\(spineIndex) local=\(localPage)")
        
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

    /// Pre-renders the first and last pages of a chapter as UIImages, stored in chapterSnapshots for cross-chapter animation handoff.
    /// Uses Task.detached to render on a background thread, avoiding main thread blocking.
    private func generateSnapshot(for spineIndex: Int) {
        guard let layout = _layouts[spineIndex],
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
        
        // Convert UIColor to CGColor for passing in non-isolated context
        let bgCGColor = bgColor.cgColor
        
        // First page snapshot (Key: (spine << 1))
        let firstKey = NSNumber(value: (spineIndex << 1))
        if chapterSnapshots.object(forKey: firstKey) == nil {
            Task {
                let img = await Task.detached(priority: .userInitiated) {
                    Self.renderImage(layout: layout, pageIndex: 0, size: size, bgColor: bgCGColor)
                }.value
                self.chapterSnapshots.setObject(img, forKey: firstKey, cost: Self.imageCost(img))
            }
        }

        // Last page snapshot (Key: (spine << 1) | 1)
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

    /// Returns the global page index of the last page of the specified chapter.
    /// Returns nil if the chapter is not loaded — or only partially paginated,
    /// since the real last page is unknown until the full pass completes.
    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        guard let layout = _layouts[spineIndex],
              !layout.isPartial,
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

        // Estimate bytes per page, scaled by font size so totalPages tracks layout changes.
        // At 20pt CJK, ~600 bytes/page. Larger font → fewer chars per page → fewer bytes per page.
        let baseFontSize: CGFloat = 20
        let referenceBytesPerPage: CGFloat = 600
        let scale = baseFontSize / max(1, renderSettings.fontSize)
        let avgBytesPerPage = max(100, Int(referenceBytesPerPage * scale * scale)) 

        spinePageOffsets = (0..<chapterCount).map { i in
            let start = offset
            if let layout = _layouts[i] {
                // displayPageCount: real count when complete, extrapolated
                // estimate while the chapter is still partially paginated.
                offset += layout.displayPageCount
            } else if i < chapterByteSizes.count && chapterByteSizes[i] > 0 {
                // Estimate page count from byte size
                offset += max(1, chapterByteSizes[i] / avgBytesPerPage)
            } else {
                // Without layout or byte info, estimate 1 page to keep spinePageOffsets and totalPages from breaking
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
            // duokan popup footnote: show the note in place instead of paging to the chapter tail.
            if let note = FootnoteStore.text(spineIndex: spineIndex, href: href) {
                self.onFootnoteTap?(note)
                return
            }
            Task { @MainActor in
                if let url = Self.externalURL(from: href) {
                    await UIApplication.shared.open(url)
                    return
                }
                guard let targetPage = await self.resolveInternalLink(href, fromSpineIndex: spineIndex) else {
                    AppLogger.render("⟐ link.tap unresolved spine=\(spineIndex) href=\(href.prefix(96))")
                    return
                }
                AppLogger.render("⟐ link.tap page=\(targetPage) href=\(href.prefix(64))")
                (self.onLinkNavigate ?? self.onNavigateToPage)?(targetPage)
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
        vc.setTextAnnotations(textAnnotations.filter { $0.spineIndex == spineIndex })
        return vc
    }

    private static func externalURL(from href: String) -> URL? {
        guard let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int? {
        guard spinePageOffsets.indices.contains(position.spineIndex) else { return nil }
        let chapterStart = spinePageOffsets[position.spineIndex]
        if let layout = _layouts[position.spineIndex] {
            let localPage = layout.pageIndex(
                for: CoreTextReadingPositionMapper.clampedCharOffset(for: position, in: layout)
            )
            return chapterStart + localPage
        }
        if position.charOffset == .max {
            return chapterStart + max(0, estimatedPageCount(forChapter: position.spineIndex) - 1)
        }
        let estimatedLocal = max(0, position.charOffset / 400)
        return chapterStart + min(estimatedLocal, max(0, estimatedPageCount(forChapter: position.spineIndex) - 1))
    }

    private func estimatedPageCount(forChapter spineIndex: Int) -> Int {
        guard spinePageOffsets.indices.contains(spineIndex) else { return 1 }
        if let layout = _layouts[spineIndex] {
            return max(1, layout.displayPageCount)
        }
        if spineIndex + 1 < spinePageOffsets.count {
            return max(1, spinePageOffsets[spineIndex + 1] - spinePageOffsets[spineIndex])
        }
        return max(1, totalPages - spinePageOffsets[spineIndex])
    }

    private func placeholderReadingPosition(
        spineIndex: Int,
        localPage: Int,
        globalPage: Int
    ) -> CoreTextReadingPosition? {
        if localPage == 0 {
            return .chapterStart(spineIndex)
        }
        let estimatedLastPage = spinePageOffsets.indices.contains(spineIndex)
            ? spinePageOffsets[spineIndex] + max(0, estimatedPageCount(forChapter: spineIndex) - 1)
            : globalPage
        if globalPage >= estimatedLastPage {
            return .chapterEnd(spineIndex)
        }
        return nil
    }

    private func currentContentInsets() -> UIEdgeInsets {
        renderSettings.contentInsets
    }

    private func updateBuilderRenderSize(_ size: CGSize) {
        (attributedBuilder as? RenderSizeAwareAttributedStringBuilding)?.updateRenderSize(size)
    }

    /// Returns appropriate text color. GlobalSettings does not expose a theme enum,
    /// so we fall back to the system adaptive label color which respects dark/light mode.
    private func currentTextColor() -> UIColor { themeTextColor }
    private func currentBackgroundColor() -> UIColor { themeBackgroundColor }


    /// Returns the plain text content of a page (for TTS / bookmark excerpt use)
    func plainText(forPage page: Int) -> String {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = _layouts[spineIndex],
              localPage < layout.pageRanges.count else { return "" }
        let range = layout.pageRanges[localPage]
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location != NSNotFound, nsRange.length > 0,
              nsRange.location + nsRange.length <= layout.attributedString.length else { return "" }
        return (layout.attributedString.string as NSString).substring(with: nsRange)
    }

}
