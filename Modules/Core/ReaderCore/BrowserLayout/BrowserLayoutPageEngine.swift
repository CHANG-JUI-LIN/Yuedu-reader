import Foundation
import SwiftSoup
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
    var pages: [PageFragments]
    let sourceText: String
    let anchorOffsets: [String: Int]
    /// Page-local source ranges (into `sourceText`), derived from the CURRENT
    /// pages — computed so incremental completion (pages growing) stays
    /// correct. Cheap: a few dozen pages × ~50 fragments.
    var pageSourceRanges: [NSRange] {
        Self.buildPageRanges(pages, sourceText: sourceText)
    }
    let fontSize: CGFloat
    let themeTextColor: UIColor
    let themeBackgroundColor: UIColor
    /// Lifecycle accounting: estimated retained bytes for this chapter's
    /// style tree / box tree / fragments (released on chapter eviction).
    var estimatedStyleBytes: Int64 = 0
    var estimatedBoxBytes: Int64 = 0
    var estimatedFragmentBytes: Int64 = 0
    /// Bytes of built DisplayLists for this chapter (released on eviction).
    var displayListBytes: Int64 = 0
    /// DEBUG-only: layout generation for on-device diagnostics.
    var diagnosticGeneration: Int = -1

    init(spineIndex: Int, pages: [PageFragments], sourceText: String, anchorOffsets: [String: Int],
         fontSize: CGFloat, themeTextColor: UIColor, themeBackgroundColor: UIColor) {
        self.spineIndex = spineIndex
        self.pages = pages
        self.sourceText = sourceText
        self.anchorOffsets = anchorOffsets
        self.fontSize = fontSize
        self.themeTextColor = themeTextColor
        self.themeBackgroundColor = themeBackgroundColor
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
                        font: t.font, color: color, text: visible, ctLine: t.ctLine
                    )))
                case .fill(let f):
                    items.append(.fill(DisplayFillItem(
                        rect: f.rect, color: f.color, cornerRadius: f.cornerRadius,
                        borderTop: f.borderTop, borderBottom: f.borderBottom,
                        borderLeft: f.borderLeft, borderRight: f.borderRight,
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
        #if DEBUG
        // DEBUG-only: k1 fill/border commands as emitted (page-local).
        var k1Fill: PageRect? = nil
        var k2Border: PageRect? = nil
        for item in items {
            if case .fill(let f) = item {
                if f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 { k1Fill = f.rect }
                if f.rect.width > 200, f.rect.width < 320, f.rect.height <= 2 { k2Border = f.rect }
            }
        }
        let k1Msg = k1Fill.map { BrowserLayoutDeviceDiagnostic.rect($0.rect, space: "coordinate=pageLocal") } ?? "none"
        let k2Msg = k2Border.map { BrowserLayoutDeviceDiagnostic.rect($0.rect, space: "coordinate=pageLocal") } ?? "none"
        BrowserLayoutDeviceDiagnostic.log(
            .k1DisplayList(spine: spineIndex, generation: diagnosticGeneration),
            spine: spineIndex, generation: diagnosticGeneration, page: localPage,
            message: "stage=displayList node=k1 fillRect=\(k1Msg) borderRect=\(k2Msg)"
        )
        #endif
        return DisplayList(items: items)
    }

    private func slice(_ sourceText: String, _ range: NSRange) -> String {
        guard !sourceText.isEmpty, range.length > 0 else { return "" }
        let ns = sourceText as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    // MARK: - Lifecycle accounting

    /// Records this chapter's estimated style-tree / box-tree bytes (per
    /// chapter, so eviction can release them) and its current fragment bytes.
    mutating func recordLifecycleBytes(nodeCount: Int, boxCount: Int) {
        estimatedStyleBytes = Int64(nodeCount) * 120
        estimatedBoxBytes = Int64(boxCount) * 200
        refreshFragmentBytes()
        MemoryTracker.record(.domStyleTree, bytes: estimatedStyleBytes)
        MemoryTracker.record(.layoutBoxTree, bytes: estimatedBoxBytes)
    }

    /// Re-accounts fragment bytes after pages grew (incremental completion).
    mutating func refreshFragmentBytes() {
        let fragmentCount = pages.reduce(0) { total, page in
            total + Self.countFragments(page.fragments)
        }
        let delta = Int64(fragmentCount) * 60 - estimatedFragmentBytes
        if delta > 0 {
            MemoryTracker.record(.fragmentTree, bytes: delta)
        } else if delta < 0 {
            MemoryTracker.release(.fragmentTree, bytes: -delta)
        }
        estimatedFragmentBytes = Int64(fragmentCount) * 60
    }

    func releaseLifecycleBytes() {
        MemoryTracker.release(.domStyleTree, bytes: estimatedStyleBytes)
        MemoryTracker.release(.layoutBoxTree, bytes: estimatedBoxBytes)
        MemoryTracker.release(.fragmentTree, bytes: estimatedFragmentBytes)
        if displayListBytes > 0 {
            MemoryTracker.release(.displayList, bytes: displayListBytes)
        }
    }

    private static func countFragments(_ fragments: [Fragment]) -> Int {
        var count = 0
        for fragment in fragments {
            switch fragment {
            case .text, .fill, .image: count += 1
            case .group(let children): count += countFragments(children)
            }
        }
        return count
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

    /// Test seam: current browser-mode chapter layout (precise-geometry
    /// verification for selection rects).
    var testChapterLayout: (spine: Int, layout: BrowserChapterLayout)? {
        guard let (spine, layout) = browserChapters.first else { return nil }
        return (spine, layout)
    }
    private var browserSessions: [Int: BrowserLayoutSession] = [:]
    private var backgroundFinishTasks: [Int: Task<Void, Never>] = [:]
    private var spinePageOffsets: [Int] = []
    private var chapterPageCounts: [Int: Int] = [:]
    private var layoutGeneration = 0
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var chapterTimeoutNanos: UInt64 = 5_000_000_000
    /// Stored for future annotation/selection integration (data structures must
    /// not block later work).
    private var textAnnotations: [CoreTextTextAnnotation] = []
    private var engineStatus: [Int: String] = [:]
    /// Bounded DisplayList window cache: ±2 pages around the current page keep
    /// their paint artifacts; farther pages rebuild on demand (DisplayLists
    /// are cheap to rebuild from fragments).
    private var displayListCache: [Int: DisplayList] = [:]
    private var displayListCacheBytes: [Int: Int64] = [:]

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
        if let cached = choices[spineIndex] {
            BrowserLayoutDeviceDiagnostic.log(
                .engineDecision(spine: spineIndex, generation: layoutGeneration),
                spine: spineIndex, generation: layoutGeneration,
                message: "engineDecision cached=\(cached.debugLabel)"
            )
            return cached
        }
        guard let html = try? await resource.chapterHTML(at: spineIndex) else {
            BrowserLayoutDeviceDiagnostic.log(
                .engineDecision(spine: spineIndex, generation: layoutGeneration),
                spine: spineIndex, generation: layoutGeneration,
                message: "actualEngine=legacy reason=chapterHTML-fetch-failed"
            )
            return .legacyEngineFailure("chapterHTML")
        }
        let css = await resource.processedCSS(forChapter: spineIndex)
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        let mode = BrowserLayoutFeature.mode
        let decision: ChapterEngineChoice
        if scan.supported {
            decision = .browser
        } else if mode == .browserForced {
            // Forced mode: attempt the browser engine anyway; failures below
            // become engine failures, never silent capability fallbacks.
            engineStatus[spineIndex] = "forced (unsupported: \(scan.unsupportedFeatures.map(\.description).joined(separator: ",")))"
            decision = .browser
        } else {
            decision = .legacyFallback(scan.unsupportedFeatures)
        }
        let isBrowser: Bool
        switch decision {
        case .browser: isBrowser = true
        case .legacyFallback, .legacyEngineFailure: isBrowser = false
        }
        BrowserLayoutDeviceDiagnostic.log(
            .engineDecision(spine: spineIndex, generation: layoutGeneration),
            spine: spineIndex, generation: layoutGeneration,
            message: "engineDecision mode=\(mode) scanSupported=\(scan.supported) "
                + "unsupported=\(scan.unsupportedFeatures.map(\.description)) choice=\(decision.debugLabel) "
                + "actualEngine=\(isBrowser ? "browser" : "legacy")"
        )
        if case .legacyFallback(let reasons) = decision {
            BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) fallbackReason=\(reasons.map(\.description).joined(separator: ",")) spine=\(spineIndex)")
        }
        return decision
    }

    private func layoutBrowserChapter(_ spineIndex: Int) async {
        let generation = layoutGeneration
        let traceID = BrowserLayoutDeviceDiagnostic.newTraceID(for: spineIndex, generation: generation)
        BrowserLayoutDeviceDiagnostic.log(
            .chapterConfig(spine: spineIndex, generation: generation),
            spine: spineIndex, generation: generation,
            message: "chapterLayoutStart trace=\(traceID) engineCreated=BrowserLayoutPageEngine "
                + "mode=\(BrowserLayoutFeature.mode)"
        )
        do {
            let html = try await resource.chapterHTML(at: spineIndex)
            guard !html.isEmpty else {
                await fallbackToLegacy(spineIndex, reason: "chapterHTML")
                return
            }
            let css = await resource.processedCSS(forChapter: spineIndex)
            let images = await resource.prefetchImages(forChapter: spineIndex, html: html)
            guard generation == layoutGeneration else { return }  // stale

            let fontPolicy = Self.fontScalePolicy(for: html)
            let config = makeBrowserConfig(fontScalePolicy: fontPolicy)
            let session = BrowserLayoutSession(
                html: html, cssTexts: css, config: config,
                imageLoader: { images[$0] }, generation: generation
            )
            session.diagnosticSpine = spineIndex

            // FIRST PAGE: publish immediately — the rest of the chapter is NOT
            // laid out yet.
            let firstPage = try await withTimeout(nanos: chapterTimeoutNanos) {
                try await session.layoutNextPage()
            }
            guard generation == layoutGeneration else { return }
            guard let firstPage else {
                // A chapter with content that produced zero pages is an engine
                // failure, not a capability issue.
                await fallbackToLegacy(spineIndex, reason: "emptyLayout")
                return
            }
            browserSessions[spineIndex] = session
            var layout = BrowserChapterLayout(
                spineIndex: spineIndex,
                pages: [firstPage],
                sourceText: session.sourceText,
                anchorOffsets: session.anchorOffsets,
                fontSize: settings.fontSize,
                themeTextColor: self.themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            )
            layout.diagnosticGeneration = generation
            layout.recordLifecycleBytes(nodeCount: session.pipelineNodeCount, boxCount: session.pipelineBoxCount)
            browserChapters[spineIndex] = layout
            engineStatus[spineIndex] = "browser"
            rebuildOffsets()
            onChapterReady?(spineIndex)

            // REMAINING PAGES: generated after the first-page publish. The
            // caller already rendered page 1 via onChapterReady; preload
            // returns only when the chapter is complete (deterministic).
            await finishBrowserChapter(spineIndex, generation: generation)
        } catch let error as EngineTimeoutError {
            await fallbackToLegacy(spineIndex, reason: "timeout")
            _ = error
        } catch {
            await fallbackToLegacy(spineIndex, reason: String(describing: error).prefix(80).description)
        }
    }

    /// Background completion of a chapter's remaining pages. On failure the
    /// WHOLE chapter falls back to the legacy delegate (no mixed chapter).
    private func finishBrowserChapter(_ spineIndex: Int, generation: Int) async {
        guard let session = browserSessions[spineIndex] else { return }
        do {
            try await session.finish()
        } catch {
            guard layoutGeneration == generation else { return }
            browserChapters.removeValue(forKey: spineIndex)?.releaseLifecycleBytes()
            browserSessions.removeValue(forKey: spineIndex)
            await fallbackToLegacy(spineIndex, reason: String(describing: error).prefix(80).description)
            rebuildOffsets()
            onChapterReady?(spineIndex)
            return
        }
        guard layoutGeneration == generation, var layout = browserChapters[spineIndex] else { return }
        layout.pages = session.completedPages
        layout.refreshFragmentBytes()
        browserChapters[spineIndex] = layout
        browserSessions.removeValue(forKey: spineIndex)
        rebuildOffsets()
        onChapterReady?(spineIndex)
    }

    /// Extends a browser chapter's layout to cover `sourceOffset` on demand
    /// (the caller may then resolve the offset to an exact page).
    func extendLayout(spineIndex: Int, toSourceOffset offset: Int) async {
        guard let session = browserSessions[spineIndex], !session.isFinished else { return }
        try? await session.layout(untilSourceOffset: offset)
        guard layoutGeneration == session.generation, var layout = browserChapters[spineIndex] else { return }
        layout.pages = session.completedPages
        layout.refreshFragmentBytes()
        browserChapters[spineIndex] = layout
        rebuildOffsets()
    }

    private func makeBrowserConfig(fontScalePolicy: PublicationFontScalePolicy = .readerAdjustable) -> BrowserLayoutConfig {
        // A/B font parity: mirror the legacy builder's base-font resolution
        // (settings.fontPostScriptName when a user font is chosen; the CSS
        // font-family rules then override per element on both engines).
        BrowserLayoutConfig(
            renderWidth: contentWidth,
            renderHeight: contentHeight,
            rootFontSize: fontScalePolicy.rootFontSize(userSetting: settings.fontSize),
            fontFamilies: settings.fontPostScriptName.map { [$0] } ?? [],
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor,
            contentInsets: settings.contentInsets,
            lineHeight: settings.lineHeightMultiple,
            fontResolver: resource.fontResolver()
        )
    }

    /// Chapter font-scale policy from the body inline style
    /// (`zy-fontsize-adjust: fixed` → fixed; otherwise reader-adjustable).
    static func fontScalePolicy(for html: String) -> PublicationFontScalePolicy {
        guard let doc = try? SwiftSoup.parse(html),
              let body = doc.body() else { return .readerAdjustable }
        let inline = (try? body.attr("style")) ?? ""
        return PublicationFontScalePolicy.resolve(bodyInlineStyle: inline)
    }

    private func fallbackToLegacy(_ spineIndex: Int, reason: String) async {
        choices[spineIndex] = .legacyEngineFailure(reason)
        engineStatus[spineIndex] = "legacy: engineFailure \(reason)"
        BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) fallbackToLegacy spine=\(spineIndex) reason=\(reason)")
        await delegate.preloadChapter(at: spineIndex)
        BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) fallbackToLegacyDone spine=\(spineIndex) delegatePages=\(delegate.lastPageIndex(ofChapter: spineIndex).map(String.init) ?? "nil")")
    }

    func invalidateLayout(newSize: CGSize) async {
        let restore = readingPosition(forPage: currentPage)
        layoutGeneration += 1
        renderSize = newSize
        // Rebuild browser chapters from scratch (settings may have changed).
        // Background finish tasks observe the bumped generation and drop.
        let browserSpines = Array(browserChapters.keys)
        for layout in browserChapters.values { layout.releaseLifecycleBytes() }
        browserChapters.removeAll()
        browserSessions.removeAll()
        evictAllDisplayLists()
        for task in backgroundFinishTasks.values { task.cancel() }
        backgroundFinishTasks.removeAll()
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
        for task in backgroundFinishTasks.values { task.cancel() }
        backgroundFinishTasks.removeAll()
    }

    func notifyChapterDataChanged(at spineIndex: Int) async {
        browserChapters.removeValue(forKey: spineIndex)?.releaseLifecycleBytes()
        browserSessions.removeValue(forKey: spineIndex)
        evictAllDisplayLists()
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
        // substitute the new theme color where a fragment carried the layout's
        // ORIGINAL theme color (layout.themeTextColor stays unchanged, exactly
        // like the legacy engine's color-only relayout).
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
            let list = layout.displayList(forPage: local, themeTextColor: themeTextColor, oldThemeColor: layout.themeTextColor)
            return DisplayListRenderer.render(list, size: renderSize, backgroundColor: themeBackgroundColor)
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
            let list = cachedDisplayList(globalPage: index, spine: spine, local: local, layout: layout)
            let offset = layout.pageSourceRanges[local].location
            let vc = BrowserLayoutPageViewController(
                globalPageIndex: index,
                readingPosition: CoreTextReadingPosition(spineIndex: spine, charOffset: offset),
                displayList: list,
                backgroundColor: themeBackgroundColor,
                statusText: BrowserLayoutFeature.showDebugOverlay ? statusLabel(for: spine) : nil
            ) { [weak self] href in
                self?.handleLinkTap(href, fromSpine: spine)
            }
            // DEBUG: expose coordinate truth on the REAL page view (overlay
            // lines + superview chain + commit SHA). Never affects layout.
            let k1Rect = Self.k1PageLocalRect(in: list)
            let modeLabel: String
            switch BrowserLayoutFeature.mode {
            case .legacy: modeLabel = "legacy"
            case .browserAuto: modeLabel = "browserAuto"
            case .browserForced: modeLabel = "browserForced"
            }
            let spec = BrowserLayoutPageView.DebugSpec(
                commitSHA: Self.currentCommitSHA,
                engineMode: modeLabel,
                k1ExpectedPageLocalTop: Self.k1ExpectedTop(contentWidth: contentWidth),
                k1DisplayListTop: Self.k1DisplayListTop(in: list),
                k1PageLocalRect: k1Rect,
                traceID: BrowserLayoutDeviceDiagnostic.traceID(for: spine, generation: layoutGeneration),
                spine: spine,
                generation: layoutGeneration,
                pageContentRect: CGRect(
                    x: settings.contentInsets.left,
                    y: settings.contentInsets.top,
                    width: max(0, renderSize.width - settings.contentInsets.left - settings.contentInsets.right),
                    height: max(0, renderSize.height - settings.contentInsets.top - settings.contentInsets.bottom)
                ),
                bodyBorderRect: Self.genericBodyRect(in: list),
                firstBlockRect: nil,
                firstLineBoxRect: Self.firstLineBoxRect(in: list)
            )
            vc.pageView.debugSpec = spec
            BrowserLayoutDeviceDiagnostic.log(
                .pageViewConfigure(spine: spine, generation: layoutGeneration),
                spine: spine, generation: layoutGeneration, page: local,
                message: "pageViewConfigure trace=\(spec.traceID) k1PageLocalRect=\(BrowserLayoutDeviceDiagnostic.rect(k1Rect, space: "coordinate=pageLocal"))"
            )
            return vc
        case .legacyFallback, .legacyEngineFailure:
            return delegate.pageViewController(at: delegatePageIndex(for: spine, localPage: local))
        }
    }

    /// Position-driven page view. For a chapter the browser engine has NOT
    /// laid out yet, returns a titled placeholder AND kicks off the chapter
    /// preload so `onChapterReady` can replace it — the same contract the
    /// legacy engine follows. Without this, turning past a chapter boundary
    /// left the reader stuck on a bare placeholder (could not turn pages).
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        let spine = position.spineIndex
        guard (0..<resource.chapterCount).contains(spine) else {
            return pageViewController(at: 0)
        }
        // Already decided/laid out → normal path.
        switch choices[spine] ?? .browser {
        case .browser:
            if let layout = browserChapters[spine], !layout.pages.isEmpty {
                if let page = pageIndex(for: position) {
                    return pageViewController(at: page)
                }
            }
            // Not laid out yet: placeholder + preload.
            let title = resource.chapterTitle(at: spine)
            let estimated = estimatedGlobalPage(for: position) ?? 0
            BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) pageVCPosition placeholder spine=\(spine) estimated=\(estimated) title=\(title)")
            let placeholder = PlaceholderPageViewController(
                chapterTitle: title,
                globalPage: estimated,
                readingPosition: position,
                themeBackgroundColor: themeBackgroundColor,
                themeTextColor: themeTextColor
            )
            Task { [weak self] in
                guard let self else { return }
                await self.preloadChapter(at: spine)
                let stillBrowser: Bool
                switch self.choices[spine] {
                case .browser: stillBrowser = true
                case .legacyFallback, .legacyEngineFailure, nil: stillBrowser = false
                }
                guard stillBrowser, self.browserChapters[spine] != nil else { return }
                self.onChapterReady?(spine)
            }
            return placeholder
        case .legacyFallback, .legacyEngineFailure:
            return delegate.pageViewController(for: position)
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

    /// Selection/annotation/TTS contract: input a UTF-16 range in the
    /// chapter's sourceText, get per-page page-local rects (baseline-aligned
    /// text fragments intersecting the range). Rects remain source-range
    /// semantic across relayouts — the same range re-derives the same text.
    func rects(forSpine spineIndex: Int, range: NSRange) -> [(page: Int, rects: [CGRect])] {
        guard range.length > 0,
              case .browser = choices[spineIndex] ?? .browser,
              let layout = browserChapters[spineIndex] else {
            // Fallback chapters delegate selection to the legacy engine's own
            // mechanisms (out of scope for Phase 2B's browser contract).
            return []
        }
        let ns = layout.sourceText as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return [] }
        let rangeEnd = range.location + range.length

        var result: [(page: Int, rects: [CGRect])] = []
        for (pageIndex, page) in layout.pages.enumerated() {
            var pageRects: [CGRect] = []
            func walk(_ fragments: [Fragment]) {
                for fragment in fragments {
                    switch fragment {
                    case .text(let t):
                        guard t.sourceRange.length > 0 else { continue }
                        let start = max(t.sourceRange.location, range.location)
                        let end = min(t.sourceRange.location + t.sourceRange.length, rangeEnd)
                        guard end > start else { continue }
                        if let line = t.ctLine,
                           let rect = preciseRect(
                               fragment: t, line: line,
                               selection: NSRange(location: start, length: end - start)
                           ) {
                            pageRects.append(rect)
                            continue
                        }
                        // Proportional fallback (no line artifact, or the
                        // fragment's range was trimmed off the line's range).
                        let fraction = Double(end - start) / Double(t.sourceRange.length)
                        let selectedWidth = CGFloat(fraction) * t.rect.width
                        let xOffset = CGFloat(Double(start - t.sourceRange.location) / Double(t.sourceRange.length)) * t.rect.width
                        pageRects.append(CGRect(
                            x: t.rect.minX + xOffset,
                            y: t.rect.minY,
                            width: selectedWidth,
                            height: t.rect.height
                        ))
                    case .group(let children): walk(children)
                    default: break
                    }
                }
            }
            walk(page.fragments)
            if !pageRects.isEmpty {
                result.append((page: pageIndex, rects: pageRects))
            }
        }
        return result
    }

    /// Precise selection rect for a sub-range of one text fragment, using the
    /// fragment's shaped line: `CTLineGetOffsetForStringIndex` yields exact
    /// typographic offsets (kerning, ligatures, RTL, emoji ZWJ clusters,
    /// combining marks) instead of proportional width estimation.
    ///
    /// The fragment's `sourceRange` is a slice of the chapter source; the line's
    /// own string range (in attributed space) is `CTLineGetStringRange(line)`.
    /// They align for normal runs; when leading whitespace was trimmed the run's
    /// range shifts, and this helper returns nil so callers fall back to
    /// proportional rects (whitespace-only discrepancy).
    private func preciseRect(
        fragment t: TextFragment,
        line: CTLine,
        selection: NSRange
    ) -> CGRect? {
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.length > 0 else { return nil }
        let lineStart = lineRange.location
        let lineEnd = lineRange.location + lineRange.length

        // The fragment's run within the line: its source range must sit inside
        // the line's range for the line-space mapping to be exact. (Whitespace
        // trims shift run ranges; those fall back to proportional.)
        let fragStart = t.sourceRange.location
        let fragEnd = t.sourceRange.location + t.sourceRange.length
        guard fragStart >= lineStart, fragEnd <= lineEnd else { return nil }

        let selStart = selection.location
        let selEnd = selection.location + selection.length
        let startInLine = max(selStart, lineStart) - lineStart
        let endInLine = min(selEnd, lineEnd) - lineStart
        guard endInLine > startInLine else { return nil }

        let offsetStart = CTLineGetOffsetForStringIndex(line, startInLine, nil)
        let offsetEnd = CTLineGetOffsetForStringIndex(line, endInLine, nil)

        // Horizontal only for now: the fragment rect already encodes the run's
        // baseline-aligned horizontal placement. Vertical mapping arrives with
        // the vertical-rl writing mode (Phase 3B).
        let x = t.rect.minX + offsetStart
        let width = max(1, offsetEnd - offsetStart)
        return CGRect(x: x, y: t.rect.minY, width: width, height: t.rect.height)
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

    // MARK: - DisplayList window cache

    private func cachedDisplayList(globalPage: Int, spine: Int, local: Int, layout: BrowserChapterLayout) -> DisplayList {
        if let cached = displayListCache[globalPage] { return cached }
        let list = layout.displayList(forPage: local, themeTextColor: themeTextColor, oldThemeColor: layout.themeTextColor)
        displayListCache[globalPage] = list
        let bytes = Int64(list.items.count) * 96
        displayListCacheBytes[globalPage] = bytes
        if var stored = browserChapters[spine] {
            stored.displayListBytes += bytes
            browserChapters[spine] = stored
        }
        MemoryTracker.record(.displayList, bytes: bytes)
        evictDisplayLists(around: globalPage)
        return list
    }

    private func evictDisplayLists(around globalPage: Int) {
        let window = 2
        for (page, bytes) in displayListCacheBytes where abs(page - globalPage) > window {
            displayListCache.removeValue(forKey: page)
            displayListCacheBytes.removeValue(forKey: page)
            MemoryTracker.release(.displayList, bytes: bytes)
        }
    }

    private func evictAllDisplayLists() {
        for bytes in displayListCacheBytes.values {
            MemoryTracker.release(.displayList, bytes: bytes)
        }
        displayListCache.removeAll()
        displayListCacheBytes.removeAll()
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

    /// Short commit SHA of the build (debug overlay label).
    static var currentCommitSHA: String {
        #if DEBUG
        // Best-effort from the Info.plist build metadata; falls back to a
        // compile-time marker when unavailable.
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String, !sha.isEmpty {
            return String(sha.prefix(7))
        }
        return "unknown"
        #else
        return "release"
        #endif
    }

    /// Expected k1 border top in page-local coordinates: 25% of the body
    /// containing-block width. The body content width is the engine's content
    /// width (contentWidth), which the RedChamber CSS resolves to 358.68 for a
    /// 390pt viewport — 25% → 89.67.
    static func k1ExpectedTop(contentWidth: CGFloat) -> CGFloat {
        contentWidth * 0.25
    }

    /// k1's actual top as painted by the DisplayList: the first large
    /// non-body fill (15em cover box). Falls back to -1 when absent.
    static func k1DisplayListTop(in list: DisplayList) -> CGFloat {
        for item in list.items {
            if case .fill(let f) = item,
               f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 {
                return f.rect.minY
            }
        }
        return -1
    }

    /// k1's page-local rect from the DisplayList (for window conversion).
    static func k1PageLocalRect(in list: DisplayList) -> CGRect {
        for item in list.items {
            if case .fill(let f) = item,
               f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 {
                return f.rect.rect
            }
        }
        return .null
    }

    /// The largest full-width fill in the page (body background / page-level
    /// fill) — the body border rect approximation for the overlay.
    static func genericBodyRect(in list: DisplayList) -> CGRect? {
        var best: CGRect? = nil
        for item in list.items {
            if case .fill(let f) = item,
               f.rect.width > 300, f.rect.height > 100 {
                if best == nil || f.rect.width > best!.width {
                    best = f.rect.rect
                }
            }
        }
        return best
    }

    /// The first text fragment's rect (first line box) for the overlay.
    static func firstLineBoxRect(in list: DisplayList) -> CGRect? {
        for item in list.items {
            if case .text(let t) = item {
                return t.rect.rect
            }
        }
        return nil
    }
}

private extension BrowserLayoutResourceProviding {
    func chapterSourceHrefs() -> [String] {
        (0..<chapterCount).compactMap { chapterSourceHref(at: $0) }
    }
}
