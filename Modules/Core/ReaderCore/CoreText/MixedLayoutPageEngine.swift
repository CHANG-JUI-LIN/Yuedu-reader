import UIKit

@MainActor
final class MixedLayoutPageEngine: PageRenderingProvider, ReaderContentInteractionRouting {
    enum Slot: Equatable {
        case reflowable(spineIndex: Int, localPage: Int, charOffset: Int)
        case fixed(spineIndex: Int)

        var spineIndex: Int {
            switch self {
            case .reflowable(let spineIndex, _, _), .fixed(let spineIndex):
                return spineIndex
            }
        }

        var charOffset: Int {
            switch self {
            case .reflowable(_, _, let charOffset): return charOffset
            case .fixed: return 0
            }
        }
    }

    private let session: PublicationSession
    private let reflowEngine: CoreTextPageEngine
    private let fixedEngine: FixedLayoutPageEngine
    private var slots: [Slot] = []

    private(set) var currentPage: Int = 0
    var totalPages: Int { slots.count }
    var layouts: [Int: CoreTextPaginator.ChapterLayout] {
        reflowEngine.layouts.filter {
            effectiveLayout(at: $0.key) == .reflowable
        }
    }
    var renderSize: CGSize { reflowEngine.renderSize }
    var offsetStore: CharOffsetStore { reflowEngine.offsetStore }
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?
    var onLinkNavigate: ((Int) -> Void)?
    var onFootnoteTap: ((String) -> Void)? {
        didSet { reflowEngine.onFootnoteTap = onFootnoteTap }
    }

    init(
        session: PublicationSession,
        reflowEngine: CoreTextPageEngine,
        fixedEngine: FixedLayoutPageEngine
    ) {
        self.session = session
        self.reflowEngine = reflowEngine
        self.fixedEngine = fixedEngine
        rebuildSlots()

        reflowEngine.onChapterReady = { [weak self] spineIndex in
            guard let self else { return }
            rebuildSlots()
            onChapterReady?(spineIndex)
        }
        fixedEngine.onChapterReady = { [weak self] spineIndex in
            guard let self else { return }
            rebuildSlots()
            onChapterReady?(spineIndex)
        }
        reflowEngine.onNavigateToPage = { [weak self, weak reflowEngine] childPage in
            guard let self, let position = reflowEngine?.readingPosition(forPage: childPage),
                  let page = pageIndex(for: position) else { return }
            currentPage = page
            onNavigateToPage?(page)
        }
        reflowEngine.onLinkNavigate = { [weak self, weak reflowEngine] childPage in
            guard let self, let position = reflowEngine?.readingPosition(forPage: childPage),
                  let page = pageIndex(for: position) else { return }
            currentPage = page
            (onLinkNavigate ?? onNavigateToPage)?(page)
        }
    }

    func start(renderSize: CGSize, bookId: String) async {
        await reflowEngine.start(renderSize: renderSize, bookId: bookId)
        await fixedEngine.start(renderSize: renderSize, bookId: bookId)
        rebuildSlots()
        onChapterReady?(nil)
    }

    func preloadChapter(at spineIndex: Int) async {
        guard session.chapters.indices.contains(spineIndex) else { return }
        if effectiveLayout(at: spineIndex) == .prePaginated {
            await fixedEngine.preloadChapter(at: spineIndex)
        } else {
            await reflowEngine.preloadChapter(at: spineIndex)
        }
        rebuildSlots()
        onChapterReady?(spineIndex)
    }

    func invalidateLayout(newSize: CGSize) async {
        let position = readingPosition(forPage: currentPage)
        await reflowEngine.invalidateLayout(newSize: newSize)
        await fixedEngine.invalidateLayout(newSize: newSize)
        rebuildSlots()
        if let position, let page = estimatedGlobalPage(for: position) {
            currentPage = page
            onNavigateToPage?(page)
        }
        onChapterReady?(nil)
    }

    func warmUpNext(currentGlobalPage: Int) {
        guard slots.isEmpty == false else { return }
        let page = max(0, min(currentGlobalPage, slots.count - 1))
        let neighboringSpines = Set(
            [page - 1, page + 1]
                .filter { slots.indices.contains($0) }
                .map { slots[$0].spineIndex }
        )
        for spineIndex in neighboringSpines {
            Task { [weak self] in
                await self?.preloadChapter(at: spineIndex)
            }
        }
    }

    func cancelPendingWork() {
        reflowEngine.cancelPendingWork()
        fixedEngine.cancelPendingWork()
    }

    func notifyChapterDataChanged(at spineIndex: Int) async {
        guard session.chapters.indices.contains(spineIndex) else { return }
        if effectiveLayout(at: spineIndex) == .prePaginated {
            await fixedEngine.notifyChapterDataChanged(at: spineIndex)
        } else {
            await reflowEngine.notifyChapterDataChanged(at: spineIndex)
        }
        rebuildSlots()
        onChapterReady?(spineIndex)
    }

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        pageIndex(for: CoreTextReadingPosition(
            spineIndex: spineIndex,
            charOffset: charOffset
        )) ?? firstPage(of: spineIndex) ?? 0
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        guard session.chapters.indices.contains(position.spineIndex) else { return nil }
        if effectiveLayout(at: position.spineIndex) == .prePaginated {
            return firstPage(of: position.spineIndex)
        }
        guard let layout = layouts[position.spineIndex] else { return nil }
        let charOffset = CoreTextReadingPositionMapper.clampedCharOffset(
            for: position,
            in: layout
        )
        let localPage = layout.pageIndex(for: charOffset)
        return slots.firstIndex {
            if case .reflowable(position.spineIndex, localPage, _) = $0 { return true }
            return false
        }
    }

    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int? {
        if let exact = pageIndex(for: position) { return exact }
        if position.charOffset == .max {
            return lastPageIndex(ofChapter: position.spineIndex)
        }
        return firstPage(of: position.spineIndex)
    }

    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        guard let slot = slot(at: page) else { return nil }
        return CoreTextReadingPosition(
            spineIndex: slot.spineIndex,
            charOffset: slot.charOffset
        )
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        guard let slot = slot(at: page) else { return (0, 0) }
        return (slot.spineIndex, slot.charOffset)
    }

    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int? {
        guard effectiveLayout(at: spineIndex) == .reflowable else { return nil }
        return reflowEngine.charOffset(forSpine: spineIndex, fragment: fragment)
    }

    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
        guard let slot = slot(at: globalPage) else { return (0, 0) }
        switch slot {
        case .fixed(let spineIndex): return (spineIndex, 0)
        case .reflowable(let spineIndex, let localPage, _): return (spineIndex, localPage)
        }
    }

    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        slots.lastIndex { $0.spineIndex == spineIndex }
    }

    func plainText(forPage page: Int) -> String {
        guard let slot = slot(at: page) else { return "" }
        switch slot {
        case .fixed:
            return ""
        case .reflowable(let spineIndex, _, let charOffset):
            let childPage = reflowEngine.pageIndex(
                forSpine: spineIndex,
                charOffset: charOffset
            )
            return reflowEngine.plainText(forPage: childPage)
        }
    }

    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        return Double(pageIndex(forSpine: spineIndex, charOffset: charOffset))
            / Double(totalPages - 1)
    }

    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        guard slots.isEmpty == false else { return (0, 0) }
        let clamped = min(max(progress, 0), 1)
        let page = Int((clamped * Double(slots.count - 1)).rounded())
        return charOffset(forPage: page)
    }

    func contentMetrics(
        forSpine spineIndex: Int,
        charOffset: Int,
        currentChapterCharacterCount: Int?
    ) -> ReaderContentMetrics? {
        guard effectiveLayout(at: spineIndex) == .reflowable else { return nil }
        return reflowEngine.contentMetrics(
            forSpine: spineIndex,
            charOffset: charOffset,
            currentChapterCharacterCount: currentChapterCharacterCount
        )
    }

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? {
        if href.hasPrefix("kindle:") { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let targetSpine: Int
        if rawPath.isEmpty {
            targetSpine = spineIndex
        } else {
            guard session.chapters.indices.contains(spineIndex) else { return nil }
            let resolvedHref = EPUBStyleResolver.resolveImageHref(
                rawPath,
                chapterHref: session.chapters[spineIndex].href
            )
            guard let matched = session.chapterIndex(for: resolvedHref)
                    ?? session.chapterIndex(for: rawPath) else { return nil }
            targetSpine = matched
        }

        if effectiveLayout(at: targetSpine) == .prePaginated {
            return firstPage(of: targetSpine)
        }
        await preloadChapter(at: targetSpine)
        let offset = fragment.flatMap {
            reflowEngine.charOffset(forSpine: targetSpine, fragment: $0)
        } ?? 0
        return pageIndex(forSpine: targetSpine, charOffset: offset)
    }

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        reflowEngine.applyThemeChange(
            textColor: textColor,
            backgroundColor: backgroundColor
        )
        fixedEngine.applyThemeChange(
            textColor: textColor,
            backgroundColor: backgroundColor
        )
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        reflowEngine.updateRenderSettings(settings)
        fixedEngine.updateRenderSettings(settings)
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        reflowEngine.setTextAnnotations(annotations)
        fixedEngine.setTextAnnotations(annotations)
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        guard let slot = slot(at: index) else { return nil }
        switch slot {
        case .fixed(let spineIndex):
            return fixedEngine.pageViewController(
                spineIndex: spineIndex,
                globalPage: index
            )
        case .reflowable(let spineIndex, let localPage, _):
            return reflowEngine.snapshotViewController(
                spineIndex: spineIndex,
                localPage: localPage,
                globalPage: index
            )
        }
    }

    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        guard let slot = slot(at: globalPage) else { return nil }
        switch slot {
        case .fixed:
            return nil
        case .reflowable(let spineIndex, _, let charOffset):
            let childPage = reflowEngine.pageIndex(
                forSpine: spineIndex,
                charOffset: charOffset
            )
            return reflowEngine.renderSnapshot(forPage: childPage)
        }
    }

    func pageViewController(at index: Int) -> UIViewController {
        guard slots.isEmpty == false else {
            return reflowEngine.pageViewController(at: 0)
        }
        let globalPage = max(0, min(index, slots.count - 1))
        currentPage = globalPage
        switch slots[globalPage] {
        case .fixed(let spineIndex):
            return fixedEngine.pageViewController(
                spineIndex: spineIndex,
                globalPage: globalPage
            )
        case .reflowable(let spineIndex, let localPage, _):
            return reflowEngine.pageViewController(
                spineIndex: spineIndex,
                localPage: localPage,
                globalPage: globalPage
            )
        }
    }

    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        let page = pageIndex(for: position)
            ?? estimatedGlobalPage(for: position)
            ?? 0
        return pageViewController(at: page)
    }

    private func effectiveLayout(at spineIndex: Int) -> EPUBLayoutMode {
        guard session.chapters.indices.contains(spineIndex) else {
            return session.layoutMode
        }
        return session.chapters[spineIndex].layoutModeOverride ?? session.layoutMode
    }

    private func rebuildSlots() {
        let anchoredPosition = slots.indices.contains(currentPage)
            ? readingPosition(forPage: currentPage)
            : nil
        let oldPage = currentPage
        let rebuiltSlots = session.chapters.flatMap { chapter -> [Slot] in
            if effectiveLayout(at: chapter.index) == .prePaginated {
                return [.fixed(spineIndex: chapter.index)]
            }
            guard let layout = reflowEngine.layouts[chapter.index],
                  layout.pageRanges.isEmpty == false else {
                return [.reflowable(
                    spineIndex: chapter.index,
                    localPage: 0,
                    charOffset: 0
                )]
            }
            return layout.pageRanges.enumerated().map { localPage, range in
                .reflowable(
                    spineIndex: chapter.index,
                    localPage: localPage,
                    charOffset: range.location
                )
            }
        }
        slots = rebuiltSlots
        if let anchoredPosition {
            currentPage = pageIndex(for: anchoredPosition)
                ?? estimatedGlobalPage(for: anchoredPosition)
                ?? oldPage
        }
        currentPage = max(0, min(currentPage, max(slots.count - 1, 0)))
        if currentPage != oldPage {
            onNavigateToPage?(currentPage)
        }
    }

    private func slot(at page: Int) -> Slot? {
        guard slots.isEmpty == false else { return nil }
        return slots[max(0, min(page, slots.count - 1))]
    }

    private func firstPage(of spineIndex: Int) -> Int? {
        slots.firstIndex { $0.spineIndex == spineIndex }
    }
}
