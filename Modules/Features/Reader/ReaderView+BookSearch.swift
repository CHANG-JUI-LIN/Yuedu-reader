import SwiftUI

// MARK: - 全書搜尋

extension ReaderView {
    /// Per book, so each book offers its own recent searches.
    var bookSearchHistoryKey: String {
        "yd_reader_search_history_\(bookId.uuidString)"
    }

    var bookSearchSignature: ReaderBookSearchSession.ContentSignature {
        .init(source: aiSourceIdentity, conversion: settings.textConversion,
              rulesRevision: ReplaceRuleStore.shared.revision)
    }

    /// Each spine item under the TOC title it starts in, as the TOC shows it. Read once per
    /// search, so it maps by spine index alone rather than resolving every TOC anchor.
    var bookSearchChapterTitles: [String] {
        let spine = spineChapters
        let conversion = settings.textConversion
        guard activePublicationSession != nil else {
            return spine.map { $0.title.converted(to: conversion) }
        }
        // A spine item with TOC entries goes under its first; one without continues the last
        // entry before it, which is where the TOC would place it.
        var first: [Int: String] = [:], last: [Int: String] = [:]
        for entry in chapters {
            if first[entry.index] == nil { first[entry.index] = entry.title }
            last[entry.index] = entry.title
        }
        var carried: String?
        return spine.enumerated().map { index, item in
            let title = first[index] ?? carried ?? item.title
            if let entry = last[index] { carried = entry }
            return (title.isEmpty ? String(format: localized("第 %d 章"), index + 1) : title).converted(to: conversion)
        }
    }

    /// A new search starts over: the hit on the page belongs to the old results.
    func runBookSearch(_ query: String) {
        bookSearchJumpTask?.cancel()
        searchHitHighlight = nil
        let renderer = epubRenderer
        bookSearch.search(query, chapterTitles: bookSearchChapterTitles, signature: bookSearchSignature) { index, appliesRules in
            await renderer.localChapterText(at: index, applyingReplaceRules: appliesRules)
        }
    }

    /// The sheet opened again: results found in other text — 繁簡, 替換規則 or the source
    /// changed since — are searched again rather than shown against a page they no longer match.
    func refreshBookSearchIfStale() {
        guard !bookSearch.query.isEmpty, bookSearch.isStale(for: bookSearchSignature) else { return }
        runBookSearch(bookSearch.query)
    }

    /// Jumps to hit `index` and washes it on the page. The first jump remembers where the
    /// reader was, for ✕.
    func openBookSearchHit(at index: Int) {
        guard bookSearch.hits.indices.contains(index) else { return }
        let hit = bookSearch.hits[index]
        bookSearch.select(index, from: aiDisplayedReadingPosition())
        showReaderSearch = false
        setReaderChromeVisible(false)
        bookSearchJumpTask?.cancel()
        let renderer = epubRenderer
        bookSearchJumpTask = Task {
            let located = await bookSearch.locate(
                hit,
                loadSource: { index, rules in await renderer.localChapterText(at: index, applyingReplaceRules: rules) },
                loadLaidOut: { index in await renderer.laidOutChapterText(at: index) }
            )
            guard !Task.isCancelled, bookSearch.currentHit == hit else { return }
            if let located {
                searchHitHighlight = ReaderPlaybackHighlight(
                    text: located.drawnText,
                    expectedChapterOffset: located.range.location,
                    chapterIndex: hit.chapterIndex,
                    isSearchHit: true
                )
                jumpToChapter(hit.chapterIndex, charOffset: located.range.location)
            } else {
                // Nowhere to put it: the chapter would not lay out, or the hit is not
                // recognisably in what it laid out. The chapter is still where it is, and
                // the bar stays for the next hit; no wash, since a wash on another match
                // would be worse than none.
                AppLogger.render("全書搜尋 hit not located spine=\(hit.chapterIndex) range=\(hit.range)")
                searchHitHighlight = nil
                jumpToChapter(hit.chapterIndex)
            }
        }
    }

    func stepBookSearch(by offset: Int) {
        guard let index = bookSearch.hitIndex(offsetBy: offset) else { return }
        openBookSearchHit(at: index)
    }

    /// The sheet closed. Without a hit to step through — a new search with nothing picked, or
    /// the field cleared — the stepping is over, and so is the place it would go back to.
    func bookSearchSheetDidDismiss() {
        readerSearchSelection = ""
        guard !bookSearch.isNavigating else { return }
        endBookSearch(returningToOrigin: false)
    }

    /// ✕ on the bar. Asks first when there is a place to go back to.
    func requestEndBookSearch() {
        if bookSearch.origin != nil {
            showBookSearchExitConfirmation = true
        } else {
            endBookSearch(returningToOrigin: false)
        }
    }

    func endBookSearch(returningToOrigin: Bool) {
        bookSearchJumpTask?.cancel()
        bookSearchJumpTask = nil
        searchHitHighlight = nil
        let origin = bookSearch.endNavigation()
        if returningToOrigin, let origin {
            jumpToChapter(origin.spineIndex, charOffset: origin.charOffset)
        }
    }

    // MARK: - Bar

    /// Steps through hits on the page: ‹ the previous, › the next, the list, and ✕ to stop.
    /// Shown while the reader chrome is down, where the chrome's own bar would be.
    var bookSearchNavigationBar: some View {
        let palette = modernPalette
        let count = bookSearch.hits.count
        let position = (bookSearch.currentHitIndex ?? 0) + 1
        let title = bookSearch.currentHit.flatMap { hit in
            bookSearch.sections.first { $0.chapterIndex == hit.chapterIndex }?.title
        } ?? ""
        return HStack(spacing: 0) {
            Button { stepBookSearch(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .disabled(bookSearch.hitIndex(offsetBy: -1) == nil)
            .accessibilityLabel(localized("上一個結果"))

            VStack(spacing: 0) {
                Text(String(format: localized("%1$d／%2$d"), position, count))
                    .font(DSFont.subheadline.weight(.semibold))
                    .monospacedDigit()
                if !title.isEmpty {
                    Text(title)
                        .font(DSFont.caption2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: localized("第 %1$d 個結果，共 %2$d 個"), position, count))
            .accessibilityValue(title)

            Button { stepBookSearch(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .disabled(bookSearch.hitIndex(offsetBy: 1) == nil)
            .accessibilityLabel(localized("下一個結果"))

            Button { showReaderSearch = true } label: {
                Image(systemName: "list.bullet")
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("全部結果"))

            Button { requestEndBookSearch() } label: {
                Image(systemName: "xmark")
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("結束搜尋"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.bottomIcon)
        .padding(.horizontal, DSSpacing.xs)
        .floatingSurface(in: Capsule(), fill: palette.bottomFill)
        .frame(maxWidth: overlayContentMaxWidth)
        .padding(.horizontal, DSSpacing.lg)
    }
}
