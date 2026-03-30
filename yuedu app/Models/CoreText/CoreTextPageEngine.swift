import CoreText
import UIKit

@MainActor
final class CoreTextPageEngine: PageRenderingProvider {

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0

    private(set) var layouts: [Int: CoreTextPaginator.ChapterLayout] = [:]
    private var chapterSnapshots: [Int: UIImage] = [:]
    private var spinePageOffsets: [Int] = []
    private(set) var renderSize: CGSize = .zero

    private let session: PublicationSession
    private let builder: HTMLAttributedStringBuilder
    let paginator: CoreTextPaginator
    let offsetStore: CharOffsetStore

    private(set) var isRelaying = false

    init(
        session: PublicationSession,
        builder: HTMLAttributedStringBuilder = HTMLAttributedStringBuilder(),
        paginator: CoreTextPaginator = CoreTextPaginator(),
        offsetStore: CharOffsetStore
    ) {
        self.session = session
        self.builder = builder
        self.paginator = paginator
        self.offsetStore = offsetStore

        self.builder.imageLoader = { [weak session] href in
            guard let session else { return nil }
            guard let response = try? await session.response(
                for: session.resourceURL(for: href)
            ) else { return nil }
            return UIImage(data: response.data)
        }
    }

    func start(renderSize: CGSize, bookId: String) async {
        self.renderSize = renderSize
        print("[CoreTextEngine] start renderSize=\(renderSize) chapters=\(session.chapters.count)")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<min(3, session.chapters.count) {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }
        print("[CoreTextEngine] start done totalPages=\(totalPages)")

        if let record = offsetStore.load(bookId: bookId) {
            currentPage = pageIndex(forSpine: record.spineIndex, charOffset: record.charOffset)
        } else {
            migrateFromLegacyProgressIfNeeded(bookId: bookId)
        }
    }

    func pageViewController(at index: Int) -> UIViewController {
        let (spineIndex, localPage) = localPosition(for: index)
        if let layout = layouts[spineIndex] {
            let vc = CoreTextPageViewController()
            vc.configure(layout: layout, localPage: localPage, globalPage: index)
            return vc
        }
        let title = session.chapters.indices.contains(spineIndex)
            ? session.chapters[spineIndex].title
            : ""
        let placeholder = PlaceholderPageViewController(chapterTitle: title)
        Task { [weak self] in
            await self?.preloadChapter(at: spineIndex)
            NotificationCenter.default.post(
                name: .coreTextEngineChapterReady,
                object: self,
                userInfo: ["spineIndex": spineIndex]
            )
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
        let (spineIndex, localPage) = localPosition(for: page)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count else {
            return (spineIndex, 0)
        }
        return (spineIndex, Int(layout.pageRanges[localPage].location))
    }

    func preloadChapter(at spineIndex: Int) async {
        guard session.chapters.indices.contains(spineIndex),
              layouts[spineIndex] == nil else { return }
        guard let html = try? await session.chapterHTML(at: spineIndex) else {
            print("[CoreTextEngine] preloadChapter[\(spineIndex)] FAILED to get HTML")
            return
        }

        let chapterHref = session.chapters[spineIndex].href
        let localBuilder = HTMLAttributedStringBuilder()
        localBuilder.imageLoader = { [weak session] src in
            guard let session else { return nil }
            let resolved = Self.resolveImageHref(src, chapterHref: chapterHref)
            guard let response = try? await session.response(
                for: session.resourceURL(for: resolved)
            ) else { return nil }
            return UIImage(data: response.data)
        }

        let config = currentBuilderConfig()
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] htmlLen=\(html.count) fontSize=\(config.fontSize) renderSize=\(renderSize)")
        let attrStr = await localBuilder.build(html: html, config: config)
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] attrStrLen=\(attrStr.length)")
        let layout = await paginator.paginate(
            spineIndex: spineIndex,
            attrStr: attrStr,
            renderSize: renderSize,
            fontSize: config.fontSize
        )
        print("[CoreTextEngine] preloadChapter[\(spineIndex)] pageCount=\(layout.pageRanges.count)")
        layouts[spineIndex] = layout
        generateSnapshot(for: spineIndex)
        rebuildPageOffsets()
    }

    func invalidateLayout(newSize: CGSize) async {
        isRelaying = true
        renderSize = newSize
        paginator.invalidate(reason: .viewSizeChanged)
        layouts.removeAll()
        chapterSnapshots.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for i in session.chapters.indices {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }
        isRelaying = false
    }

    func warmUpNext(currentGlobalPage: Int) {
        let (spineIndex, localPage) = localPosition(for: currentGlobalPage)
        guard let layout = layouts[spineIndex] else { return }
        let total = layout.pageRanges.count
        // Trigger at 20% remaining (minimum 3 pages) so snapshot is ready before chapter boundary
        let threshold = max(3, Int(Double(total) * 0.20))
        let remaining = total - localPage
        if remaining <= threshold {
            let nextSpine = spineIndex + 1
            guard nextSpine < session.chapters.count else { return }
            Task { [weak self] in await self?.preloadChapter(at: nextSpine) }
        }
    }

    func snapshotViewController(at index: Int) -> UIViewController? {
        let (spineIndex, localPage) = localPosition(for: index)
        guard localPage == 0,
              let snapshot = chapterSnapshots[spineIndex] else { return nil }
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
            backgroundColor: bgColor
        )
    }

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        paginator.invalidate(reason: .themeChanged)
        chapterSnapshots.removeAll()
        for (spineIndex, layout) in layouts {
            let updated = NSMutableAttributedString(attributedString: layout.attributedString)
            let fullRange = NSRange(location: 0, length: updated.length)
            updated.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            updated.addAttribute(.backgroundColor, value: backgroundColor, range: fullRange)
            Task { [weak self] in
                guard let self else { return }
                let newLayout = await self.paginator.paginate(
                    spineIndex: spineIndex,
                    attrStr: updated,
                    renderSize: self.renderSize,
                    fontSize: layout.fontSize
                )
                self.layouts[spineIndex] = newLayout
                self.generateSnapshot(for: spineIndex)
            }
        }
    }

    // MARK: - Private helpers

    /// 將章節第 0 頁預渲染成 UIImage，存入 chapterSnapshots 以供跨章節動畫接力。
    /// 在 preloadChapter 完成後同步呼叫（MainActor）。
    private func generateSnapshot(for spineIndex: Int) {
        guard let layout = layouts[spineIndex],
              !layout.pageRanges.isEmpty,
              chapterSnapshots[spineIndex] == nil,
              renderSize.width > 0, renderSize.height > 0 else { return }

        let bgColor: UIColor
        if layout.attributedString.length > 0,
           let color = layout.attributedString.attribute(
               .backgroundColor, at: 0, effectiveRange: nil
           ) as? UIColor {
            bgColor = color
        } else {
            bgColor = .systemBackground
        }

        let size = renderSize
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1.0, y: -1.0)

            let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
            let frame = CTFramesetterCreateFrame(layout.framesetter, layout.pageRanges[0], path, nil)
            CTFrameDraw(frame, ctx)

            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.translateBy(x: 0, y: -size.height)

            if let imgRect = layout.imageRects[0], let img = layout.pageImages[0] {
                img.draw(in: imgRect)
            }
        }
        chapterSnapshots[spineIndex] = image
    }

    private func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
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
        var offset = 0
        spinePageOffsets = session.chapters.indices.map { i in
            let start = offset
            offset += layouts[i]?.pageRanges.count ?? 0
            return start
        }
        totalPages = offset
    }

    private func currentBuilderConfig() -> HTMLAttributedStringBuilder.Config {
        let gs = GlobalSettings.shared
        let fontSize = CGFloat(gs.readerFontSize)
        return HTMLAttributedStringBuilder.Config(
            fontSize: fontSize,
            lineSpacing: CGFloat(gs.lineSpacing),
            paragraphSpacing: CGFloat(gs.paragraphSpacing),
            firstLineIndent: fontSize * 2,
            textColor: currentTextColor(),
            backgroundColor: currentBackgroundColor(),
            fontFamilyName: nil,
            renderWidth: renderSize.width - CGFloat(gs.pageMarginH) * 2
        )
    }

    /// Returns appropriate text color. GlobalSettings does not expose a theme enum,
    /// so we fall back to the system adaptive label color which respects dark/light mode.
    private func currentTextColor() -> UIColor {
        .label
    }

    /// Returns appropriate background color using the system adaptive background color.
    private func currentBackgroundColor() -> UIColor {
        .systemBackground
    }

    /// 將 HTML img src（可能是相對路徑）解析成相對於章節 href 的絕對 EPUB 路徑。
    /// 例：chapterHref="OEBPS/Text/ch01.xhtml", src="../Images/fig.jpg" → "OEBPS/Images/fig.jpg"
    private static func resolveImageHref(_ src: String, chapterHref: String) -> String {
        guard !src.isEmpty,
              !src.hasPrefix("http://"),
              !src.hasPrefix("https://"),
              !src.hasPrefix("data:") else { return src }
        if src.hasPrefix("/") { return String(src.dropFirst()) }
        let baseStr = "x://b/" + chapterHref
        guard let base = URL(string: baseStr),
              let resolved = URL(string: src, relativeTo: base)?.standardized else { return src }
        let path = resolved.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func migrateFromLegacyProgressIfNeeded(bookId: String) {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let progressDir = docsURL.appendingPathComponent("epub_progress/\(bookId)")
        let legacyStore = EPUBProgressStore(directoryURL: progressDir)
        guard let locator = legacyStore.loadLastRecord() else { return }

        let spineIndex = locator.chapterIndex
        guard let layout = layouts[spineIndex] else { return }
        let progression = locator.chapterProgression ?? locator.progression
        let charOffset = Int(progression * Double(layout.attributedString.length))
        currentPage = pageIndex(forSpine: spineIndex, charOffset: charOffset)
    }
}

extension Notification.Name {
    static let coreTextEngineChapterReady = Notification.Name("CoreTextEngineChapterReady")
}
