import UIKit
import CoreText
import ReadiumShared

@MainActor
final class TXTPageEngine: PageRenderingProvider {
    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0

    private(set) var layouts: [Int: CoreTextPaginator.ChapterLayout] = [:]
    private var chapterSnapshots: [Int: UIImage] = [:]
    private var spinePageOffsets: [Int] = []
    private(set) var renderSize: CGSize = .zero
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var layoutGeneration: Int = 0

    let offsetStore: CharOffsetStore
    private let paginationManager = PaginationManager()
    private let attributedBuilder: any AttributedStringBuilding
    let bookTitle: String
    private var currentBookId: String?
    
    private var themeTextColor: UIColor = .label
    private var themeBackgroundColor: UIColor = .systemBackground
    private var renderSettings: ReaderRenderSettings
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?

    init(text: String, title: String, offsetStore: CharOffsetStore, settings: ReaderRenderSettings) {
        self.bookTitle = title
        self.offsetStore = offsetStore
        let chapters = TXTChapterParser.parseUnifiedChapters(text, bookTitle: title)
        if GlobalSettings.shared.useRenderableNodePipeline {
            self.attributedBuilder = NodeAttributedStringBuilder(chapters: chapters)
        } else {
            self.attributedBuilder = TXTAttributedStringBuilder(chapters: chapters)
        }
        self.renderSettings = settings
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        self.renderSettings = settings
    }

    private var chapterCount: Int { attributedBuilder.chapterCount }

    var chapterTitles: [String] {
        (0..<chapterCount).map { attributedBuilder.chapterTitle(at: $0) }
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

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        self.themeTextColor = textColor
        self.themeBackgroundColor = backgroundColor
        for spineIndex in layouts.keys {
            layouts[spineIndex] = layouts[spineIndex]?.withUpdatedColors(textColor: textColor, backgroundColor: backgroundColor)
        }
        chapterSnapshots.removeAll()
        onChapterReady?(nil)
        for spineIndex in layouts.keys {
            if let layout = layouts[spineIndex] {
                Task { [weak self] in
                    guard let self else { return }
                    self.chapterSnapshots[spineIndex] = self.renderImage(layout: layout, pageIndex: 0)
                }
            }
        }
    }

    func start(renderSize: CGSize, bookId: String) async {
        self.renderSize = renderSize
        self.currentBookId = bookId
        
        var startSpine = 0
        var startCharOffset = 0
        if let record = offsetStore.load(bookId: bookId) {
            startSpine = record.spineIndex
            startCharOffset = record.charOffset
        }
        
        await preloadChapter(at: startSpine)
        if startSpine > 0 { schedulePreloadChapter(at: startSpine - 1) }
        if startSpine < chapterCount - 1 { schedulePreloadChapter(at: startSpine + 1) }
        
        self.currentPage = pageIndex(forSpine: startSpine, charOffset: startCharOffset)
        onChapterReady?(startSpine)
    }

    func pageViewController(at index: Int) -> UIViewController {
        let (spineIndex, localPage) = localPosition(for: index)
        if let layout = layouts[spineIndex] {
            let vc = CoreTextPageViewController()
            let readingPosition = CoreTextReadingPosition(spineIndex: spineIndex, charOffset: Int(layout.pageRanges[localPage].location))
            vc.configure(
                layout: layout,
                localPage: localPage,
                globalPage: index,
                readingPosition: readingPosition,
                fallbackBackgroundColor: themeBackgroundColor
            )
            return vc
        }
        
        let title = (0..<chapterCount).contains(spineIndex)
            ? attributedBuilder.chapterTitle(at: spineIndex)
            : ""
        let estimatedGlobalPage = (spinePageOffsets.indices.contains(spineIndex) ? spinePageOffsets[spineIndex] : 0) + localPage
        let position = CoreTextReadingPosition(spineIndex: spineIndex, charOffset: 0)
        let placeholder = PlaceholderPageViewController(
            chapterTitle: title,
            globalPage: estimatedGlobalPage,
            readingPosition: position
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
        guard spinePageOffsets.indices.contains(spineIndex),
              let layout = layouts[spineIndex] else { return 0 }
        let localPage = layout.pageIndex(for: charOffset)
        return spinePageOffsets[spineIndex] + localPage
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        let (spine, local) = localPosition(for: page)
        guard let layout = layouts[spine], local < layout.pageRanges.count else { return (spine, 0) }
        return (spine, Int(layout.pageRanges[local].location))
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
            return .chapterStart(spineIndex)
        }
        return CoreTextReadingPosition(
            spineIndex: spineIndex,
            charOffset: Int(layout.pageRanges[localPage].location)
        )
    }

    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        guard (0..<chapterCount).contains(position.spineIndex) else {
            return pageViewController(at: 0)
        }
        if let globalPage = pageIndex(for: position) {
            return pageViewController(at: globalPage)
        }
        let title = attributedBuilder.chapterTitle(at: position.spineIndex)
        let estimatedGlobalPage = spinePageOffsets.indices.contains(position.spineIndex)
            ? spinePageOffsets[position.spineIndex] : 0
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

    private func preloadChapterInternal(at spineIndex: Int, generation: Int) async {
        guard (0..<chapterCount).contains(spineIndex), layouts[spineIndex] == nil else { return }
        guard !shouldAbortPreload(generation: generation) else { return }

        guard let buildResult = try? await attributedBuilder.buildChapter(
            at: spineIndex,
            settings: renderSettings,
            themeTextColor: themeTextColor,
            themeBackgroundColor: themeBackgroundColor
        ) else { return }
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
            contentInsets: renderSettings.contentInsets
        )
        let layout = await paginationManager.paginate(request).layout
        guard !shouldAbortPreload(generation: generation) else { return }
        
        layouts[spineIndex] = layout.withUpdatedColors(textColor: themeTextColor, backgroundColor: themeBackgroundColor)
        if let l = layouts[spineIndex], !l.pageRanges.isEmpty {
            chapterSnapshots[spineIndex] = renderImage(layout: l, pageIndex: 0)
        }
        rebuildPageOffsets()
    }

    func invalidateLayout(newSize: CGSize) async {
        cancelPendingWork()
        renderSize = newSize
        let currentRecord = CharOffsetRecord(bookId: currentBookId ?? "", spineIndex: charOffset(forPage: currentPage).spineIndex, charOffset: charOffset(forPage: currentPage).charOffset, timestamp: Date())
        
        layouts.removeAll()
        chapterSnapshots.removeAll()
        rebuildPageOffsets()
        
        await preloadChapter(at: currentRecord.spineIndex)
        currentPage = pageIndex(forSpine: currentRecord.spineIndex, charOffset: currentRecord.charOffset)
        onChapterReady?(currentRecord.spineIndex)
    }

    func warmUpNext(currentGlobalPage: Int) {
        let (spine, local) = localPosition(for: currentGlobalPage)

        guard chapterCount > 0 else { return }
        let keep = Set(max(0, spine - 1)...min(spine + 1, chapterCount - 1))
        for key in layouts.keys where !keep.contains(key) {
            layouts.removeValue(forKey: key)
            chapterSnapshots.removeValue(forKey: key)
        }
        rebuildPageOffsets()

        guard let layout = layouts[spine] else { return }
        let total = layout.pageRanges.count
        let threshold = max(3, Int(Double(total) * 0.20))

        if total - local <= threshold, spine + 1 < chapterCount, layouts[spine + 1] == nil {
            schedulePreloadChapter(at: spine + 1)
        }
        if local < threshold, spine > 0, layouts[spine - 1] == nil {
            schedulePreloadChapter(at: spine - 1)
        }
    }

    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        guard let layout = layouts[spineIndex], spinePageOffsets.indices.contains(spineIndex) else { return nil }
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
        return (lo, max(0, globalPage - spinePageOffsets[lo]))
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        let (spine, local) = localPosition(for: index)
        guard local == 0, let image = chapterSnapshots[spine] else { return nil }
        let pos = CoreTextReadingPosition(spineIndex: spine, charOffset: 0)
        return SnapshotPageViewController(
            image: image,
            globalPage: index,
            backgroundColor: themeBackgroundColor,
            readingPosition: pos
        )
    }

    func plainText(forPage page: Int) -> String {
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count else { return "" }
        let range = layout.pageRanges[localPage]
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location + nsRange.length <= layout.attributedString.length else { return "" }
        return layout.attributedString.attributedSubstring(from: nsRange).string
    }

    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        guard chapterCount > 0 else { return 0 }

        let clampedSpine = max(0, min(spineIndex, chapterCount - 1))
        let baseProgress = Double(clampedSpine) / Double(chapterCount)

        let chapterCharLength = layouts[clampedSpine]?.attributedString.length ?? 1
        let safeOffset = max(0, min(charOffset, chapterCharLength))
        let chapterFraction = Double(safeOffset) / Double(max(chapterCharLength, 1))

        return min(1.0, max(0.0, baseProgress + (chapterFraction / Double(chapterCount))))
    }

    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        guard chapterCount > 0 else { return (0, 0) }
        let targetIndex = Int(progress * Double(chapterCount - 1))
        let clamped = max(0, min(targetIndex, chapterCount - 1))
        return (clamped, 0)
    }

    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        let (spine, local) = localPosition(for: globalPage)
        guard let layout = layouts[spine], local < layout.pageRanges.count, renderSize.width > 0 else { return nil }
        return renderImage(layout: layout, pageIndex: local)
    }

    private func renderImage(layout: CoreTextPaginator.ChapterLayout, pageIndex: Int) -> UIImage {
        let size = renderSize
        let bgColor = themeBackgroundColor
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(bgColor.cgColor)
            c.fill(CGRect(origin: .zero, size: size))
            CoreTextPageView.renderPage(layout: layout, pageIndex: pageIndex, in: c, bounds: CGRect(origin: .zero, size: size))
        }
    }

    private func rebuildPageOffsets() {
        let anchoredPosition = readingPosition(forPage: currentPage) ?? .chapterStart(0)
        let oldOffsets = spinePageOffsets
        var offset = 0
        spinePageOffsets = (0..<chapterCount).map { i in
            let start = offset
            offset += layouts[i]?.pageRanges.count ?? 1
            return start
        }
        totalPages = offset
        if let correctedPage = pageIndex(for: anchoredPosition) {
            currentPage = max(0, min(correctedPage, max(totalPages - 1, 0)))
        }
        if !oldOffsets.isEmpty, oldOffsets != spinePageOffsets {
            onChapterReady?(nil)
        }
    }
}
