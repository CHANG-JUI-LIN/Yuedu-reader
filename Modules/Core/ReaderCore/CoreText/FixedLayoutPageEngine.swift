import UIKit

@MainActor
final class FixedLayoutPageEngine: PageRenderingProvider, FixedLayoutSpreadPairingProviding {
    private let session: PublicationSession
    private let resourceProvider: BookResourceProvider
    private let viewportResolver: FixedLayoutViewportResolver

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0
    private(set) var renderSize: CGSize = .zero
    let fixedLayoutSpreadPairs: [FixedLayoutSpreadPair]
    let offsetStore: CharOffsetStore

    private var pageVCs: [Int: FixedLayoutPageViewController] = [:]

    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?

    init(session: PublicationSession, renderSize: CGSize) {
        self.session = session
        self.resourceProvider = ReadiumBookResourceAdapter(session: session)
        self.totalPages = session.chapters.count
        self.renderSize = renderSize
        self.fixedLayoutSpreadPairs = FixedLayoutSpreadPairingBuilder.build(
            chapters: session.chapters,
            isRTL: session.pageProgressionDirection == .rtl
        )
        self.viewportResolver = FixedLayoutViewportResolver(
            defaultViewport: session.fixedLayoutViewport?.defaultViewport,
            pageViewports: session.fixedLayoutViewport?.pageViewports ?? [:]
        )
        let storeDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("epub_charoffsets/\(session.id)")
        self.offsetStore = CharOffsetStore(directoryURL: storeDir)
    }

    // MARK: - PagedReaderEngine

    var layouts: [Int : CoreTextPaginator.ChapterLayout] { [:] }

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        spineIndex
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        guard position.spineIndex >= 0, position.spineIndex < totalPages else { return nil }
        return position.spineIndex
    }

    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int? {
        pageIndex(for: position)
    }

    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        guard page >= 0, page < totalPages else { return nil }
        return CoreTextReadingPosition(spineIndex: page, charOffset: 0)
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        guard page >= 0, page < totalPages else { return (0, 0) }
        return (page, 0)
    }

    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
        guard globalPage >= 0, globalPage < totalPages else { return (0, 0) }
        return (globalPage, 0)
    }

    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        guard spineIndex >= 0, spineIndex < totalPages else { return nil }
        return spineIndex
    }

    func plainText(forPage page: Int) -> String { "" }

    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        guard totalPages > 0 else { return 0 }
        return Double(spineIndex) / Double(totalPages)
    }

    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        let idx = Int((progress * Double(max(totalPages - 1, 0))).rounded())
        return (max(0, min(idx, totalPages - 1)), 0)
    }

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? { nil }

    func start(renderSize: CGSize, bookId: String) async {
        self.renderSize = renderSize
        guard totalPages > 0 else { return }

        let priority = Set([0, 1].filter { $0 < totalPages })
        await withTaskGroup(of: Void.self) { @MainActor group in
            for i in priority {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.viewportResolver.viewport(for: i, resourceProvider: self.resourceProvider)
                }
            }
        }
    }

    func preloadChapter(at spineIndex: Int) async {
        guard spineIndex >= 0, spineIndex < totalPages else { return }
        _ = await viewportResolver.viewport(for: spineIndex, resourceProvider: resourceProvider)
    }

    func invalidateLayout(newSize: CGSize) async {
        renderSize = newSize
        pageVCs.removeAll()
        onChapterReady?(nil)
    }

    func warmUpNext(currentGlobalPage: Int) {
        let idx = max(0, min(currentGlobalPage, totalPages - 1))
        var priority: [Int] = []
        if idx > 0 { priority.append(idx - 1) }
        priority.append(idx)
        if idx < totalPages - 1 { priority.append(idx + 1) }
        for i in pageVCs.keys where !priority.contains(i) {
            pageVCs[i] = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewportResolver.prewarm(
                spineIndices: priority,
                resourceProvider: self.resourceProvider
            )
        }
    }

    func cancelPendingWork() {}

    func notifyChapterDataChanged(at spineIndex: Int) async {
        pageVCs[spineIndex] = nil
        onChapterReady?(spineIndex)
    }

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        pageVCs.removeAll()
        onChapterReady?(nil)
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {}

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {}

    // MARK: - PageViewControllerVending

    func pageViewController(at index: Int) -> UIViewController {
        pageViewController(spineIndex: index, globalPage: index)
    }

    func pageViewController(spineIndex: Int, globalPage: Int) -> UIViewController {
        let clampedSpine = max(0, min(spineIndex, totalPages - 1))
        if let cached = pageVCs[clampedSpine],
           cached.globalPageIndex == globalPage {
            return cached
        }
        let controller = FixedLayoutPageViewController()
        controller.configure(globalPage: globalPage)
        pageVCs[clampedSpine] = controller
        loadPage(controller, spineIndex: clampedSpine)
        return controller
    }

    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        pageViewController(at: max(0, min(position.spineIndex, totalPages - 1)))
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        pageViewController(at: max(0, min(index, totalPages - 1)))
    }

    func renderSnapshot(forPage globalPage: Int) -> UIImage? { nil }

    private func loadPage(
        _ controller: FixedLayoutPageViewController,
        spineIndex: Int
    ) {
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            let pageSize = await viewportResolver.viewport(
                for: spineIndex,
                resourceProvider: resourceProvider
            )
            let html = (try? await resourceProvider.chapterHTML(at: spineIndex)) ?? ""
            let chapterHref = session.chapters[spineIndex].href
            let preparedHTML = await FixedLayoutEPUBHTMLInliner(
                resourceProvider: resourceProvider,
                chapterHref: chapterHref
            ).inlinedHTML(html)
            controller.load(
                html: preparedHTML,
                baseURL: nil,
                pageSize: pageSize,
                availableSize: renderSize
            )
        }
    }
}
