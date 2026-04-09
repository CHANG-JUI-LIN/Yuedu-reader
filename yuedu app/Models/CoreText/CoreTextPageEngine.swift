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

@MainActor
final class CoreTextPageEngine: PageRenderingProvider {
    private struct RegisteredFontFace {
        let alias: String
        let familyName: String
        let postScriptName: String
    }

    private(set) var totalPages: Int = 0
    private(set) var currentPage: Int = 0

    private(set) var layouts: [Int: CoreTextPaginator.ChapterLayout] = [:]
    private let chapterSnapshots: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 5
        return cache
    }()
    private var spinePageOffsets: [Int] = []
    private(set) var renderSize: CGSize = .zero
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    private var layoutGeneration: Int = 0

    private let resourceProvider: any BookResourceProvider
    private let paginationManager: PaginationManager
    private let fontRegistrationService: any FontRegistrationServicing
    let offsetStore: CharOffsetStore
    private var registeredFontFaces: [String: RegisteredFontFace] = [:]
    private var registeredFontFileURLs: [String: URL] = [:]
    private var renderSettings: ReaderRenderSettings

    private var currentBookId: String?
    /// 各章節的原始 Data 大小（bytes），用於全書進度估算
    private var chapterByteSizes: [Int] = []

    private(set) var isRelaying = false

    private var themeTextColor: UIColor = .label
    private var themeBackgroundColor: UIColor = .systemBackground
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?

    deinit {
        for url in registeredFontFileURLs.values {
            fontRegistrationService.cleanupTemporaryFile(at: url)
        }
    }

    init(
        resourceProvider: any BookResourceProvider,
        renderSettings: ReaderRenderSettings,
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService(),
        paginationManager: PaginationManager? = nil,
        offsetStore: CharOffsetStore
    ) {
        self.resourceProvider = resourceProvider
        self.renderSettings = renderSettings
        self.fontRegistrationService = fontRegistrationService
        self.paginationManager = paginationManager ?? PaginationManager()
        self.offsetStore = offsetStore
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

    func start(renderSize: CGSize, bookId: String) async {
        self.renderSize = renderSize
        self.currentBookId = bookId
        print("[CoreTextEngine] start renderSize=\(renderSize) chapters=\(resourceProvider.chapters.count)")

        // 1. 掃描全書章節 Data 大小（秒完，用於 Bytes 進度估算）
        await scanChapterByteSizes()

        // 2. 讀存檔 → 決定優先載入哪些章節
        let record = offsetStore.load(bookId: bookId)
        let savedSpine = record?.spineIndex ?? 0

        // 3. 載入存檔鄰域 [n-1, n, n+1]（+ 第 0 章如果不在範圍內）
        var priority = Set<Int>()
        priority.insert(0) // 封面/目錄始終需要
        for i in max(0, savedSpine - 1)...min(savedSpine + 1, resourceProvider.chapters.count - 1) {
            priority.insert(i)
        }

        await withTaskGroup(of: Void.self) { group in
            for i in priority.sorted() {
                group.addTask { await self.preloadChapter(at: i) }
            }
        }
        print("[CoreTextEngine] start done totalPages=\(totalPages)")

        // 4. 恢復位置（存檔章節已載入，不會 fallback 到 0）
        if let record {
            currentPage = pageIndex(forSpine: record.spineIndex, charOffset: record.charOffset)
        } else {
            migrateFromLegacyProgressIfNeeded(bookId: bookId)
        }
    }

    private func scanChapterByteSizes() async {
        chapterByteSizes = await withTaskGroup(of: (Int, Int).self) { group in
            for i in resourceProvider.chapters.indices {
                group.addTask {
                    let size = (try? await self.resourceProvider.chapterDataSize(at: i)) ?? 0
                    return (i, size)
                }
            }
            var sizes = [Int](repeating: 0, count: resourceProvider.chapters.count)
            for await (idx, size) in group { sizes[idx] = size }
            return sizes
        }
    }

    /// 全書進度（0.0 ~ 1.0）= (前 N-1 章總 Bytes + 當前章 charOffset) / 全書總 Bytes
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        guard !chapterByteSizes.isEmpty else { return 0 }
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

    /// 釋放距離當前章超過 1 的 layout，記憶體只保留 [n-1, n, n+1]
    private func evictDistantChapters(currentSpine: Int) {
        let keep = Set(max(0, currentSpine - 1)...min(currentSpine + 1, resourceProvider.chapters.count - 1))
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
        guard resourceProvider.chapters.indices.contains(spineIndex),
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
        let title = resourceProvider.chapters.indices.contains(spineIndex)
            ? resourceProvider.chapters[spineIndex].title
            : ""
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
        guard spinePageOffsets.indices.contains(spineIndex),
              let layout = layouts[spineIndex] else { return 0 }
        let localPage = layout.pageIndex(for: charOffset)
        return spinePageOffsets[spineIndex] + localPage
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
        guard resourceProvider.chapters.indices.contains(position.spineIndex) else {
            return pageViewController(at: 0)
        }

        if let globalPage = pageIndex(for: position) {
            return pageViewController(at: globalPage)
        }

        let title = resourceProvider.chapters[position.spineIndex].title
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
        guard resourceProvider.chapters.indices.contains(spineIndex) else { return }
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
        guard resourceProvider.chapters.indices.contains(spineIndex),
              layouts[spineIndex] == nil else { return }
        guard !shouldAbortPreload(generation: generation) else { return }

        if spineIndex == 0 {
            let cssHrefs = resourceProvider.cssResourceHrefs()
            print("[CoreTextEngine] Publication CSS hrefs: \(cssHrefs)")
        }

        guard let html = try? await resourceProvider.chapterHTML(at: spineIndex) else {
            print("[CoreTextEngine] preloadChapter[\(spineIndex)] FAILED to get HTML")
            return
        }
        guard !shouldAbortPreload(generation: generation) else { return }

        let chapterHref = resourceProvider.chapters[spineIndex].href
        let localBuilder = HTMLAttributedStringBuilder()
        localBuilder.resolvedFont = { [weak self] families, weight, italic, size in
            self?.resolveRegisteredFont(
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
            return self.registeredFontFaces[normalized]?.postScriptName
                ?? self.registeredFontFaces[normalized]?.familyName
        }
        localBuilder.imageLoader = { [weak self] src in
            guard let self else { return nil }
            return await self.loadImageResource(from: src, chapterHref: chapterHref)
        }
        localBuilder.cssLoader = { [weak resourceProvider] href in
            guard let resourceProvider else { return nil }
            let resolved = Self.resolveImageHref(href, chapterHref: chapterHref)
            let url = resourceProvider.resourceURL(for: resolved)
            print("[CoreTextEngine] cssLoader href=\(href) → resolved=\(resolved) → url=\(url)")
            do {
                let response = try await resourceProvider.response(for: url)
                let cssText = String(data: response.data, encoding: .utf8) ?? ""
                let processed = await self.processStylesheet(cssText, cssHref: resolved, chapterHref: chapterHref)
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
            candidates.append(Self.resolveImageHref(source, chapterHref: chapterHref))
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
            currentPage = pageIndex(forSpine: record.spineIndex, charOffset: record.charOffset)
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
            let resolvedHref = Self.resolveImageHref(rawPath, chapterHref: resourceProvider.chapters[spineIndex].href)
            guard let matchedIndex = resourceProvider.chapterIndex(for: resolvedHref) else {
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
            if nextSpine < resourceProvider.chapters.count {
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
        guard localPage == 0,
              let snapshot = chapterSnapshots.object(forKey: NSNumber(value: spineIndex)) else { return nil }
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
        // 在背景重建各章節的快照（用於跨章節動畫）
        for spineIndex in layouts.keys {
            if let layout = layouts[spineIndex] {
                Task { [weak self] in
                    guard let self else { return }
                    self.chapterSnapshots.setObject(self.renderImage(layout: layout, pageIndex: 0), forKey: NSNumber(value: spineIndex))
                }
            }
        }
    }

    /// 離屏渲染任意全局頁為 UIImage，供 cover 動畫即時快照使用。
    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        let (spineIndex, localPage) = localPosition(for: globalPage)
        guard let layout = layouts[spineIndex],
              localPage < layout.pageRanges.count,
              renderSize.width > 0, renderSize.height > 0 else { return nil }
        return renderImage(layout: layout, pageIndex: localPage)
    }

    // MARK: - Private helpers

    /// 將章節第 0 頁預渲染成 UIImage，存入 chapterSnapshots 以供跨章節動畫接力。
    /// 在 preloadChapter 完成後同步呼叫（MainActor）。
    private func generateSnapshot(for spineIndex: Int) {
        guard let layout = layouts[spineIndex],
              !layout.pageRanges.isEmpty,
              chapterSnapshots.object(forKey: NSNumber(value: spineIndex)) == nil,
              renderSize.width > 0, renderSize.height > 0 else { return }
        chapterSnapshots.setObject(renderImage(layout: layout, pageIndex: 0), forKey: NSNumber(value: spineIndex))
    }

    private func renderImage(layout: CoreTextPaginator.ChapterLayout, pageIndex: Int) -> UIImage {
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
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(bgColor.cgColor)
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
        let oldOffsets = spinePageOffsets
        var offset = 0
        spinePageOffsets = resourceProvider.chapters.indices.map { i in
            let start = offset
            // 未載入章節估 1 頁，確保 spinePageOffsets 和 totalPages 不崩壞
            offset += layouts[i]?.pageRanges.count ?? 1
            return start
        }
        totalPages = offset
        
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

    private func currentContentInsets() -> UIEdgeInsets {
        renderSettings.contentInsets
    }

    private func currentBuilderConfig() -> HTMLAttributedStringBuilder.Config {
        let fontSize = renderSettings.fontSize
        let horizontalInsets = renderSettings.contentInsets.left + renderSettings.contentInsets.right
        return HTMLAttributedStringBuilder.Config(
            fontSize: fontSize,
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

    private func processStylesheet(_ cssText: String, cssHref: String, chapterHref: String) async -> String {
        let withImports = await inlineLocalImports(from: cssText, cssHref: cssHref, chapterHref: chapterHref, visited: [cssHref])
        let fontFaces = extractFontFaces(from: withImports, cssHref: cssHref, chapterHref: chapterHref)
        if !fontFaces.isEmpty {
            print("[CoreTextEngine] discovered font faces: \(fontFaces.map { $0.alias })")
        }

        for fontFace in fontFaces {
            if registeredFontFaces[fontFace.alias] != nil { continue }
            guard
                let fontURL = URL(string: fontFace.resolvedURL),
                let response = try? await resourceProvider.response(for: fontURL),
                let registeredFont = fontRegistrationService.registerFont(
                    data: response.data,
                    alias: fontFace.alias,
                    existingTempURL: registeredFontFileURLs[fontFace.alias]
                )
            else {
                print("[CoreTextEngine] font registration FAILED alias=\(fontFace.alias)")
                continue
            }
            if let tempFileURL = registeredFont.tempFileURL {
                registeredFontFileURLs[fontFace.alias] = tempFileURL
            }
            registeredFontFaces[fontFace.alias] = RegisteredFontFace(
                alias: fontFace.alias,
                familyName: registeredFont.familyName,
                postScriptName: registeredFont.postScriptName
            )
            print("[CoreTextEngine] registered font alias=\(fontFace.alias) -> family=\(registeredFont.familyName) ps=\(registeredFont.postScriptName)")
        }

        let stripped = stripFontFaceBlocks(from: withImports)
        let withRewrittenURLs = rewriteResourceURLs(in: stripped, cssHref: cssHref)
        return rewriteFontFamilies(in: withRewrittenURLs)
    }

    private func inlineLocalImports(from cssText: String, cssHref: String, chapterHref: String, visited: Set<String>) async -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"@import\s+(?:url\()?['"]?([^'")]+)['"]?\)?\s*;"#,
            options: [.caseInsensitive]
        ) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText

        for match in matches.reversed() {
            let rawHref = nsCSS.substring(with: match.range(at: 1))
            if rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                print("[CoreTextEngine] ignoring remote @import \(rawHref)")
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            let resolved = Self.resolveCSSHref(rawHref, cssHref: cssHref, chapterHref: chapterHref)
            if visited.contains(resolved) {
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            guard
                let response = try? await resourceProvider.response(for: resourceProvider.resourceURL(for: resolved)),
                let imported = String(data: response.data, encoding: .utf8)
            else {
                print("[CoreTextEngine] local @import FAILED \(resolved)")
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            let inlined = await inlineLocalImports(from: imported, cssHref: resolved, chapterHref: chapterHref, visited: visited.union([resolved]))
            result = (result as NSString).replacingCharacters(in: match.range, with: inlined)
        }

        return result
    }

    private func rewriteResourceURLs(in cssText: String, cssHref: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#,
            options: [.caseInsensitive]
        ) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText
        for match in matches.reversed() {
            let rawHref = nsCSS.substring(with: match.range(at: 1))
            if rawHref.hasPrefix("data:") || rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                continue
            }
            let resolved = Self.resolveCSSRelativePath(rawHref, cssHref: cssHref)
            let absolute = resourceProvider.resourceURL(for: resolved).absoluteString
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: absolute)
        }
        return result
    }

    private func extractFontFaces(from cssText: String, cssHref: String, chapterHref: String) -> [(alias: String, resolvedURL: String)] {
        guard
            let blockRegex = try? NSRegularExpression(pattern: #"@font-face\s*\{.*?\}"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let familyRegex = try? NSRegularExpression(pattern: #"font-family\s*:\s*['"]?([^;'"}]+)['"]?"#, options: [.caseInsensitive]),
            let srcRegex = try? NSRegularExpression(pattern: #"src\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)"#, options: [.caseInsensitive])
        else {
            return []
        }

        let nsCSS = cssText as NSString
        return blockRegex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length)).compactMap { match in
            let block = nsCSS.substring(with: match.range)
            let nsBlock = block as NSString
            guard
                let familyMatch = familyRegex.firstMatch(in: block, range: NSRange(location: 0, length: nsBlock.length)),
                let srcMatch = srcRegex.firstMatch(in: block, range: NSRange(location: 0, length: nsBlock.length))
            else {
                print("[CoreTextEngine] unable to parse @font-face block: \(block)")
                return nil
            }
            let alias = Self.normalizeFontName(nsBlock.substring(with: familyMatch.range(at: 1)))
            let rawURL = nsBlock.substring(with: srcMatch.range(at: 1))
            let resolvedHref = Self.resolveCSSHref(rawURL, cssHref: cssHref, chapterHref: chapterHref)
            let resolvedURL = resourceProvider.resourceURL(for: resolvedHref).absoluteString
            return alias.isEmpty ? nil : (alias, resolvedURL)
        }
    }

    private func stripFontFaceBlocks(from cssText: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"@font-face\s*\{.*?\}"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return cssText
        }
        return regex.stringByReplacingMatches(in: cssText, range: NSRange(location: 0, length: (cssText as NSString).length), withTemplate: "")
    }

    private func rewriteFontFamilies(in cssText: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"font-family\s*:\s*([^;}{]+)"#, options: [.caseInsensitive]) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText
        for match in matches.reversed() {
            let familyList = nsCSS.substring(with: match.range(at: 1))
            let rewritten = familyList
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { part in
                    let normalized = Self.normalizeFontName(String(part))
                    if let registered = registeredFontFaces[normalized] {
                        return "\"\(registered.familyName)\""
                    }
                    return String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .joined(separator: ", ")
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: rewritten)
        }
        return result
    }

    /// 將 HTML img src（可能是相對路徑）解析成相對於章節 href 的絕對 EPUB 路徑。
    /// 例：chapterHref="OEBPS/Text/ch01.xhtml", src="../Images/fig.jpg" → "OEBPS/Images/fig.jpg"
    ///
    /// 注意：不能用 URL(string:relativeTo:).standardized，因為 Swift 對非 file:// 的自定義
    /// scheme URL 不能正確解析 ".." 段，必須用純字串路徑運算。
    private static func resolveImageHref(_ src: String, chapterHref: String) -> String {
        guard !src.isEmpty,
              !src.hasPrefix("http://"),
              !src.hasPrefix("https://"),
              !src.hasPrefix("data:") else { return src }
        if src.hasPrefix("/") { return String(src.dropFirst()) }

        // 取章節所在目錄，與 src 拼接後用堆疊法解析 . / ..
        let dir = (chapterHref as NSString).deletingLastPathComponent
        let combined = dir.isEmpty ? src : dir + "/" + src

        var stack: [String] = []
        for seg in combined.components(separatedBy: "/") {
            switch seg {
            case "", ".": break
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(seg)
            }
        }
        return stack.joined(separator: "/")
    }

    private static func resolveCSSHref(_ href: String, cssHref: String, chapterHref: String) -> String {
        if cssHref.isEmpty {
            return resolveImageHref(href, chapterHref: chapterHref)
        }
        return resolveCSSRelativePath(href, cssHref: cssHref)
    }

    private static func resolveCSSRelativePath(_ href: String, cssHref: String) -> String {
        guard !href.isEmpty,
              !href.hasPrefix("http://"),
              !href.hasPrefix("https://"),
              !href.hasPrefix("data:") else { return href }
        if href.hasPrefix("/") { return String(href.dropFirst()) }

        let dir = (cssHref as NSString).deletingLastPathComponent
        let combined = dir.isEmpty ? href : dir + "/" + href
        var stack: [String] = []
        for segment in combined.components(separatedBy: "/") {
            switch segment {
            case "", ".":
                break
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(segment)
            }
        }
        return stack.joined(separator: "/")
    }

    private static func normalizeFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .lowercased()
    }

    private func resolveRegisteredFont(
        families: [String],
        weight: Int,
        italic: Bool,
        size: CGFloat
    ) -> UIFont? {
        let normalizedFamilies = families
            .map(Self.normalizeFontName)
            .filter { !$0.isEmpty }

        for family in normalizedFamilies {
            let matchedFace = registeredFontFaces[family]
                ?? registeredFontFaces.values.first(where: {
                    Self.normalizeFontName($0.familyName) == family
                        || Self.normalizeFontName($0.postScriptName) == family
                })
            guard let matchedFace else { continue }

            let baseFont =
                UIFont(name: matchedFace.postScriptName, size: size)
                ?? UIFont(name: matchedFace.familyName, size: size)
            guard let baseFont else { continue }

            var descriptor = baseFont.fontDescriptor
            var traits = descriptor.symbolicTraits
            if italic {
                traits.insert(.traitItalic)
            }
            if weight >= 600 {
                traits.insert(.traitBold)
            }
            if let styledDescriptor = descriptor.withSymbolicTraits(traits) {
                descriptor = styledDescriptor
            }
            descriptor = descriptor.addingAttributes([.cascadeList: fontCascadeDescriptors()])
            return UIFont(descriptor: descriptor, size: size)
        }

        return nil
    }

    private func fontCascadeDescriptors() -> [UIFontDescriptor] {
        ["PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
            .compactMap { UIFontDescriptor(name: $0, size: 0) }
    }

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
        guard let layout = layouts[spineIndex] else { return }
        let progression = locator.chapterProgression ?? locator.progression
        let charOffset = Int(progression * Double(layout.attributedString.length))
        currentPage = pageIndex(forSpine: spineIndex, charOffset: charOffset)
    }
}
