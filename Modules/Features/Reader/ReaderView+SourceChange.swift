import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Source Change Sheet
    var changeSourceSheetContent: AnyView {
        AnyView(NavigationStack {
            List {
                // 目前使用中的書源 — always visible with a checkmark so the user knows
                // which source is active (search results below exclude this one).
                Section(localized("目前書源")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentSourceName)
                                .foregroundColor(.primary)
                            if let last = book?.onlineChapters?.last?.title, !last.isEmpty {
                                Text(last)
                                    .font(DSFont.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(DSFont.body.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                }

                // 其他可切換的書源。Results stream in one source at a time, so show them
                // as soon as the first match arrives instead of blocking on the full
                // fan-out (459 sources can take minutes).
                Section {
                    if !changeSourceOrigins.isEmpty {
                        ForEach(changeSourceOrigins) { origin in
                            Button { switchToOrigin(origin) } label: { changeSourceRow(origin) }
                        }
                        if changeSourceLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(localized("正在搜尋更多書源…"))
                                    .font(DSFont.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if changeSourceLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(localized("正在搜尋其他書源…"))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(localized("暫無其他書源"))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(localized("其他書源"))
                } footer: {
                    if let err = changeSourceError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("換源"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        loadOtherOrigins(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(changeSourceLoading)
                    .accessibilityLabel(localized("重新搜尋"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("關閉")) { showChangeSourceSheet = false }
                }
            }
        })
    }

    /// A single switchable-origin row; flags origins that previously failed to switch.
    @ViewBuilder
    func changeSourceRow(_ origin: BookOrigin) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.sourceName)
                    .foregroundColor(.primary)
                // Aggregation sources share one sourceName across channels;
                // lastChapter distinguishes them.
                if !origin.lastChapter.isEmpty {
                    Text(origin.lastChapter)
                        .font(DSFont.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if changeSourceFailedKeys.contains(ChangeSourceCache.urlKey(origin.bookUrl)) {
                Text(localized("載入失敗"))
                    .font(DSFont.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            } else {
                Image(systemName: "chevron.right")
                    .font(DSFont.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Switches the book to the chosen origin. On success dismisses the sheet and
    /// reloads; on failure flags the origin (persisted) and keeps the sheet open so
    /// the user can try another.
    ///
    /// Reading position: the raw chapter index means different things in different
    /// sources (extra 卷 headers, merged 序章 …), so before reloading, the current
    /// chapter is re-located in the new TOC via `ChapterAlignment` (title
    /// similarity + chapter-number match, Legado getDurChapter-style) and the
    /// restore target/persisted position are updated to the mapped chapter.
    func switchToOrigin(_ origin: BookOrigin) {
        let oldRefs = book?.onlineChapters ?? []
        let oldIndex = currentChapterIndex
        let livePosition = readerSessionCoordinator?.state.location.coreTextPosition
        Task {
            do {
                try await store.updateOnlineBookSource(bookId: bookId, origin: origin)
                let mappedPosition: CoreTextReadingPosition? = await MainActor.run {
                    let newRefs = store.books.first(where: { $0.id == bookId })?.onlineChapters ?? []
                    guard !oldRefs.isEmpty, !newRefs.isEmpty else { return nil }
                    let mapped = ChapterAlignment.mappedChapterIndex(
                        oldIndex: oldIndex,
                        oldTitle: oldRefs.indices.contains(oldIndex) ? oldRefs[oldIndex].title : nil,
                        oldCount: oldRefs.count,
                        newTitles: newRefs.map(\.title)
                    )
                    // Same chapter text in a new source starts at a different
                    // offset anyway; only a same-index mapping keeps the offset.
                    let keepOffset = (mapped == oldIndex && livePosition?.spineIndex == oldIndex)
                        ? max(0, livePosition?.charOffset ?? 0)
                        : 0
                    let position = CoreTextReadingPosition(spineIndex: mapped, charOffset: keepOffset)
                    savedCoreTextRestoreTarget = (mapped, keepOffset)
                    setCoreTextExternalTarget(position)
                    currentChapterIndex = mapped
                    scrollVisibleChapter = mapped
                    return position
                }
                // Persist before loadContent so any restore path that re-reads the
                // position store already sees the mapped chapter.
                if let mappedPosition {
                    let storeKey = book?.id.uuidString ?? bookId.uuidString
                    await dependencies.readingPositionStore.save(mappedPosition, for: storeKey)
                }
                await MainActor.run {
                    showChangeSourceSheet = false
                    loadContent()
                }
            } catch {
                await MainActor.run {
                    readerViewModel.markOriginFailed(bookId: bookId, bookUrl: origin.bookUrl)
                    readerViewModel.reportChangeSourceError(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    func circleBtn(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DSFont.fixed(size: 18, weight: .light))
                .foregroundColor(readerTheme.textColor.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(Color.clear)
                .clipShape(Circle())
                .overlay(Circle().stroke(readerTheme.textColor.opacity(0.3), lineWidth: 1))
        }
    }

    /// Looks up the chapter title for a given progress value (0–1), used for the drag HUD.
    func chapterTitle(forProgress value: Double) -> String {
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        if book?.isOnline == true && totalChapters > 0 {
            let targetIndex = max(0, min(Int(round(value * Double(totalChapters - 1))), totalChapters - 1))
            if let refs = book?.onlineChapters, refs.indices.contains(targetIndex) {
                return refs[targetIndex].title
            }
            return chapters.indices.contains(targetIndex) ? chapters[targetIndex].title : ""
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.position(forProgress: value)
            if let chapter = tocChapter(forSpineIndex: pos.spineIndex, charOffset: pos.charOffset) {
                return chapter.title
            }
        }
        guard allPages.count > 1 else { return chapters.first?.title ?? "" }
        let pageIdx = max(0, min(Int(value * Double(allPages.count - 1)), allPages.count - 1))
        let chIdx = allPages[pageIdx].chapterIndex
        if chapters.indices.contains(chIdx) { return chapters[chIdx].title }
        return ""
    }

    func chapterSliderProgressValue() -> Double {
        // Scroll mode: approximate using chapter index (chunks may not be fully loaded, no reliable character count).
        if effectiveScrollMode {
            let total = max(chapters.count - 1, 1)
            return Double(min(scrollVisibleChapter, total)) / Double(total)
        }
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        guard totalChapters > 1 else { return 0 }
        if book?.isOnline == true {
            return Double(currentChapterIndex) / Double(totalChapters - 1)
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.charOffset(forPage: currentPage)
            return engine.totalProgress(forSpine: pos.spineIndex, charOffset: pos.charOffset)
        }
        guard allPages.count > 1 else { return 0 }
        return Double(currentPage) / Double(allPages.count - 1)
    }

    func applyChapterSliderProgress(_ value: Double) {
        // Scroll mode: round to nearest chapter, then reslice the engine.
        if effectiveScrollMode, let scrollEngine = epubRenderer.scrollEngine {
            let total = max(chapters.count - 1, 1)
            let target = max(0, min(Int(round(value * Double(total))), total))
            scrollVisibleChapter = target
            currentChapterIndex = target
            let width = scrollEngine.contentWidth
            Task { await scrollEngine.reslice(restoreAt: target, contentWidth: width) }
            return
        }
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        if book?.isOnline == true && totalChapters > 1 {
            let targetIndex = max(0, min(Int(round(value * Double(totalChapters - 1))), totalChapters - 1))
            jumpToChapter(targetIndex)
            return
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.position(forProgress: value)
            jumpToChapter(pos.spineIndex, charOffset: pos.charOffset)
            return
        }
        currentPage = max(
            0,
            min(
                Int(value * Double(max(allPages.count - 1, 1))),
                max(allPages.count - 1, 0)
            )
        )
    }

    func currentTTSReaderPosition() -> CoreTextReadingPosition? {
        if effectiveScrollMode {
            if let location = readerSessionCoordinator?.state.location.coreTextPosition {
                return location
            }
            return CoreTextReadingPosition(spineIndex: scrollVisibleChapter, charOffset: 0)
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            guard engine.totalPages > 0 else { return nil }
            let page = max(0, min(currentPage, engine.totalPages - 1))
            return engine.readingPosition(forPage: page)
                ?? CoreTextReadingPosition(
                    spineIndex: engine.charOffset(forPage: page).spineIndex,
                    charOffset: engine.charOffset(forPage: page).charOffset
                )
        }

        guard !allPages.isEmpty else {
            return chapters.indices.contains(currentChapterIndex)
                ? CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
                : nil
        }
        let page = allPages[max(0, min(currentPage, allPages.count - 1))]
        return CoreTextReadingPosition(spineIndex: page.chapterIndex, charOffset: page.pageInChapter)
    }

    func isReaderAtTTSAnchor(_ anchor: CoreTextReadingPosition) -> Bool {
        if effectiveScrollMode {
            return currentChapterIndex == anchor.spineIndex
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB,
           let anchorPage = engine.pageIndex(for: anchor) {
            return currentPage == anchorPage
        }

        guard let current = currentTTSReaderPosition() else { return false }
        return current == anchor
    }

    func setActiveTTSAnchor(_ anchor: CoreTextReadingPosition, alignReader: Bool) {
        ttsPlaybackAnchor = anchor
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        if alignReader {
            alignReaderToTTSAnchorIfNeeded()
        }
    }

    func alignReaderToTTSAnchorIfNeeded() {
        guard readerHeaderFooterEditorModel == nil,
              let anchor = ttsPlaybackAnchor,
              chapters.indices.contains(anchor.spineIndex),
              !isReaderAtTTSAnchor(anchor)
        else { return }

        isAligningReaderToTTSAnchor = true
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        jumpToChapter(anchor.spineIndex, charOffset: anchor.charOffset)
        DispatchQueue.main.async {
            isAligningReaderToTTSAnchor = false
        }
    }

    /// Keeps the paged reader on the sentence TTS is currently speaking. Called on
    /// every spoken-segment change. Moves the playback anchor to the spoken text and
    /// turns the page only when that text now sits on a different page. Paged CoreText
    /// mode only — scroll mode and the "jump back to TTS" browse state are left alone.
    func followTTSPlaybackHighlight() {
        guard readerHeaderFooterEditorModel == nil,
              ttsCoordinator.playbackState == .playing,
              !showTTSJumpPrompt,            // user navigated away — let them browse
              !effectiveScrollMode,
              let engine = epubRenderer.engine, usesCoreTextEPUB
        else { return }

        let chapterIndex = ttsChapterIndex ?? currentChapterIndex
        guard chapters.indices.contains(chapterIndex),
              let layout = engine.layouts[chapterIndex],
              layout.attributedString.length > 0
        else { return }

        let text = ttsCoordinator.currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Locate the spoken sentence inside the chapter string. Search forward from
        // the current page start so a repeated sentence resolves to the occurrence
        // actually being read (TTS always moves forward through the chapter).
        let ns = layout.attributedString.string as NSString
        let pageStart = engine.charOffset(forPage: currentPage)
        let searchStart = pageStart.spineIndex == chapterIndex
            ? min(max(0, pageStart.charOffset), ns.length)
            : 0
        var found = ns.range(
            of: text,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: NSRange(location: searchStart, length: ns.length - searchStart)
        )
        if found.location == NSNotFound {
            found = ns.range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
        }
        guard found.location != NSNotFound else { return }

        setActiveTTSAnchor(
            CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: found.location),
            alignReader: true
        )
    }

    func handleTTSPlayPause() {
        switch ttsCoordinator.playbackState {
        case .playing:
            ttsCoordinator.pause()
        case .paused:
            ttsCoordinator.resume()
        case .stopped:
            let startOffset = currentTTSReaderPosition()
                .map { $0.spineIndex == currentChapterIndex ? $0.charOffset : 0 } ?? 0
            startTTSChapter(currentChapterIndex, syncReader: false, startCharOffset: startOffset)
        }
    }

    func openPlaybackPanel() {
        let chapterIndex = currentChapterIndex
        if isEPUB, epubRenderer.mediaOverlaysByChapter[chapterIndex] != nil {
            activeMediaOverlayChapterIndex = chapterIndex
            showMediaOverlayPanel = true
        } else {
            showTTSPanel = true
        }
    }

    func currentMediaOverlayHighlightText() -> String? {
        guard let chapterIndex = mediaOverlayCoordinator.currentChapterIndex,
              let fragment = mediaOverlayCoordinator.currentFragment,
              let overlay = epubRenderer.mediaOverlaysByChapter[chapterIndex],
              let layout = epubRenderer.engine?.layouts[chapterIndex],
              layout.attributedString.length > 0
        else {
            return mediaOverlayCoordinator.currentFragment?.textFragmentID
                ?? mediaOverlayCoordinator.currentFragment?.id
        }

        let anchorID = fragment.textFragmentID ?? fragment.id
        guard let start = layout.anchorOffsets[anchorID],
              start >= 0,
              start < layout.attributedString.length
        else {
            return anchorID
        }

        let nextStart = overlay.fragments
            .compactMap { next -> Int? in
                guard next.id != fragment.id else { return nil }
                let nextID = next.textFragmentID ?? next.id
                guard let offset = layout.anchorOffsets[nextID], offset > start else { return nil }
                return offset
            }
            .min()
        let end = min(nextStart ?? min(layout.attributedString.length, start + 180), layout.attributedString.length)
        guard end > start else { return anchorID }

        let text = (layout.attributedString.string as NSString)
            .substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? anchorID : text
    }

    func setTTSFloatingOverlayVisible(_ visible: Bool) {
        Task { @MainActor in
            NowPlayingHub.shared.setReaderOverlayVisible(visible)
        }
    }

    @discardableResult
    func startTTSChapter(_ chapterIndex: Int, syncReader: Bool, startCharOffset: Int = 0) -> Bool {
        guard chapters.indices.contains(chapterIndex) else { return false }
        let shouldSyncReader = syncReader && readerHeaderFooterEditorModel == nil
        mediaOverlayCoordinator.stop()
        let narration = narrationForTTSChapter(chapterIndex)
        var text = narration.text
        var hints = narration.pronunciationHints
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLogger.render("[TTS][Reader] startTTSChapter ignored empty chapter=\(chapterIndex)")
            if shouldSyncReader {
                jumpToChapter(chapterIndex)
            }
            ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
            return false
        }

        if startCharOffset > 0, startCharOffset < (text as NSString).length {
            let nsText = text as NSString
            text = nsText.substring(from: startCharOffset)
            hints = hints.compactMap { hint in
                let shifted = NSRange(location: hint.range.location - startCharOffset, length: hint.range.length)
                guard shifted.location >= 0,
                      NSMaxRange(shifted) <= (text as NSString).length
                else { return nil }
                return TTSPronunciationHint(range: shifted, ipa: hint.ipa)
            }
        }

        ttsChapterIndex = chapterIndex
        let anchor = startCharOffset > 0
            ? CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: startCharOffset)
            : .chapterStart(chapterIndex)
        setActiveTTSAnchor(anchor, alignReader: shouldSyncReader)
        ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
        ttsCoordinator.speak(
            text: text,
            title: chapters[chapterIndex].title,
            bookTitle: ttsNowPlayingBookTitle,
            author: ttsNowPlayingAuthor,
            artwork: ttsNowPlayingArtwork(),
            pronunciationHints: hints
        )
        ttsCoordinator.refreshNowPlayingForSystemSurfaces()
        return true
    }

    @discardableResult
    func startAdjacentTTSChapter(delta: Int) -> Bool {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + delta
        guard chapters.indices.contains(target) else { return false }
        return startTTSChapter(target, syncReader: true)
    }

    func advanceTTSChapterFromEngine() -> TTSNarrationUnit? {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + 1
        guard chapters.indices.contains(target) else {
            ttsChapterIndex = nil
            return nil
        }
        let narration = narrationForTTSChapter(target)
        let text = narration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ensureChapterReady(chapterIndex: target, priority: .jump)
            return nil
        }
        ttsChapterIndex = target
        setActiveTTSAnchor(
            .chapterStart(target),
            alignReader: readerHeaderFooterEditorModel == nil
        )
        ttsCoordinator.updateNowPlayingChapter(title: chapters[target].title, text: text)
        return narration
    }

    func handleReaderPositionChangedForTTS() {
        guard !isAligningReaderToTTSAnchor else { return }
        guard ttsCoordinator.playbackState != .stopped,
              let anchor = ttsPlaybackAnchor
        else {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
            return
        }

        guard !isReaderAtTTSAnchor(anchor) else {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
            return
        }

        ttsJumpPromptChapterIndex = currentTTSReaderPosition()?.spineIndex ?? currentChapterIndex
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = true
        }
    }

    func jumpBackToTTSChapter() {
        guard let anchor = ttsPlaybackAnchor,
              chapters.indices.contains(anchor.spineIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        alignReaderToTTSAnchorIfNeeded()
    }

    func startTTSFromPromptChapter() {
        let target = ttsJumpPromptChapterIndex ?? currentChapterIndex
        let startOffset = currentTTSReaderPosition().map {
            $0.spineIndex == target ? $0.charOffset : 0
        } ?? 0
        _ = startTTSChapter(target, syncReader: false, startCharOffset: startOffset)
    }

    func narrationForTTSChapter(_ chapterIndex: Int) -> TTSNarrationUnit {
        guard chapters.indices.contains(chapterIndex) else {
            return TTSNarrationUnit(text: "")
        }
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           let layout = engine.layouts[chapterIndex],
           layout.attributedString.length > 0 {
            let hints = TTSPronunciationAnnotator.hints(
                in: layout.attributedString,
                lexicons: activePublicationSession?.pronunciationLexicons ?? [],
                bookLanguage: activePublicationSession?.language
            )
            return TTSNarrationUnit(text: layout.attributedString.string, pronunciationHints: hints)
        }
        let pageText = allPages
            .filter { $0.chapterIndex == chapterIndex }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageText.isEmpty { return TTSNarrationUnit(text: pageText) }
        return TTSNarrationUnit(text: chapters[chapterIndex].content)
    }

    func textForTTSChapter(_ chapterIndex: Int) -> String {
        narrationForTTSChapter(chapterIndex).text
    }

}
