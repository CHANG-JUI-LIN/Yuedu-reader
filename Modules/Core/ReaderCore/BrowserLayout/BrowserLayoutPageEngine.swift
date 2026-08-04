import Foundation
import UIKit
import YueduCoreText

/// Per-chapter engine choice with structured reasons (never book content).
enum ChapterEngineChoice {
    case browser
    case legacyFallback([UnsupportedFeature])
    case legacyEngineFailure(String)

    var isBrowser: Bool {
        if case .browser = self { return true }
        return false
    }

    var debugLabel: String {
        switch self {
        case .browser: return "browser"
        case .legacyFallback(let reasons): return "legacy: capability \(reasons.map(\.description).joined(separator: ","))"
        case .legacyEngineFailure(let reason): return "legacy: engineFailure \(reason)"
        }
    }
}

/// One browser-laid-out chapter: pages, source text, anchors, and the
/// source-offset → page mapping.
struct BrowserChapterLayout {
    let spineIndex: Int
    let pages: [PageFragments]
    let sourceText: String
    let anchorOffsets: [String: Int]
    /// Page-local source ranges (into `sourceText`), built from fragments.
    let pageSourceRanges: [NSRange]
    let fontSize: CGFloat
    let themeTextColor: UIColor
    let themeBackgroundColor: UIColor

    init(spineIndex: Int, pages: [PageFragments], sourceText: String, anchorOffsets: [String: Int],
         fontSize: CGFloat, themeTextColor: UIColor, themeBackgroundColor: UIColor) {
        self.spineIndex = spineIndex
        self.pages = pages
        self.sourceText = sourceText
        self.anchorOffsets = anchorOffsets
        self.fontSize = fontSize
        self.themeTextColor = themeTextColor
        self.themeBackgroundColor = themeBackgroundColor
        self.pageSourceRanges = Self.buildPageRanges(pages, sourceText: sourceText)
    }

    static func buildPageRanges(_ pages: [PageFragments], sourceText: String) -> [NSRange] {
        let ns = sourceText as NSString
        return pages.map { page in
            var minLocation = ns.length
            var maxEnd = 0
            func walk(_ fragments: [Fragment]) {
                for fragment in fragments {
                    switch fragment {
                    case .text(let t):
                        if t.sourceRange.length > 0 {
                            minLocation = min(minLocation, t.sourceRange.location)
                            maxEnd = max(maxEnd, t.sourceRange.location + t.sourceRange.length)
                        }
                    case .group(let children): walk(children)
                    default: break
                    }
                }
            }
            walk(page.fragments)
            guard maxEnd > minLocation else { return NSRange(location: minLocation, length: 0) }
            return NSRange(location: minLocation, length: maxEnd - minLocation)
        }
    }

    /// Page index containing `charOffset` (binary search, clamped to the page
    /// whose range is nearest — offsets from another engine's collapse space
    /// are approximate; the spec restores to *nearby* content).
    func pageIndex(forCharOffset charOffset: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        let nsLength = (sourceText as NSString).length
        let target = min(max(charOffset, 0), nsLength)
        var low = 0
        var high = pageSourceRanges.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let range = pageSourceRanges[mid]
            if range.location > target {
                high = mid - 1
            } else if range.location + range.length < target {
                best = mid
                low = mid + 1
            } else {
                return mid
            }
        }
        return best
    }

    func displayList(forPage localPage: Int, themeTextColor: UIColor, oldThemeColor: UIColor) -> DisplayList {
        guard pages.indices.contains(localPage) else { return .empty }
        let page = pages[localPage]
        var items: [DisplayItem] = []
        func collect(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text(let t):
                    let color: UIColor
                    if t.color == oldThemeColor { color = themeTextColor } else { color = t.color }
                    let visible = slice(sourceText, t.sourceRange)
                    items.append(.text(DisplayTextItem(
                        sourceRange: t.sourceRange, nodeID: t.nodeID, linkTarget: t.linkTarget,
                        writingMode: t.writingMode, rect: t.rect, baselineY: t.baselineY,
                        font: t.font, color: color, text: visible
                    )))
                case .fill(let f):
                    items.append(.fill(DisplayFillItem(
                        rect: f.rect, color: f.color, cornerRadius: f.cornerRadius,
                        nodeID: f.nodeID, writingMode: f.writingMode
                    )))
                case .image(let i):
                    items.append(.image(DisplayImageItem(
                        source: i.source, image: i.image, sourceRange: i.sourceRange,
                        nodeID: i.nodeID, linkTarget: i.linkTarget,
                        writingMode: i.writingMode, rect: i.rect, alt: i.alt
                    )))
                case .group(let children): collect(children)
                }
            }
        }
        collect(page.fragments)
        return DisplayList(items: items)
    }

    private func slice(_ sourceText: String, _ range: NSRange) -> String {
        guard !sourceText.isEmpty, range.length > 0 else { return "" }
        let ns = sourceText as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }
}

/// Reader adapter for the browser-layout engine. Implements the FULL
/// `PageRenderingProvider` contract with per-chapter dispatch: chapters that
/// pass the capability scan (or are forced in `browserForced` mode) render with
/// the browser engine; everything else — and any internal error — falls back to
/// a legacy `CoreTextPageEngine` delegate for the WHOLE chapter (atomic).
///
/// The browser engine depends only on `BrowserLayoutResourceProviding` and
/// reader MODEL types — never on ReaderView/GlobalSettings/Readium UI.
@MainActor
final class BrowserLayoutPageEngine: PageRenderingProvider, LinkNavigationProviding {

    // MARK: - Protocol state

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0
    var layouts: [Int: CoreTextPaginator.ChapterLayout] { delegate.layouts }
    private(set) var renderSize: CGSize = .zero
    var offsetStore: CharOffsetStore { delegate.offsetStore }

    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?
    var onLinkNavigate: ((Int) -> Void)?
    var onFootnoteTap: ((String) -> Void)?

    // MARK: - Dependencies

    private let resource: any BrowserLayoutResourceProviding
    private let delegate: CoreTextPageEngine
    private var settings: ReaderRenderSettings
    private var themeTextColor: UIColor
    private var themeBackgroundColor: UIColor

    // MARK: - Per-chapter state

    private var choices: [Int: ChapterEngineChoice] = [:]
    private var browserChapters: [Int: BrowserChapterLayout] = [:]
    private var spinePageOffsets: [Int] = []
    private var chapterPageCounts: [Int: Int] = [:]
    private var layoutGeneration = 0
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var chapterTimeoutNanos: UInt64 = 5_000_000_000
    /// Stored for future annotation/selection integration (data structures must
    /// not block later work).
    private var textAnnotations: [CoreTextTextAnnotation] = []
    private var engineStatus: [Int: String] = [:]

    init(
        resource: any BrowserLayoutResourceProviding,
        delegate: CoreTextPageEngine,
        settings: ReaderRenderSettings
    ) {
        self.resource = resource
        self.delegate = delegate
        self.settings = settings
        self.themeTextColor = settings.textColor
        self.themeBackgroundColor = settings.backgroundColor
        delegate.onChapterReady = { [weak self] spine in
            self?.onChapterReady?(spine)
        }
        delegate.onNavigateToPage = { [weak self] page in
            self?.onNavigateToPage?(page)
        }
        delegate.onLinkNavigate = { [weak self] page in
            self?.onLinkNavigate?(page)
        }
        delegate.onFootnoteTap = { [weak self] note in
            self?.onFootnoteTap?(note)
        }
    }

    /// Which engine a chapter uses (decided once, cached).
    func choice(for spineIndex: Int) -> ChapterEngineChoice? {
        choices[spineIndex]
    }

    // MARK: - LayoutLifecycle

    func start(renderSize: CGSize, bookId: String) async {
        self.renderSize = renderSize
        await delegate.start(renderSize: renderSize, bookId: bookId)
        await preloadChapter(at: 0)
    }

    func preloadChapter(at spineIndex: Int) async {
        if preloadTasks[spineIndex] != nil { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.preloadChapterInternal(spineIndex)
            self.preloadTasks[spineIndex] = nil
        }
        preloadTasks[spineIndex] = task
        await task.value
    }

    private func preloadChapterInternal(_ spineIndex: Int) async {
        let choice = await decideEngine(for: spineIndex)
        choices[spineIndex] = choice
        switch choice {
        case .browser:
            await layoutBrowserChapter(spineIndex)
        case .legacyFallback, .legacyEngineFailure:
            await delegate.preloadChapter(at: spineIndex)
        }
        rebuildOffsets()
        onChapterReady?(spineIndex)
    }

    private func decideEngine(for spineIndex: Int) async -> ChapterEngineChoice {
        if let cached = choices[spineIndex] { return cached }
        guard let html = try? await resource.chapterHTML(at: spineIndex) else {
            return .legacyEngineFailure("chapterHTML")
        }
        let css = await resource.processedCSS(forChapter: spineIndex)
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        if scan.supported {
            return .browser
        }
        if BrowserLayoutFeature.mode == .browserForced {
            // Forced mode: attempt the browser engine anyway; failures below
            // become engine failures, never silent capability fallbacks.
            engineStatus[spineIndex] = "forced (unsupported: \(scan.unsupportedFeatures.map(\.description).joined(separator: ",")))"
            return .browser
        }
        return .legacyFallback(scan.unsupportedFeatures)
    }

    private func layoutBrowserChapter(_ spineIndex: Int) async {
        let generation = layoutGeneration
        do {
            let html = try await resource.chapterHTML(at: spineIndex)
            guard !html.isEmpty else {
                await fallbackToLegacy(spineIndex, reason: "chapterHTML")
                return
            }
            let css = await resource.processedCSS(forChapter: spineIndex)
            let images = await resource.prefetchImages(forChapter: spineIndex, html: html)
            guard generation == layoutGeneration else { return }  // stale

            let config = BrowserLayoutConfig(
                renderWidth: contentWidth,
                renderHeight: contentHeight,
                rootFontSize: settings.fontSize,
                fontFamilies: [],
                textColor: themeTextColor,
                backgroundColor: themeBackgroundColor,
                contentInsets: settings.contentInsets,
                lineHeight: settings.lineHeightMultiple,
                fontResolver: resource.fontResolver()
            )
            let document = BrowserLayoutDocument(
                html: html, cssTexts: css, config: config,
                imageLoader: { images[$0] }
            )

            let result = try await withTimeout(nanos: chapterTimeoutNanos) {
                try await document.renderPagesAndMeasure(containerSize: CGSize(width: self.contentWidth, height: self.contentHeight))
            }
            guard generation == layoutGeneration else { return }
            let (pages, _) = result
            if pages.isEmpty, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A chapter with content that produced zero pages is an engine
                // failure, not a capability issue.
                await fallbackToLegacy(spineIndex, reason: "emptyLayout")
                return
            }
            browserChapters[spineIndex] = BrowserChapterLayout(
                spineIndex: spineIndex,
                pages: pages,
                sourceText: document.lastSourceText,
                anchorOffsets: document.lastAnchorOffsets,
                fontSize: settings.fontSize,
                themeTextColor: settings.textColor,
                themeBackgroundColor: settings.backgroundColor
            )
            engineStatus[spineIndex] = "browser"
        } catch let error as EngineTimeoutError {
            await fallbackToLegacy(spineIndex, reason: "timeout")
            _ = error
        } catch {
            await fallbackToLegacy(spineIndex, reason: String(describing: error).prefix(80).description)
        }
    }

    private func fallbackToLegacy(_ spineIndex: Int, reason: String) async {
        choices[spineIndex] = .legacyEngineFailure(reason)
        engineStatus[spineIndex] = "legacy: engineFailure \(reason)"
        await delegate.preloadChapter(at: spineIndex)
    }

    func invalidateLayout(newSize: CGSize) async {
        let restore = readingPosition(forPage: currentPage)
        layoutGeneration += 1
        renderSize = newSize
        // Rebuild browser chapters from scratch (settings may have changed).
        let browserSpines = Array(browserChapters.keys)
        browserChapters.removeAll()
        choices.removeAll()
        engineStatus.removeAll()
        await delegate.invalidateLayout(newSize: newSize)
        for spine in browserSpines {
            await preloadChapter(at: spine)
        }
        rebuildOffsets()
        if let restore, let page = pageIndex(for: restore) {
            currentPage = page
            onNavigateToPage?(page)
        }
        onChapterReady?(nil)
    }

    func warmUpNext(currentGlobalPage: Int) {
        delegate.warmUpNext(currentGlobalPage: currentGlobalPage)
        let (spine, _) = localPosition(for: currentGlobalPage)
        if spine + 1 < resource.chapterCount, choices[spine + 1] == nil {
            Task { [weak self] in
                await self?.preloadChapter(at: spine + 1)
            }
        }
    }

    func cancelPendingWork() {
        delegate.cancelPendingWork()
        for task in preloadTasks.values { task.cancel() }
        preloadTasks.removeAll()
    }

    func notifyChapterDataChanged(at spineIndex: Int) async {
        browserChapters.removeValue(forKey: spineIndex)
        choices.removeValue(forKey: spineIndex)
        await delegate.notifyChapterDataChanged(at: spineIndex)
        await preloadChapter(at: spineIndex)
    }

    // MARK: - StablePositionResolving

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        let base = spinePageOffsets.indices.contains(spineIndex) ? spinePageOffsets[spineIndex] : 0
        return base + localPageIndex(in: spineIndex, charOffset: charOffset)
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        pageIndex(forSpine: position.spineIndex, charOffset: position.charOffset)
    }

    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int? {
        pageIndex(for: position)
    }

    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        let (spine, local) = localPosition(for: page)
        let offset = charOffset(forPage: page).charOffset
        return CoreTextReadingPosition(spineIndex: spine, charOffset: offset)
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        let (spine, local) = localPosition(for: page)
        switch choices[spine] ?? .browser {
        case .browser:
            guard let layout = browserChapters[spine],
                  layout.pageSourceRanges.indices.contains(local) else {
                return (spine, 0)
            }
            return (spine, layout.pageSourceRanges[local].location)
        case .legacyFallback, .legacyEngineFailure:
            return delegate.charOffset(forPage: delegatePageIndex(for: spine, localPage: local))
        }
    }

    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int? {
        switch choices[spineIndex] ?? .browser {
        case .browser:
            return browserChapters[spineIndex]?.anchorOffsets[fragment]
        case .legacyFallback, .legacyEngineFailure:
            return delegate.charOffset(forSpine: spineIndex, fragment: fragment)
        }
    }

    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
        guard !spinePageOffsets.isEmpty else { return (0, 0) }
        let target = max(0, globalPage)
        var low = 0
        var high = spinePageOffsets.count - 1
        var spine = 0
        while low <= high {
            let mid = (low + high) / 2
            if spinePageOffsets[mid] <= target {
                spine = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return (spine, max(0, target - spinePageOffsets[spine]))
    }

    func lastPageIndex(ofChapter spineIndex: Int) -> Int? {
        guard let count = chapterPageCounts[spineIndex], count > 0 else { return nil }
        let base = spinePageOffsets.indices.contains(spineIndex) ? spinePageOffsets[spineIndex] : 0
        return base + count - 1
    }

    // MARK: - ProgressResolving

    func plainText(forPage page: Int) -> String {
        let (spine, local) = localPosition(for: page)
        switch choices[spine] ?? .browser {
        case .browser:
            guard let layout = browserChapters[spine],
                  layout.pageSourceRanges.indices.contains(local) else { return "" }
            let range = layout.pageSourceRanges[local]
            let ns = layout.sourceText as NSString
            guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
            return ns.substring(with: range)
        case .legacyFallback, .legacyEngineFailure:
            return delegate.plainText(forPage: delegatePageIndex(for: spine, localPage: local))
        }
    }

    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        delegate.totalProgress(forSpine: spineIndex, charOffset: charOffset)
    }

    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) {
        delegate.position(forProgress: progress)
    }

    // MARK: - InternalLinkResolving

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? {
        // Legacy-compatible resolution: path#fragment → target spine + offset.
        var path = href
        var fragment: String? = nil
        if let hashIndex = href.firstIndex(of: "#") {
            path = String(href[..<hashIndex])
            fragment = String(href[href.index(after: hashIndex)...])
        }
        var targetSpine = spineIndex
        if !path.isEmpty {
            // Resolve the path relative to the current chapter's href.
            let currentHref = resource.chapterSourceHref(at: spineIndex) ?? ""
            let resolved = EPUBStyleResolver.resolveImageHref(path, chapterHref: currentHref)
            targetSpine = chapterIndexMatching(resolved) ?? spineIndex
        }
        await preloadChapter(at: targetSpine)
        let offset: Int
        if let fragment, !fragment.isEmpty {
            offset = charOffset(forSpine: targetSpine, fragment: fragment) ?? 0
        } else {
            offset = 0
        }
        return pageIndex(forSpine: targetSpine, charOffset: offset)
    }

    private func chapterIndexMatching(_ href: String) -> Int? {
        for index in 0..<resource.chapterCount {
            if resource.chapterSourceHref(at: index) == href { return index }
        }
        return nil
    }

    // MARK: - ThemeUpdatable / AnnotationApplying / SnapshotRenderable

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        delegate.applyThemeChange(textColor: textColor, backgroundColor: backgroundColor)
        themeTextColor = textColor
        themeBackgroundColor = backgroundColor
        // Browser fragment colors are baked at layout time; DisplayList builds
        // substitute the new theme color where a fragment carried the old one.
        for (spine, layout) in browserChapters {
            browserChapters[spine] = BrowserChapterLayout(
                spineIndex: spine, pages: layout.pages, sourceText: layout.sourceText,
                anchorOffsets: layout.anchorOffsets, fontSize: layout.fontSize,
                themeTextColor: textColor, themeBackgroundColor: backgroundColor
            )
        }
        onChapterReady?(nil)
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        self.settings = settings
        delegate.updateRenderSettings(settings)
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
        delegate.setTextAnnotations(annotations)
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        nil
    }

    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        let (spine, local) = localPosition(for: globalPage)
        switch choices[spine] ?? .browser {
        case .browser:
            guard let layout = browserChapters[spine] else { return nil }
            let list = layout.displayList(forPage: local, themeTextColor: settings.textColor, oldThemeColor: layout.themeTextColor)
            return DisplayListRenderer.render(list, size: renderSize, backgroundColor: settings.backgroundColor)
        case .legacyFallback, .legacyEngineFailure:
            return delegate.renderSnapshot(forPage: delegatePageIndex(for: spine, localPage: local))
        }
    }

    // MARK: - PageViewControllerVending

    func pageViewController(at index: Int) -> UIViewController {
        let (spine, local) = localPosition(for: index)
        currentPage = index
        switch choices[spine] ?? .browser {
        case .browser:
            guard let layout = browserChapters[spine],
                  layout.pages.indices.contains(local) else {
                return PlaceholderPageViewController()
            }
            let list = layout.displayList(forPage: local, themeTextColor: settings.textColor, oldThemeColor: layout.themeTextColor)
            let offset = layout.pageSourceRanges[local].location
            let vc = BrowserLayoutPageViewController(
                globalPageIndex: index,
                readingPosition: CoreTextReadingPosition(spineIndex: spine, charOffset: offset),
                displayList: list,
                backgroundColor: settings.backgroundColor,
                statusText: BrowserLayoutFeature.showDebugOverlay ? statusLabel(for: spine) : nil
            ) { [weak self] href in
                self?.handleLinkTap(href, fromSpine: spine)
            }
            return vc
        case .legacyFallback, .legacyEngineFailure:
            return delegate.pageViewController(at: delegatePageIndex(for: spine, localPage: local))
        }
    }

    private func handleLinkTap(_ href: String, fromSpine spineIndex: Int) {
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            if let url = URL(string: href) {
                UIApplication.shared.open(url)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let target = await self.resolveInternalLink(href, fromSpineIndex: spineIndex) {
                self.onLinkNavigate?(target)
            }
        }
    }

    // MARK: - Internal helpers

    private var contentWidth: CGFloat {
        max(1, renderSize.width - settings.contentInsets.left - settings.contentInsets.right)
    }

    private var contentHeight: CGFloat {
        max(1, renderSize.height - settings.contentInsets.top - settings.contentInsets.bottom)
    }

    private func localPageIndex(in spineIndex: Int, charOffset: Int) -> Int {
        switch choices[spineIndex] ?? .browser {
        case .browser:
            return browserChapters[spineIndex]?.pageIndex(forCharOffset: charOffset) ?? 0
        case .legacyFallback, .legacyEngineFailure:
            let delegateBase = delegate.pageIndex(forSpine: spineIndex, charOffset: 0)
            return max(0, delegate.pageIndex(forSpine: spineIndex, charOffset: charOffset) - delegateBase)
        }
    }

    private func delegatePageIndex(for spineIndex: Int, localPage: Int) -> Int {
        delegate.pageIndex(forSpine: spineIndex, charOffset: 0) + localPage
    }

    private func rebuildOffsets() {
        var offsets: [Int] = []
        var counts: [Int: Int] = [:]
        var running = 0
        for spine in 0..<resource.chapterCount {
            offsets.append(running)
            let count: Int
            switch choices[spine] ?? .browser {
            case .browser:
                count = browserChapters[spine]?.pages.count ?? 0
            case .legacyFallback, .legacyEngineFailure:
                count = max(0, delegate.lastPageIndex(ofChapter: spine).map { $0 - delegate.pageIndex(forSpine: spine, charOffset: 0) + 1 } ?? 0)
            }
            counts[spine] = count
            running += count
        }
        spinePageOffsets = offsets
        chapterPageCounts = counts
        totalPages = running
    }

    private func withTimeout<T>(nanos: UInt64, _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw EngineTimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

private struct EngineTimeoutError: Error {}

// MARK: - ChapterEngineChoice helpers

extension BrowserLayoutPageEngine {
    /// Current engine + reason for the debug overlay.
    func statusLabel(for spineIndex: Int) -> String {
        if let status = engineStatus[spineIndex] { return status }
        return choices[spineIndex]?.debugLabel ?? "unknown"
    }
}

private extension BrowserLayoutResourceProviding {
    func chapterSourceHrefs() -> [String] {
        (0..<chapterCount).compactMap { chapterSourceHref(at: $0) }
    }
}
