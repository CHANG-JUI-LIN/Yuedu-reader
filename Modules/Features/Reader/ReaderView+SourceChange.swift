import YueduCoreText
import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Source Change Sheet
    var changeSourceSheetContent: AnyView {
        let search = readerViewModel.changeSource
        let chapterOnly = canReplaceChapterOnly && readerViewModel.changeSourceReplacesChapterOnly
        return AnyView(NavigationStack {
            List {
                // 單章換源 (Legado's ChangeChapterSourceDialog): the same list, but a tap opens
                // that origin's 目錄 and only the chapter being read takes the chosen text.
                if canReplaceChapterOnly {
                    Section {
                        Picker(localized("換源範圍"), selection: $readerViewModel.changeSourceReplacesChapterOnly) {
                            Text(localized("整本書")).tag(false)
                            Text(localized("只換本章")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(readerViewModel.isSwitchingSource)
                    } footer: {
                        if chapterOnly {
                            Text(localized("只換掉正在讀的這一章；按「刷新」會換回原來的內容。"))
                                .dsSectionFooter()
                        }
                    }
                    .interfaceSectionSurface()
                }

                // Where the book is read from now — a 來源配置, a module, a library, an imported
                // file — always visible with a checkmark (the lists below leave it out).
                ChangeSourceCurrentSection(
                    search: search,
                    name: currentOriginName,
                    lastChapter: book?.onlineChapters?.last?.title,
                    source: currentChangeSourceBookSource,
                    onDeletedCurrent: { autoChangeSource(after: .deletedInSheet) }
                )
                .interfaceSectionSurface()

                // The versions kept beside the book: what it was read from before 換源, and
                // the copies merged into it. Each switches back with its own file and place.
                let kept = chapterOnly ? [] : store.keptVersions(of: bookId)
                if !kept.isEmpty {
                    Section(localized("已知的閱讀來源")) {
                        ForEach(kept, id: \.id) { version in
                            Button { switchToVersion(version.id) } label: { changeSourceVersionRow(version) }
                                .disabled(readerViewModel.isSwitchingSource)
                        }
                    }
                    .interfaceSectionSurface()
                }

                // The work in the saved libraries, 青空文庫 / Gutenberg and the modules: each a
                // version like any other, its copy taken on the tap.
                if !chapterOnly, !versionFinder.found.isEmpty || versionFinder.isSearching {
                    Section(localized("書庫與模組")) {
                        ForEach(versionFinder.found) { version in
                            Button { switchToLibraryVersion(version.route) } label: { changeSourceLibraryRow(version) }
                                .disabled(readerViewModel.isSwitchingSource)
                        }
                        if versionFinder.isSearching {
                            HStack(spacing: DSSpacing.sm) {
                                ProgressView()
                                Text(localized("正在搜尋…"))
                                    .font(DSFont.footnote)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                        }
                    }
                    .interfaceSectionSurface()
                }

                // The other origins. Results stream in one source at a time, so they show as
                // soon as the first match arrives instead of blocking on the full fan-out
                // (459 sources can take minutes).
                ChangeSourceResultsSection(
                    search: search,
                    pendingOriginID: readerViewModel.changeSourcePendingOrigin?.id,
                    // One switch at a time: a second tap would cancel the first and restart
                    // the wait the user is already sitting through.
                    isSwitching: readerViewModel.isSwitchingSource,
                    onSelect: { origin in search.select(origin) { pickedOrigin($0, chapterOnly: chapterOnly) } }
                )
                .interfaceSectionSurface()
            }
            .changeSourceFilter(search)
            .changeSourceEditor(search)
            .changeSourceKindConfirmation(search) { pickedOrigin($0, chapterOnly: chapterOnly) }
            .navigationDestination(item: $readerViewModel.changeChapterSourcePick) { pick in
                ChangeChapterSourcePage(search: search, origin: pick.origin) { ref, toc in
                    try await replaceReadingChapter(with: ref, from: toc)
                }
            }
            .softScrollEdges()
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("換源"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    ChangeSourceSearchButton(search: search) {
                        versionFinder.start(for: bookId, store: store)
                    }

                    // Legado's 換源 menu, then its variable editors: sources' JS reads these
                    // back (`source.getVariable()` / book variables) on fetch. Legado offers
                    // both only while the book has a source. The book's source cannot change
                    // while the sheet is open (a switch dismisses it), so the items keep their
                    // identity.
                    ChangeSourceOptionsMenu(search: search) {
                        if currentChangeSourceBookSource != nil {
                            Divider()
                            Button {
                                showSourceVariableEditor = true
                            } label: {
                                Label(localized("設置源變量"), systemImage: "curlybraces")
                            }
                            Button {
                                showBookVariableEditor = true
                            } label: {
                                Label(localized("設置書籍變量"), systemImage: "character.book.closed")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Legado's WaitDialog is dismissible and its cancel listener aborts the
                    // coroutine; this is the same escape hatch. Without it a slow source held
                    // the sheet hostage with no way out but force-quitting.
                    //
                    // One Button whose title changes, never an if/else pair: branching on the
                    // view itself gives the toolbar item a new identity, and toolbar items
                    // that change identity flicker or drop out entirely.
                    let isSwitching = readerViewModel.isSwitchingSource
                    Button(localized(isSwitching ? "取消" : "關閉")) {
                        if isSwitching {
                            readerViewModel.cancelPendingSourceSwitch()
                        } else {
                            showChangeSourceSheet = false
                        }
                    }
                }
            }
            .bookVariableEditors(
                source: currentChangeSourceBookSource,
                showsSourceVariable: $showSourceVariableEditor,
                showsBookVariable: $showBookVariableEditor,
                bookVariable: { BookCustomVariable.value(in: book?.runtimeVariables) },
                onSaveBookVariable: { value in
                    store.updateBookRuntimeVariables(
                        bookId: bookId,
                        variables: BookCustomVariable.merged(value, into: book?.runtimeVariables)
                    )
                }
            )
        })
    }

    /// 單章換源 needs a book of 來源配置 chapters: an online text book with a 目錄.
    var canReplaceChapterOnly: Bool {
        guard let current = book, current.isOnline, changeSourceReadingChapter != nil else { return false }
        return ReaderViewModel.contentKind(of: current) == .text
    }

    /// A tapped origin: the whole book switches to it, or — 只換本章 — its 目錄 opens.
    private func pickedOrigin(_ origin: BookOrigin, chapterOnly: Bool) {
        if chapterOnly {
            readerViewModel.changeChapterSourcePick = ChangeChapterSourcePick(origin: origin)
        } else {
            switchToOrigin(origin)
        }
    }

    /// 單章換源's last step: the chapter being read takes the text of `ref`, another origin's
    /// chapter, and is shown again. The book keeps its own 來源配置 and 目錄.
    func replaceReadingChapter(with ref: OnlineChapterRef, from toc: TOCPackage) async throws {
        guard let current = book, let refs = current.onlineChapters, !refs.isEmpty,
              let reading = changeSourceReadingChapter else { return }
        guard let source = BookSourceStore.shared.source(id: toc.sourceId) else {
            throw NSError(
                domain: "ChangeSourceSearch", code: -1,
                userInfo: [NSLocalizedDescriptionKey: localized("找不到來源配置")])
        }
        let index = reading.index
        let startedAt = ProcessInfo.processInfo.systemUptime
        try await OtherSourceChapter.replace(
            chapterIndex: index,
            ofBook: current.id,
            own: refs[index],
            with: ref,
            toc: toc,
            source: source,
            storeNormalizedHTML: current.chaptersBuiltByRules
        )
        SourcePerfTrace.record("changeSource.chapter", toc.sourceName, since: startedAt)
        // The same reload as 重新整理本章 (`refetchChapter`), with the new text already cached.
        pendingChapterContentReplacements.insert(index)
        readerViewModel.resetChapterState(for: index)
        ensureChapterReady(chapterIndex: index, priority: .jump)
        showChangeSourceSheet = false
        UIAccessibility.post(
            notification: .announcement,
            argument: String(format: localized("本章已換成「%@」的內容"), toc.sourceName)
        )
    }

    /// The source the book is currently reading from (for 設置源變量 in-reader).
    var currentChangeSourceBookSource: BookSource? {
        guard let sourceId = book?.bookSourceId else { return nil }
        return BookSourceStore.shared.source(id: sourceId)
    }

    /// The chapter on screen, for 加載字數 to read the same chapter in each result.
    var changeSourceReadingChapter: ChangeSourceTarget.ReadingChapter? {
        guard let refs = book?.onlineChapters, !refs.isEmpty else { return nil }
        let index = min(max(0, currentChapterIndex), refs.count - 1)
        return .init(index: index, title: refs[index].title, count: refs.count)
    }

    /// Where the book is read from now, as the title capsule names it.
    var currentOriginName: String {
        book.map(BookOriginName.of) ?? localized("未知來源配置")
    }

    /// A kept version: where it is read from, and how far it was read.
    @ViewBuilder
    func changeSourceVersionRow(_ version: ReadingBook) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(BookOriginName.of(version))
                    .foregroundStyle(DSColor.textPrimary)
                Text(BookshelfAccessibility.readingStatus(for: version))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if readerViewModel.changeSourcePendingVersion == .copy(version.id) {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(localized("正在載入目錄…"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A version in a library or a module: its place, and the book as that place names it.
    @ViewBuilder
    func changeSourceLibraryRow(_ version: ReaderVersionFinder.Found) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.place)
                    .foregroundStyle(DSColor.textPrimary)
                Text(([version.route.summary.title] + version.route.summary.authors).joined(separator: " · "))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if readerViewModel.changeSourcePendingVersion == version.route.nodeKey {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(localized("正在載入目錄…"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The chapter on screen, as a place in the book: an EPUB's spine item, a TXT's or a
    /// source's chapter.
    private var changeSourceReadingSpine: Int {
        readerSessionCoordinator?.state.location.spineIndex ?? currentChapterIndex
    }

    /// Switches to another version of the work (`ShelfVersionSwitch`): the shelf book becomes
    /// that copy, this one is kept beside it, and the reader hands over to the copy's own at the
    /// chapter being read.
    func switchToVersion(_ versionID: UUID) {
        let spine = changeSourceReadingSpine
        readerViewModel.stopChangeSourceSearch()
        versionFinder.stop()
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        readerViewModel.beginVersionSwitch(to: .copy(versionID)) {
            do {
                let opening = try await ShelfVersionSwitch(store: store, dependencies: dependencies)
                    .commit(from: bookId, to: versionID, readingFrom: spine)
                handOver(to: versionID, opening: opening, since: switchStartedAt)
            } catch is CancellationError {
                // Cancelled before anything was written: the book still reads from here.
            } catch {
                AppLogger.error("換源: switching to another version failed", error: error,
                                context: ["book": bookId.uuidString, "version": versionID.uuidString])
                readerViewModel.reportChangeSourceError(error.localizedDescription)
            }
        }
    }

    /// Switches to the work in a library or a module: its copy is taken as 開始閱讀 takes it
    /// (`VersionReadingCopy`) — downloaded, or its chapters listed — and becomes the shelf book.
    func switchToLibraryVersion(_ version: WorkDetailRoute) {
        let spine = changeSourceReadingSpine
        readerViewModel.stopChangeSourceSearch()
        versionFinder.stop()
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        readerViewModel.beginVersionSwitch(to: version.nodeKey) {
            do {
                let copy = try await SourcePerfTrace.spanAsync("changeSource.copy", version.record.key.instance.type.rawValue) {
                    try await VersionReadingCopy(store: store, dependencies: dependencies).readingCopy(of: version)
                }
                try Task.checkCancellation()
                let opening = try await ShelfVersionSwitch(store: store, dependencies: dependencies)
                    .commit(from: bookId, to: copy.id, readingFrom: spine)
                handOver(to: copy.id, opening: opening, since: switchStartedAt)
            } catch is CancellationError {
                // Cancelled before the commit: the book still reads from here. A copy already
                // taken stays off the shelf, read again by the next switch to it.
            } catch {
                AppLogger.error("換源: switching to a library version failed", error: error,
                                context: ["book": bookId.uuidString, "version": version.record.key.item])
                readerViewModel.reportChangeSourceError(error.localizedDescription)
            }
        }
    }

    /// The shelf book is another copy now: the sheet goes, and the copy's reader takes over.
    private func handOver(to versionID: UUID, opening: ReaderTOCTarget?, since startedAt: TimeInterval) {
        // Leave the pending state before dismissing: the sheet's dismiss handler cancels a
        // pending switch, and at this point that switch is this one.
        readerViewModel.finishSourceSwitch()
        showChangeSourceSheet = false
        SourcePerfTrace.record("changeSource.total", "version", since: startedAt)
        if let readerVersionSwitch {
            readerVersionSwitch(versionID, opening: opening)
        } else {
            // A reader shown outside `BookReaderView` has no reader to hand over to; the shelf
            // already reads from the copy, which opens next time.
            AppLogger.info("換源: version switched with no reader to hand over to", context: ["version": versionID.uuidString])
        }
    }

    /// Switches the book to the chosen origin. On success dismisses the sheet and
    /// reloads; on failure flags the origin (persisted) and keeps the sheet open so
    /// the user can try another.
    ///
    /// A book read from anywhere but a 來源配置 — an imported file, a library, a module — is not
    /// rebound: the work's 來源配置 copy reads from the origin, and the shelf switches to it as
    /// to any other version (`switchToSourceVersion`).
    ///
    /// Reading position: the raw chapter index means different things in different
    /// sources (extra 卷 headers, merged 序章 …), so before reloading, the current
    /// chapter is re-located in the new TOC via `ChapterAlignment` (title
    /// similarity + chapter-number match, Legado getDurChapter-style) and the
    /// restore target/persisted position are updated to the mapped chapter.
    func switchToOrigin(_ origin: BookOrigin) {
        guard let current = book, ShelfWork.isSourceCopy(current) else {
            switchToSourceVersion(origin)
            return
        }
        // The fan-out holds the connection pool and the JS bridge, and from this tap onward it
        // is racing the one fetch the user is waiting on. Legado's `getToc` opens with the
        // same `stopSearch()`.
        readerViewModel.stopChangeSourceSearch()
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        readerViewModel.beginSourceSwitch(to: origin) {
            do {
                // Resolved here rather than inside the commit so this step is the cancellable
                // one, and so the commit never fetches the same TOC again.
                let tocPackage = try await SourcePerfTrace.spanAsync(
                    "changeSource.toc", origin.sourceName
                ) {
                    try await readerViewModel.changeSource.prepareTOCPackage(for: origin)
                }
                try Task.checkCancellation()
                try await commitSourceSwitch(to: origin, toc: tocPackage, since: switchStartedAt)
            } catch is CancellationError {
                // The user cancelled the wait. Nothing was committed and the source is not
                // known to be bad, so it must not be flagged as a failed origin.
            } catch {
                readerViewModel.changeSource.markFailed(origin)
                readerViewModel.reportChangeSourceError(error.localizedDescription)
            }
        }
    }

    /// Rebinds the shelf book to `origin` with its TOC already in hand and reopens it at the
    /// chapter being read. The one commit both a tapped switch and 自動換源 go through.
    private func commitSourceSwitch(to origin: BookOrigin, toc tocPackage: TOCPackage, since switchStartedAt: TimeInterval) async throws {
        let oldIndex = currentChapterIndex
        let livePosition = readerSessionCoordinator?.state.location.coreTextPosition
        // Rebinds the source and carries the place on screen over to the new list
        // (`OnlineBookSourceSwitch`, shared with the detail page and 加入書架), and
        // persists it before loadContent so any restore path that re-reads the
        // position store already sees the mapped chapter.
        let mappedPosition = try await SourcePerfTrace.spanAsync(
            "changeSource.commit", "\(tocPackage.chapters.count)ch"
        ) {
            try await OnlineBookSourceSwitch(store: store, dependencies: dependencies).commit(
                bookId: bookId,
                origin: origin,
                toc: tocPackage,
                readingFrom: .init(chapterIndex: oldIndex, position: livePosition)
            )
        }
        try Task.checkCancellation()
        // It just worked; a stale flag from an earlier attempt would otherwise keep
        // this row badged 載入失敗 in every future session.
        readerViewModel.changeSource.clearFailure(origin)

        // Leave the pending state before dismissing: the sheet's dismiss handler
        // cancels a pending switch, and at this point that switch is this one.
        readerViewModel.finishSourceSwitch()
        showChangeSourceSheet = false
        SourcePerfTrace.span("changeSource.loadContent") { reopenOnStoredChapterList(at: mappedPosition) }
        // Whole-tap total, so the stage spans above can be read as a share of what
        // the user actually waited through.
        SourcePerfTrace.record(
            "changeSource.total", origin.sourceName, since: switchStartedAt)
    }

    /// 自動換源 on opening (網路設定 → 自動換源): the shelf book's 來源配置 has been deleted — deleted
    /// only, not disabled (maintainer 2026-11-07, as Legado: a disabled one still fetches). Waits for
    /// the source library to be read first, so a library still loading is never taken for a
    /// deleted source.
    func autoChangeSourceIfSourceMissing() {
        guard GlobalSettings.shared.autoChangeSource, let opened = book, opened.isOnline,
              ShelfWork.isSourceCopy(opened), let sourceId = opened.bookSourceId else { return }
        Task { @MainActor in
            await BookSourceStore.shared.waitUntilLoaded()
            guard book?.bookSourceId == sourceId, BookSourceStore.shared.source(id: sourceId) == nil else { return }
            autoChangeSource(after: .sourceMissingOnOpen)
        }
    }

    /// Why 自動換源 runs.
    enum AutoChangeSourceTrigger {
        /// The book opened and its 來源配置 is gone (Legado `ReadBookViewModel`: `bookSource == null`).
        case sourceMissingOnOpen
        /// The 來源配置 in use was deleted from the 換源 sheet (Legado `deleteSource` on the
        /// book's own origin).
        case deletedInSheet
    }

    /// Legado `autoChangeSource`: switches the shelf book to the first origin of its kind whose
    /// TOC loads — the found list first, then results as they arrive. Only a 來源配置 copy, and
    /// only when its source is really gone: a disabled source still loads chapters, so it is
    /// left alone, as in Legado.
    func autoChangeSource(after trigger: AutoChangeSourceTrigger) {
        guard let current = book, current.isOnline, ShelfWork.isSourceCopy(current),
              !readerViewModel.isSwitchingSource else { return }
        let goneSourceId = current.bookSourceId
        let search = readerViewModel.changeSource
        let kind = ReaderViewModel.contentKind(of: current)
        if trigger == .sourceMissingOnOpen {
            // Legado searches with `preciseSearchAwait` here: name and author both.
            search.start(
                ChangeSourceTarget(
                    title: current.title, author: current.author, bookId: current.id,
                    currentSourceId: nil, currentBookURL: nil,
                    readingChapter: changeSourceReadingChapter, kind: kind
                ),
                matchesAuthor: true
            )
        }
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        AppLogger.info("換源: automatic change source", context: [
            "book": current.id.uuidString, "trigger": "\(trigger)",
        ])
        readerViewModel.beginAutoSourceSwitch {
            guard let found = await search.firstLoadable(kind: kind, excluding: goneSourceId) else {
                guard !Task.isCancelled else { return }
                AppLogger.error("換源: automatic change source found no source", context: [
                    "book": current.id.uuidString, "trigger": "\(trigger)",
                ])
                readerViewModel.reportAutoChangeSourceFailure(localized("自動換源失敗：沒有可用的來源配置"))
                return
            }
            let (origin, toc) = found
            search.stop()
            do {
                try await commitSourceSwitch(to: origin, toc: toc, since: switchStartedAt)
            } catch is CancellationError {
                // Cancelled before the commit: the book keeps the source it had.
            } catch {
                AppLogger.error("換源: automatic change source commit failed", error: error,
                                context: ["book": current.id.uuidString, "source": origin.sourceName])
                search.markFailed(origin)
                readerViewModel.reportAutoChangeSourceFailure(
                    String(format: localized("自動換源失敗：%@"), error.localizedDescription))
            }
        }
    }

    /// Reopens the book on the chapter list now in `store`, at `position` in that list. The
    /// engine pages the list it was opened with, so a list that changed under it — 換源, or a
    /// refresh that moved chapters (`followChapterRenumbering`) — takes a reopen, not a patch.
    func reopenOnStoredChapterList(at position: CoreTextReadingPosition?) {
        // The new chapter list is already live in `store`, so every cache lookup from here on
        // asks about *its* chapters. The load states still describe the old list's, and a
        // stale `.ready` there is read as "ready but nothing on disk" — the 資料不一致 overlay
        // users hit on every source switch. They belong to the list we just left; drop them.
        readerViewModel.resetAllChapterStates()
        chapterConsistencyRecoveryAttempts.removeAll()

        if let position {
            savedCoreTextRestoreTarget = (position.spineIndex, position.charOffset)
            setCoreTextExternalTarget(position)
            currentChapterIndex = position.spineIndex
            scrollVisibleChapter = position.spineIndex
        }
        loadContent()
    }

    /// A table-of-contents refresh moved chapters to other indices while this book was open
    /// (feedback #95: one entry inserted ahead of 第97章, and the reader went on paging the old
    /// list while every index around it meant the chapter before). The store has moved the
    /// stored place and the bookmarks; the place on screen is moved here, the same way.
    func followChapterRenumbering(_ renumbering: ChapterRenumbering) {
        guard renumbering.bookId == bookId, let refs = book?.onlineChapters else { return }
        let live = readerSessionCoordinator?.state.location.coreTextPosition
            ?? CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
        let moved = renumbering.position(for: live)
        guard moved != live, chapters.indices.contains(live.spineIndex), refs.indices.contains(moved.spineIndex) else {
            return
        }
        // Only a reader still on the list the refresh replaced: one opened on the new list
        // already shows the chapter at its index, and moving it again would skip ahead.
        let showing = chapters[live.spineIndex]
        let target = refs[moved.spineIndex]
        let sameChapter = !showing.href.isEmpty
            ? showing.href == target.sanitizedContentURL
            : showing.title == target.title
        guard sameChapter else { return }
        AppLogger.render("⟐ reader follows moved chapters", context: [
            "bookId": bookId.uuidString,
            "from": live.spineIndex,
            "to": moved.spineIndex,
        ])
        // Now, not after the save: the refresh that sent this goes on to ask for the current
        // chapter (`revalidateTOCOnceForFailures`), and that must already mean the new index.
        // The store has saved a mapped place before announcing; this one is the exact one.
        reopenOnStoredChapterList(at: moved)
        Task { await dependencies.readingPositionStore.save(moved, for: bookId.uuidString) }
    }

    /// 換源 to a 來源配置 for a book read from elsewhere: the work's 來源配置 copy — the one kept
    /// beside the book, rebound to this origin, or a new one off the shelf — becomes the shelf
    /// book (`ShelfVersionSwitch.sourceCopy`).
    private func switchToSourceVersion(_ origin: BookOrigin) {
        let spine = changeSourceReadingSpine
        readerViewModel.stopChangeSourceSearch()
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        readerViewModel.beginSourceSwitch(to: origin) {
            do {
                let tocPackage = try await SourcePerfTrace.spanAsync("changeSource.toc", origin.sourceName) {
                    try await readerViewModel.changeSource.prepareTOCPackage(for: origin)
                }
                try Task.checkCancellation()
                let versions = ShelfVersionSwitch(store: store, dependencies: dependencies)
                let copyID = try await versions.sourceCopy(of: bookId, origin: origin, toc: tocPackage,
                                                           sourceSwitch: OnlineBookSourceSwitch(store: store, dependencies: dependencies))
                let opening = try await versions.commit(from: bookId, to: copyID, readingFrom: spine)
                readerViewModel.changeSource.clearFailure(origin)
                handOver(to: copyID, opening: opening, since: switchStartedAt)
            } catch is CancellationError {
                // Nothing was committed and the source is not known to be bad.
            } catch {
                readerViewModel.changeSource.markFailed(origin)
                readerViewModel.reportChangeSourceError(error.localizedDescription)
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
        // The chapter the release lands on (`applyChapterSliderProgress`), not the paged engine's.
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            return chapterTitle(forSpineIndex: Self.scrollSliderSpine(forProgress: value, spineCount: spineChapters.count))
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

    /// Scroll mode's slider steps through spine items, the unit scroll positions count: chunks
    /// load as they are reached, so there is no whole-book character count to place it by.
    /// 0 is the first item and 1 the last. An EPUB's `chapters` is its TOC, which can be shorter.
    static func scrollSliderSpine(forProgress value: Double, spineCount: Int) -> Int {
        let last = spineCount - 1
        guard last > 0 else { return 0 }
        return max(0, min(Int((value * Double(last)).rounded()), last))
    }

    /// Where `scrollSliderSpine(forProgress:spineCount:)` puts the slider for a spine item.
    static func scrollSliderProgress(forSpine spineIndex: Int, spineCount: Int) -> Double {
        let last = spineCount - 1
        guard last > 0 else { return 0 }
        return Double(max(0, min(spineIndex, last))) / Double(last)
    }

    func chapterSliderProgressValue() -> Double {
        if effectiveScrollMode {
            return Self.scrollSliderProgress(forSpine: scrollVisibleChapter, spineCount: spineChapters.count)
        }
        if book?.isOnline == true {
            let totalChapters = book?.onlineChapters?.count ?? chapters.count
            guard totalChapters > 1 else { return 0 }
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
        // Scroll mode: round to nearest chapter and go there the way 目錄 does, through the scroll
        // host, which holds the position and enters the chapter's segment. Reslicing the engine
        // directly left the host restoring its old position, and could lay a chapter out in
        // another segment's mode.
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            jumpToChapter(Self.scrollSliderSpine(forProgress: value, spineCount: spineChapters.count))
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
        // Narration moving the reader is one of the four things allowed to, and
        // `JumpIntent.ttsAnchor` has existed for it since the sentry was written — with
        // **zero** call sites. So every page turn narration drove looked to the sentry
        // like the position moving on its own. Harmless while the guard only fired two
        // chapters out; not harmless now that A1 records every unaccounted move.
        ReaderPositionSentry.shared.declareIntent(.ttsAnchor, target: anchor)
        ttsPlaybackAnchor = anchor
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        if alignReader {
            alignReaderToTTSAnchorIfNeeded()
        }
    }

    func alignReaderToTTSAnchorIfNeeded() {
        guard               let anchor = ttsPlaybackAnchor,
              spineChapters.indices.contains(anchor.spineIndex),
              !isReaderAtTTSAnchor(anchor)
        else { return }

        isAligningReaderToTTSAnchor = true
        withAnimation(DSAnimation.fast) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        jumpToChapter(anchor.spineIndex, charOffset: anchor.charOffset)
        DispatchQueue.main.async {
            isAligningReaderToTTSAnchor = false
        }
    }

    /// This reader took over narration from a closed reader of the book
    /// (`NowPlayingHub.narrationToTakeOver(forBook:)`) and has restored to where that reader
    /// was saved, which the narration has since moved on from. Once the opening restore has
    /// landed: go to the sentence being spoken, and prepare what comes next in this reader's
    /// own engine — the closed reader's layouts and chapter-load observers left with it, so a
    /// chapter wait it started is begun again here.
    func alignToAdoptedNarration() {
        guard alignsToNarrationOnRestore else { return }
        alignsToNarrationOnRestore = false
        guard ttsCoordinator.playbackState != .stopped,
              let chapterIndex = ttsChapterIndex
        else { return }
        ttsLog("[TTS][Reader] took over narration chapter=\(chapterIndex) pending=\(ttsPendingChapterIndex.map(String.init) ?? "nil")")
        // No offset when the narration has no mapping to the laid-out chapter
        // (`ttsNarrationOffsets`): the chapter's start, and following the spoken text does the rest.
        setActiveTTSAnchor(
            CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: expectedPlaybackChapterOffset() ?? 0),
            alignReader: true
        )
        if let pending = ttsPendingChapterIndex, ttsCoordinator.isWaitingForNextChapter {
            beginWaitingForTTSChapter(pending)
        } else {
            prepareNextTTSChapter(after: chapterIndex)
        }
    }

    /// Keeps the paged reader on the sentence TTS is currently speaking. Called on
    /// every spoken-segment change. Moves the playback anchor to the spoken text and
    /// turns the page only when that text now sits on a different page. Paged CoreText
    /// mode only — scroll mode and the "jump back to TTS" browse state are left alone.
    func followTTSPlaybackHighlight() {
        guard               ttsCoordinator.playbackState == .playing,
              !showTTSJumpPrompt,            // user navigated away — let them browse
              !effectiveScrollMode,
              let engine = epubRenderer.engine, usesCoreTextEPUB
        else { return }

        // The narration was made from this chapter's layout, so the offset map says exactly
        // where the spoken segment is — the same position the playback wash uses. Searching
        // the chapter for the spoken words cannot: a sentence that repeats on the page
        // (「嗯。」 twice, a page of identical lines) resolves to its first occurrence, the
        // anchor never moves past it, and the page never turns.
        if ttsNarrationOffsets != nil {
            guard let chapterIndex = ttsChapterIndex,
                  spineChapters.indices.contains(chapterIndex),
                  engine.chapterText(forSpine: chapterIndex)?.isEmpty == false,
                  // No segment between units: the coordinator clears the range while a
                  // chapter switch or wait is in progress.
                  let offset = expectedPlaybackChapterOffset()
            else { return }
            setActiveTTSAnchor(
                CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: offset),
                alignReader: true
            )
            return
        }

        // Fallback: narration with no offset map — `narrationForTTSChapter` read the
        // chapter's pages or its raw content because the chapter had no CoreText layout
        // when the unit was made (a chapter advance into one not laid out yet). Its offsets
        // are not the layout's, so the spoken words are searched for, and a repeated line
        // can still pin the anchor to its first occurrence. Delete this once every
        // narration unit carries a `sourceOffsets` map.
        let chapterIndex = ttsChapterIndex ?? currentChapterIndex
        guard spineChapters.indices.contains(chapterIndex),
              let chapterText = engine.chapterText(forSpine: chapterIndex),
              !chapterText.isEmpty
        else { return }

        let text = ttsCoordinator.currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Search forward from the current page start so a repeated sentence resolves to
        // an occurrence at or after the page being read.
        let ns = chapterText as NSString
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
            // A chapter switch still waiting on its layout must not resume what was paused.
            ttsStartLayoutRequest = nil
            ttsCoordinator.pause()
        case .paused:
            // Resuming what was paused cancels a chapter start still waiting on its layout or
            // on the AI; that analysis still lands in the cache for when the chapter is reached.
            if ttsStartLayoutRequest != nil {
                ttsStartLayoutRequest = nil
                ttsCoordinator.setPreparationNotice(nil)
            }
            ttsCoordinator.resume()
        case .stopped:
            let startOffset = currentTTSReaderPosition()
                .map { $0.spineIndex == currentChapterIndex ? $0.charOffset : 0 } ?? 0
            startTTSChapter(currentChapterIndex, syncReader: false, startCharOffset: startOffset)
        }
    }

    func handleListeningAction() {
        // 聽書 from the bar or the book card puts the menu away, leaving the page and
        // the narration capsule.
        setReaderChromeVisible(false)
        let chapterIndex = currentChapterIndex
        if isEPUB, epubRenderer.mediaOverlaysByChapter[chapterIndex] != nil {
            activeMediaOverlayChapterIndex = chapterIndex
            showMediaOverlayPanel = true
        } else {
            // Narration publishes the floating capsule through NowPlayingHub.
            // The capsule opens the full panel only when its artwork is tapped.
            if ttsCoordinator.playbackState != .playing {
                handleTTSPlayPause()
            }
        }
    }

    func currentMediaOverlayHighlightText() -> String? {
        guard let chapterIndex = mediaOverlayCoordinator.currentChapterIndex,
              let fragment = mediaOverlayCoordinator.currentFragment,
              let overlay = epubRenderer.mediaOverlaysByChapter[chapterIndex],
              let engine = epubRenderer.engine,
              let anchorOffsets = engine.chapterAnchorOffsets(forSpine: chapterIndex),
              let chapterText = engine.chapterText(forSpine: chapterIndex),
              !chapterText.isEmpty
        else {
            return mediaOverlayCoordinator.currentFragment?.textFragmentID
                ?? mediaOverlayCoordinator.currentFragment?.id
        }
        let chapterNS = chapterText as NSString

        let anchorID = fragment.textFragmentID ?? fragment.id
        guard let start = anchorOffsets[anchorID],
              start >= 0,
              start < chapterNS.length
        else {
            return anchorID
        }

        let nextStart = overlay.fragments
            .compactMap { next -> Int? in
                guard next.id != fragment.id else { return nil }
                let nextID = next.textFragmentID ?? next.id
                guard let offset = anchorOffsets[nextID], offset > start else { return nil }
                return offset
            }
            .min()
        let end = min(nextStart ?? min(chapterNS.length, start + 180), chapterNS.length)
        guard end > start else { return anchorID }

        let text = chapterNS
            .substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? anchorID : text
    }

    func setTTSFloatingOverlayVisible(_ visible: Bool) {
        let owner = nowPlayingHostID
        Task { @MainActor in
            NowPlayingHub.shared.setReaderOverlayVisible(visible, owner: owner)
        }
    }

    /// What starting narration at a chapter has to do before it can speak.
    enum TTSChapterStartPlan: Equatable {
        /// The chapter's text is in hand.
        case speak
        /// The paged engine can lay the chapter out but has not yet: start once it has.
        case awaitLayout
        /// Nothing will produce text for this chapter now.
        case unavailable
    }

    /// No narration text is not the same as no text. Narration reads the paged engine,
    /// and a chapter that engine has not laid out yet is unmeasured, not empty — scroll
    /// mode lays its chapters out in the scroll engine only, so the chapter on screen is
    /// routinely in that state. Only the layout pass is waited on, and only once: a
    /// chapter still empty after it (`layoutAwaited`) is empty for real.
    static func ttsChapterStartPlan(
        hasNarration: Bool,
        isLaidOut: Bool,
        canLayOut: Bool,
        layoutAwaited: Bool
    ) -> TTSChapterStartPlan {
        if hasNarration { return .speak }
        if !isLaidOut, canLayOut, !layoutAwaited { return .awaitLayout }
        return .unavailable
    }

    /// Whether the paged engine can lay `chapterIndex` out right now. A local book always
    /// can; an online chapter only once its content is cached — until then the start keeps
    /// its `ensureChapterReady` request, which is all it can do.
    private func canLayOutTTSChapter(_ chapterIndex: Int) -> Bool {
        guard epubRenderer.engine != nil, usesCoreTextEPUB else { return false }
        return book?.isOnline != true || isChapterContentAvailable(at: chapterIndex)
    }

    /// Lays `chapterIndex` out in the paged engine, then starts narration there.
    ///
    /// Scroll mode relied on a side effect for this: the paged-mode restore used to lay out
    /// the chapter the book opened on, and narration found its text there. The scroll-mode
    /// restore no longer touches the paged engine, so 聽書 found nothing and did nothing.
    /// The layout task's completion is the readiness signal — no polling, no delay — and a
    /// newer start, a pause or a stop (each clears `ttsStartLayoutRequest`) wins over a
    /// layout still in flight.
    private func startTTSChapterOnceLaidOut(_ chapterIndex: Int, syncReader: Bool, startCharOffset: Int) {
        guard let engine = epubRenderer.engine else { return }
        let request = UUID()
        ttsStartLayoutRequest = request
        let requestedAt = ProcessInfo.processInfo.systemUptime
        ttsLog("[TTS][Reader] start waits for layout chapter=\(chapterIndex)")
        Task { @MainActor in
            let outcome = await engine.preloadChapter(at: chapterIndex)
            SourcePerfTrace.record(
                "tts.start.awaitLayout",
                "spine=\(chapterIndex) outcome=\(outcome.rawValue)",
                since: requestedAt,
                thresholdMs: 0
            )
            guard ttsStartLayoutRequest == request else {
                ttsLog("[TTS][Reader] start for chapter=\(chapterIndex) superseded during layout")
                return
            }
            startTTSChapter(
                chapterIndex,
                syncReader: syncReader,
                startCharOffset: startCharOffset,
                layoutAwaited: true
            )
        }
    }

    /// 聽書's chapter list picks a 目錄 entry: narration starts in its spine item, at the entry's
    /// anchor where that item is laid out (`tocPosition`), else at the item's start.
    func startTTSChapter(atTOCEntry entry: BookChapter) {
        let position = tocPosition(for: entry, engine: epubRenderer.engine)
        startTTSChapter(position.spineIndex, syncReader: true, startCharOffset: position.charOffset)
    }

    /// 聽書's 下一章: enabled exactly when `startAdjacentTTSChapter(delta: 1)` has a chapter to start.
    var ttsHasNextChapter: Bool {
        Self.narratableChapter(
            from: ttsChapterIndex ?? currentChapterIndex,
            direction: 1,
            spineCount: spineChapters.count,
            isSeparator: isVolumeSeparatorChapter
        ) != nil
    }

    @discardableResult
    func startTTSChapter(
        _ chapterIndex: Int,
        syncReader: Bool,
        startCharOffset: Int = 0,
        layoutAwaited: Bool = false
    ) -> Bool {
        guard spineChapters.indices.contains(chapterIndex) else { return false }
        // Whatever this call does, it replaces a start still waiting on a layout.
        ttsStartLayoutRequest = nil
        // Starting on a volume separator (the reader is parked on one, or the user picked one
        // in the TOC) has nothing to read: begin at the next real chapter instead of failing
        // silently. The offset belongs to the separator, so it is dropped.
        if isVolumeSeparatorChapter(chapterIndex) {
            guard let target = narratableTTSChapter(from: chapterIndex, direction: 1) else {
                ttsLog("[TTS][Reader] startTTSChapter: no narratable chapter after separator=\(chapterIndex)")
                return false
            }
            return startTTSChapter(target, syncReader: syncReader)
        }
        let shouldSyncReader = syncReader
        mediaOverlayCoordinator.stop()
        let narration = narrationForTTSChapter(chapterIndex)
        var text = narration.text
        var hints = narration.pronunciationHints
        var offsets = narration.sourceOffsets
        let plan = Self.ttsChapterStartPlan(
            hasNarration: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isLaidOut: epubRenderer.engine?.chapterPagination(forSpine: chapterIndex, charOffset: 0) != nil,
            canLayOut: canLayOutTTSChapter(chapterIndex),
            layoutAwaited: layoutAwaited
        )
        if plan == .awaitLayout {
            startTTSChapterOnceLaidOut(chapterIndex, syncReader: syncReader, startCharOffset: startCharOffset)
            return true
        }
        guard plan == .speak else {
            // The moment listening stops. Previously a `notice` buried among thousands:
            // a real user's export had seven of these and nothing marking them as the
            // reason the audio went silent. An unmeasured chapter no longer lands here
            // (it is laid out first), so this is a chapter still empty after its own
            // layout pass, or an online chapter whose content has not arrived.
            AppLogger.anomaly(
                localized("聽書取不到章節文字而停止"),
                category: .tts,
                detail: [
                    "chapter=\(chapterIndex)",
                    "hasLayout=\(epubRenderer.engine?.chapterPagination(forSpine: chapterIndex, charOffset: 0) != nil)",
                    "layoutAwaited=\(layoutAwaited)",
                    "usesCoreText=\(usesCoreTextEPUB)",
                    "pagesForChapter=\(allPages.filter { $0.chapterIndex == chapterIndex }.count)",
                ].joined(separator: "\n")
            )
            if shouldSyncReader {
                jumpToChapter(chapterIndex)
            }
            ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
            return false
        }

        // AI 多角色朗讀: the chapter is analysed before it is read, so the first line already
        // has the right voice. The analysis covers the whole chapter, then is sliced below
        // along with the text.
        var dialogue: TTSChapterDialogue?
        if let request = ttsDialogueRequest(chapterIndex: chapterIndex, text: text) {
            switch AIDialogueCastService.shared.readiness(request) {
            case let .ready(analysed):
                dialogue = analysed
            case .needsAnalysis:
                startTTSChapterOnceAnalyzed(
                    chapterIndex,
                    syncReader: syncReader,
                    startCharOffset: startCharOffset,
                    request: request
                )
                return true
            case .unavailable:
                break
            }
        }
        let sliceOffset = startCharOffset > 0 && startCharOffset < (text as NSString).length ? startCharOffset : 0

        if startCharOffset > 0, startCharOffset < (text as NSString).length {
            let nsText = text as NSString
            text = nsText.substring(from: startCharOffset)
            hints = hints.compactMap { hint in
                let shifted = NSRange(location: hint.range.location - startCharOffset, length: hint.range.length)
                guard shifted.location >= 0,
                      NSMaxRange(shifted) <= (text as NSString).length
                else { return nil }
                return hint.rebased(to: shifted)
            }
            // The engine will report offsets into the slice, so the map has to be slid by
            // the same amount or every highlight lands `startCharOffset` characters early.
            offsets = offsets?.droppingNarrationPrefix(startCharOffset)
        }

        ttsNarrationOffsets = offsets
        ttsChapterIndex = chapterIndex
        ttsPendingChapterIndex = nil
        let anchor = startCharOffset > 0
            ? CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: startCharOffset)
            : .chapterStart(chapterIndex)
        // ⟐ ttsSwitch — measuring the 下一章 pile-up before changing anything. See
        // TTSChapterSwitchTrace for what each field separates.
        TTSChapterSwitchTrace.span(target: chapterIndex) { step in
            setActiveTTSAnchor(anchor, alignReader: shouldSyncReader)
            step("align")
            ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
            step("ensure")
            prepareNextTTSChapter(after: chapterIndex)
            step("prepare")
            // Resolved here, not in the engine: only the reader knows which book is open,
            // and the cast is per book. Empty when 多角色朗讀 is off, which is also what
            // tells the engines not to split the chapter at quote boundaries at all.
            refreshTTSRoleCast(sampleText: text)
            ttsCoordinator.setPreparationNotice(nil)
            ttsCoordinator.speak(
                text: text,
                title: chapterTitle(forSpineIndex: chapterIndex).converted(to: settings.textConversion),
                bookTitle: ttsNowPlayingBookTitle,
                author: ttsNowPlayingAuthor,
                artwork: ttsNowPlayingArtwork(),
                pronunciationHints: hints,
                speakerAttributions: dialogue.map {
                    ttsSpeakerAttributions(for: $0, droppingPrefix: sliceOffset, textLength: (text as NSString).length)
                }
            )
            step("speak")
            ttsCoordinator.refreshNowPlayingForSystemSurfaces()
            step("nowPlaying")
        }
        return true
    }

    @discardableResult
    func startAdjacentTTSChapter(delta: Int) -> Bool {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        // Skip separators in both directions: next/previous-track should land on something
        // that can actually be read aloud.
        guard let target = narratableTTSChapter(from: baseChapter, direction: delta) else {
            return false
        }
        return startTTSChapter(target, syncReader: true)
    }

    func advanceTTSChapterFromEngine() -> TTSNextUnitOutcome {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        guard let target = narratableTTSChapter(from: baseChapter, direction: 1) else {
            ttsChapterIndex = nil
            ttsNarrationOffsets = nil
            return .finished
        }
        var narration = narrationForTTSChapter(target)
        let text = narration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Not "the book ended" — the chapter just isn't fetched/laid out yet. Hold the
            // session open and let `resolveWaitingTTSChapter` finish the job.
            beginWaitingForTTSChapter(target)
            return .waiting
        }
        switch attachTTSDialogue(to: narration, chapterIndex: target) {
        case let .ready(analysed):
            narration = analysed
        case let .needsAnalysis(request):
            // The prefetch did not finish in time. Hold the session open like any other
            // chapter wait; the analysis completing is what releases it.
            ttsPendingChapterIndex = target
            awaitTTSDialogue(for: target, request: request)
            return .waiting
        }
        commitTTSChapterAdvance(to: target, narration: narration)
        return .ready(narration)
    }

    /// Shared tail of both advance paths (immediate and post-wait): move the anchor, retitle
    /// Now Playing, and start preparing the chapter after this one.
    private func commitTTSChapterAdvance(to target: Int, narration: TTSNarrationUnit) {
        ttsChapterIndex = target
        // A chapter advance always starts at the top, so the unit's own map applies as-is.
        ttsNarrationOffsets = narration.sourceOffsets
        ttsPendingChapterIndex = nil
        setActiveTTSAnchor(
            .chapterStart(target),
            alignReader: true
        )
        ttsCoordinator.updateNowPlayingChapter(title: chapterTitle(forSpineIndex: target).converted(to: settings.textConversion), text: narration.text)
        // The new chapter may introduce characters; they need voices before the engine
        // splits it, which happens as soon as this returns.
        refreshTTSRoleCast(sampleText: narration.text)
        ttsCoordinator.setPreparationNotice(nil)
        prepareNextTTSChapter(after: target)
    }

    // MARK: - TTS chapter readiness

    /// A TOC entry that structurally has no prose to read: 「第N卷」/「正文」/「番外」 headers,
    /// which carry no fetchable content URL and render as a divider page.
    ///
    /// This is a structural test (`shouldRenderAsVolumeSeparator`), never "the text came back
    /// empty" — an empty result from a real chapter means the fetch or parse failed, and that
    /// case must still wait/report rather than be silently skipped.
    func isVolumeSeparatorChapter(_ index: Int) -> Bool {
        guard let refs = book?.onlineChapters, refs.indices.contains(index) else { return false }
        return refs[index].shouldRenderAsVolumeSeparator
    }

    /// Next chapter in `direction` (+1 / -1) that actually has prose, skipping volume
    /// separators. Returns nil at the ends of the book.
    func narratableTTSChapter(from base: Int, direction: Int) -> Int? {
        Self.narratableChapter(from: base, direction: direction, spineCount: spineChapters.count) { candidate in
            let isSeparator = isVolumeSeparatorChapter(candidate)
            if isSeparator { ttsLog("[TTS][Reader] skipping volume separator chapter=\(candidate)") }
            return isSeparator
        }
    }

    /// `narratableTTSChapter`'s walk. Narration counts spine items, so it is bounded by the spine
    /// rather than the TOC — and so a run of consecutive separators terminates instead of looping.
    static func narratableChapter(
        from base: Int,
        direction: Int,
        spineCount: Int,
        isSeparator: (Int) -> Bool
    ) -> Int? {
        guard direction != 0 else { return nil }
        var candidate = base + direction
        while (0..<spineCount).contains(candidate) {
            if !isSeparator(candidate) { return candidate }
            candidate += direction
        }
        return nil
    }

    /// Prepare the chapter after the one being narrated, driven by the *playback* position
    /// rather than by page turns.
    ///
    /// Both preparation steps are required and neither was previously performed for TTS:
    /// `ensureChapterReady` fetches an online chapter's content into the cache, and
    /// `preloadChapter` builds the CoreText layout — and the layout is the only thing
    /// `narrationForTTSChapter` can read for an online book, whose `chapters[i].content` is
    /// always empty. Page-turn-driven `warmUpNext` never runs while the screen is locked, so
    /// without this the next chapter is simply never ready in the listening-only case.
    func prepareNextTTSChapter(after chapterIndex: Int) {
        // Prepare the chapter narration will actually reach, not a separator it will skip.
        guard let next = narratableTTSChapter(from: chapterIndex, direction: 1) else { return }
        ensureChapterReady(chapterIndex: next, priority: .prefetch)
        guard let engine = epubRenderer.engine, usesCoreTextEPUB else {
            prefetchTTSDialogue(for: next)
            return
        }
        Task { @MainActor in
            await engine.preloadChapter(at: next)
            // Analysed while this chapter plays, so the next one starts without a wait.
            prefetchTTSDialogue(for: next)
        }
    }

    /// Enter the wait for `target`. Kicks the fetch if the content isn't cached; otherwise
    /// goes straight to layout. Resolution happens on the real readiness signal — either the
    /// `chapterStates` publisher (content arrived) or `preloadChapter`'s completion (layout
    /// built) — never on a timer.
    func beginWaitingForTTSChapter(_ target: Int) {
        ttsLog("[TTS][Reader] begin waiting for chapter=\(target) contentAvailable=\(isChapterContentAvailable(at: target))")
        ttsPendingChapterIndex = target

        if isChapterContentAvailable(at: target) {
            resolveWaitingTTSChapter(target)
        } else {
            // .jump: the listener is blocked on this chapter right now, so it outranks any
            // in-flight prefetch for a chapter nobody is waiting on.
            ensureChapterReady(chapterIndex: target, priority: .jump)
        }
    }

    /// Content for `target` is in the cache: build its layout, then hand the text to the
    /// engine that is holding the session open.
    func resolveWaitingTTSChapter(_ target: Int) {
        guard ttsPendingChapterIndex == target else { return }
        guard let engine = epubRenderer.engine, usesCoreTextEPUB else {
            // Non-CoreText books read from `allPages` / `spineChapters[i].content`, which need no
            // layout pass — if the text is still empty here there is nothing left to wait for.
            let narration = narrationForTTSChapter(target)
            finishWaitingTTSChapter(target, narration: narration)
            return
        }
        Task { @MainActor in
            // Completion of the layout task IS the signal; no polling, no delay.
            await engine.preloadChapter(at: target)
            guard ttsPendingChapterIndex == target else {
                ttsLog("[TTS][Reader] chapter wait for \(target) superseded during layout")
                return
            }
            finishWaitingTTSChapter(target, narration: narrationForTTSChapter(target))
        }
    }

    func finishWaitingTTSChapter(_ target: Int, narration unanalysed: TTSNarrationUnit) {
        guard ttsPendingChapterIndex == target else { return }
        var narration = unanalysed
        guard ttsCoordinator.isWaitingForNextChapter else {
            // Playback was stopped or restarted while we were preparing; drop the result.
            ttsPendingChapterIndex = nil
            return
        }
        let text = narration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Content cached and layout built, yet still no text: this chapter is genuinely
            // unreadable (empty body, parse failure), so waiting longer cannot help.
            // Reported, not narrated. This is the line behind 「朗讀每次都斷在章末」:
            // the content was cached and the layout pass ran, and there is still no
            // text, so narration stops at a chapter boundary. It reached `NSLog` only
            // until now, which is why no exported log ever explained the stop.
            AppLogger.anomaly(
                localized("朗讀在章節結束處取不到下一章文字"),
                category: .tts,
                detail: [
                    "chapter=\(target)",
                    "contentAvailable=\(isChapterContentAvailable(at: target))",
                    "hasLayout=\(epubRenderer.engine?.chapterPagination(forSpine: target, charOffset: 0) != nil)",
                    "usesCoreTextEPUB=\(usesCoreTextEPUB)",
                ].joined(separator: "\n")
            )
            ttsPendingChapterIndex = nil
            ttsCoordinator.abortWaitingForNextChapter(reason: "empty chapter \(target)")
            return
        }
        switch attachTTSDialogue(to: narration, chapterIndex: target) {
        case let .ready(analysed):
            narration = analysed
        case let .needsAnalysis(request):
            awaitTTSDialogue(for: target, request: request)
            return
        }
        ttsLog("[TTS][Reader] chapter wait resolved chapter=\(target) textCount=\(text.count)")
        commitTTSChapterAdvance(to: target, narration: narration)
        ttsCoordinator.supplyPendingNarration(narration, chapterTitle: chapterTitle(forSpineIndex: target).converted(to: settings.textConversion))
    }

    /// Called from the `chapterStates` observer. Drives the pending wait forward on the real
    /// fetch outcome: `.ready` proceeds to layout, `.failed` ends the session with the reason
    /// (an unreachable source can't be waited out).
    func handleTTSChapterWaitStateChange(_ state: ChapterLoadState, at chapterIndex: Int) {
        guard ttsPendingChapterIndex == chapterIndex else { return }
        switch state {
        case .ready:
            resolveWaitingTTSChapter(chapterIndex)
        case let .failed(reason):
            AppLogger.render(
                "⟐ [TTS][Reader] chapter wait failed chapter=\(chapterIndex) reason=\(reason)",
                level: .error
            )
            ttsPendingChapterIndex = nil
            ttsCoordinator.abortWaitingForNextChapter(reason: reason)
        case .cancelled:
            // Preempted, not refused. `reissueCancelledChapterFetch` asks again; ending the
            // session here stopped narration at a chapter boundary over a fetch that was
            // never carried to a verdict — the lock-screen "stops for no reason" report.
            AppLogger.render(
                "⟐ [TTS][Reader] chapter wait fetch cancelled chapter=\(chapterIndex); awaiting re-request",
                level: .warning
            )
        case .idle, .loading:
            break
        }
    }

    func handleReaderPositionChangedForTTS() {
        guard !isAligningReaderToTTSAnchor else { return }
        guard ttsCoordinator.playbackState != .stopped,
              let anchor = ttsPlaybackAnchor
        else {
            if showTTSJumpPrompt { showTTSJumpPrompt = false }
            if ttsJumpPromptChapterIndex != nil { ttsJumpPromptChapterIndex = nil }
            return
        }

        guard !isReaderAtTTSAnchor(anchor) else {
            if showTTSJumpPrompt { showTTSJumpPrompt = false }
            if ttsJumpPromptChapterIndex != nil { ttsJumpPromptChapterIndex = nil }
            return
        }

        ttsJumpPromptChapterIndex = currentTTSReaderPosition()?.spineIndex ?? currentChapterIndex
        withAnimation(DSAnimation.fast) {
            showTTSJumpPrompt = true
        }
    }

    func jumpBackToTTSChapter() {
        guard let anchor = ttsPlaybackAnchor,
              spineChapters.indices.contains(anchor.spineIndex) else { return }
        withAnimation(DSAnimation.fast) {
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

    /// The chapter text with everything that is not speech removed.
    ///
    /// Paragraph reviews, 本章说 and 神评论 are drawn by the source as SVG and reach the
    /// layout as image attachments, so in the string they are `U+FFFC` object-replacement
    /// characters — not words. They were never stripped on this path, which meant they
    /// counted toward the 300-character chunk budget and were sent to the provider as
    /// literal `%EF%BF%BC`. A paragraph dense with review anchors could produce a chunk
    /// that was almost entirely markers: a synthesis request with nothing to say.
    ///
    /// (The only other `U+FFFC` strip in this file is in the anchor-label helper, a
    /// different function that never fed narration.)
    static func narratableText(from raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            // Removing a marker can leave the spaces that surrounded it stranded, and a
            // run of blank lines reads to a provider as an empty request.
            .replacingOccurrences(
                of: "[ \t]+", with: " ", options: .regularExpression
            )
            .replacingOccurrences(
                of: "\n[ \t]*(\n[ \t]*)+", with: "\n\n", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters heard in the chapter currently being read, in the order they first
    /// speak, for the 多角色朗讀 cast screen.
    ///
    /// Read from the same narration text playback uses, through the same annotator, so the
    /// names offered are exactly the ones the engine will attribute — a name that shows up
    /// here is one that can actually be cast, and one that does not never will be.
    /// alias → canonical name for the open book, from its AI character cards.
    ///
    /// Empty until the reader builds cards, and narration is fully usable without them — the
    /// difference is that 張若塵, 若塵 and 塵哥 stop being three characters with three voices.
    func activeTTSRoleAliases() -> [String: String] {
        guard GlobalSettings.shared.ttsMultiRoleEnabled else { return [:] }
        // The AI analysis' own roster folds the names it has seen; the character cards add
        // what the reader built by hand. Cards win on a conflict — they were asked for.
        let boundary = aiBookAdapter().boundary()
        return AIDialogueCastService.shared.roster(forBook: bookId).aliasMap
            .merging(AICharacterCardStore.shared.aliasMap(forBook: bookId, boundary: boundary)) { _, card in card }
    }

    var ttsSpeakerDetectionKey: String {
        let position = aiDisplayedReadingPosition()
        return "\(bookId):\(ttsChapterIndex ?? currentChapterIndex):\(position?.spineIndex ?? 0):\(position?.charOffset ?? 0):\(aiSourceAdapter?.contentFingerprint ?? "pending")"
    }

    func detectedTTSSpeakers() -> [String] {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("reader.tts.detectSpeakers", since: started) }
        let chapterIndex = ttsChapterIndex ?? currentChapterIndex
        guard spineChapters.indices.contains(chapterIndex) else { return [] }
        let text = narrationForTTSChapter(chapterIndex).text
        guard !text.isEmpty else { return [] }
        var seen: Set<String> = []
        var ordered: [String] = []
        // Folded through the same alias table playback uses, so the cast screen lists the
        // characters that will actually be spoken rather than every name in the prose.
        //
        // No filtering by that table: it used to drop every speaker it did not list, which —
        // once the alias table was the character cards — meant building one card hid every
        // other character in the chapter from the cast screen.
        let aliases = AIDialogueCastService.shared.roster(forBook: bookId).aliasMap
            .merging(AICharacterCardStore.shared.aliasMap(forBook: bookId, boundary: aiBookAdapter().boundary())) { _, card in card }
        for attribution in TTSSpeakerAnnotator.attributions(in: text, aliases: aliases) {
            guard let speaker = attribution.speaker, seen.insert(speaker).inserted else { continue }
            ordered.append(speaker)
        }
        return ordered
    }

    /// The 多角色朗讀 cast for the book being read, or empty when the feature is off.
    ///
    /// Empty is not merely "no voices": the engines read it as "single voice", and skip
    /// splitting the chapter at every quote. That split is what makes multi-role cost
    /// more utterances — and, on a network voice, more requests — so it must not happen
    /// for a listener who never turned the feature on.
    func activeTTSRoleVoices() -> [String: String] {
        guard GlobalSettings.shared.ttsMultiRoleEnabled else { return [:] }
        let explicit = TTSRoleVoiceCast.cast(forBook: bookId, in: GlobalSettings.shared.ttsRoleVoices)
        guard GlobalSettings.shared.ttsAutoCastEnabled else { return explicit }
        // The reader's own choices win over the automatic ones.
        return AIDialogueCastService.shared
            .autoVoices(forBook: bookId, family: TTSVoiceFamily.active())
            .merging(explicit) { _, chosen in chosen }
    }

    func narrationForTTSChapter(_ chapterIndex: Int) -> TTSNarrationUnit {
        guard spineChapters.indices.contains(chapterIndex) else {
            return TTSNarrationUnit(text: "")
        }
        // The legacy delegate may retain chapter zero from its startup even
        // after the browser owns that chapter. Its offsets are not browser offsets.
        let browserOwnsChapter = (epubRenderer.engine as? BrowserLayoutPageEngine)?
            .choice(for: chapterIndex)?.isBrowser == true
        // A translated layout reads its source text through `chapterText` below: narration
        // stays on the book's own words and in the offsets every position uses.
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           !browserOwnsChapter,
           let layout = engine.layouts[chapterIndex],
           layout.translation == nil,
           layout.attributedString.length > 0 {
            let hints = TTSPronunciationAnnotator.hints(
                in: layout.attributedString,
                lexicons: activePublicationSession?.pronunciationLexicons ?? [],
                bookLanguage: activePublicationSession?.language
            )
            let source = layout.attributedString.string
            let narration = Self.narratableText(from: source)
            return TTSNarrationUnit(
                text: narration,
                pronunciationHints: hints,
                // This is the text the reader actually laid out, so the cleanup the
                // narration went through is exactly what the highlight has to undo.
                sourceOffsets: TTSNarrationOffsetMap(narration: narration, source: source)
            )
        }
        // Browser semantics carry their own source ranges. Keep this text in
        // chapter UTF-16 coordinates; the speech chunker trims spoken chunks.
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           let chapterText = engine.chapterText(forSpine: chapterIndex),
           !chapterText.isEmpty {
            return TTSNarrationUnit(
                text: chapterText,
                pronunciationHints: TTSPronunciationAnnotator.hints(
                    in: chapterText,
                    authoredHints: engine.chapterPronunciationHints(forSpine: chapterIndex),
                    lexicons: activePublicationSession?.pronunciationLexicons ?? [],
                    bookLanguage: activePublicationSession?.language
                ),
                // Already in chapter UTF-16 coordinates (no narratable cleanup runs on
                // this branch), so the map is the identity — built the same way rather
                // than special-cased, so callers never branch on which path produced it.
                sourceOffsets: TTSNarrationOffsetMap(narration: chapterText, source: chapterText)
            )
        }
        let pageText = allPages
            .filter { $0.chapterIndex == chapterIndex }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageText.isEmpty { return TTSNarrationUnit(text: pageText) }
        return TTSNarrationUnit(text: spineChapters[chapterIndex].content)
    }

    func textForTTSChapter(_ chapterIndex: Int) -> String {
        narrationForTTSChapter(chapterIndex).text
    }

    // MARK: - AI assistant

    /// Stable source context and one gathered snapshot, independent of layout-cache eviction.
    var aiSourceIdentity: ReaderAISourceIdentity {
        ReaderAISourceIdentity(bookID: bookId, sourceID: book?.bookSourceId,
                               source: book?.source ?? "",
                               chapters: spineChapters)
    }

    var aiCurrentSourceContext: String {
        aiSourceIdentity.context
    }

    /// Use the same visible anchor as the reader bars. The paged anchor remains stale
    /// while scrolling and must never become the AI reading ceiling.
    func aiDisplayedReadingPosition() -> CoreTextReadingPosition? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = displayedCoreTextPosition(in: engine)
            return .init(spineIndex: position.spineIndex, charOffset: position.charOffset)
        }
        return currentPagedReadingPositionForModeSwitch()
    }

    func aiBookAdapter() -> AIBookContentAdapter {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("reader.ai.presentation", since: started, thresholdMs: 10) }
        let position = aiDisplayedReadingPosition()
        let spine = position?.spineIndex ?? currentChapterIndex
        let snapshot = aiSourceIdentity.presentationAdapter(
            prepared: aiSourceAdapter, identity: aiPreparedSourceIdentity
        )
        let reading = snapshot.atReadingPosition(spine: spine, renderedOffset: position?.charOffset ?? 0,
            renderedText: effectiveScrollMode
                ? epubRenderer.scrollEngine?.chapterText(forSpine: spine) ?? epubRenderer.engine?.chapterText(forSpine: spine)
                : epubRenderer.engine?.chapterText(forSpine: spine))
        // Explicitly selected visible text is part of this request's reading context. It may
        // end after the page's leading reading anchor, but it does not authorize later text.
        if let selected = aiLaunch?.selection, snapshot.chunkSections.indices.contains(selected.spineIndex),
           selected.validated(in: reading, boundary: reading.boundary(wholeBook: true)),
           selected.spineIndex > reading.boundary().spineIndex || (selected.spineIndex == reading.boundary().spineIndex && NSMaxRange(selected.range) > reading.boundary().utf16Offset) {
            return reading.atReadingPosition(spine: selected.spineIndex, renderedOffset: NSMaxRange(selected.range),
                renderedText: snapshot.chunkSections[selected.spineIndex].text)
        }
        return reading
    }

    /// Refreshes local source text only. One publish per snapshot; an obsolete gather cannot win.
    func gatherAIBookText() async {
        let acquisitionStarted = Date()
        let generation = UUID()
        aiGatherGeneration = generation
        let capturedBook = bookId
        let capturedIdentity = aiSourceIdentity
        let capturedChapters = capturedIdentity.chapters
        let conversion = settings.textConversion
        var gathered: [Int: String] = [:]
        var statuses: [Int: AISourceManifest.Availability] = [:]
        for index in capturedChapters.indices {
            guard !Task.isCancelled, aiGatherGeneration == generation,
                  bookId == capturedBook, aiSourceIdentity == capturedIdentity else { return }
            let result = await epubRenderer.localChapterText(at: index)
            // AI quotes are located again by searching the rendered text, so the source text
            // has to carry the characters the reader shows.
            gathered[index] = result.text?.converted(to: conversion)
            statuses[index] = result.status
        }
        guard !Task.isCancelled, aiGatherGeneration == generation, bookId == capturedBook,
              aiSourceIdentity == capturedIdentity else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rulesDigest = (try? encoder.encode(ReplaceRuleStore.shared.rules)).map(AISourceManifest.digest) ?? "unavailable"
        let prepared: AIBookContentAdapter
        do {
            prepared = try await AIBookContentAdapter.prepare(bookID: capturedBook, chapters: capturedChapters,
                transformationVersion: "chapterPlainText.v1@rules:" + rulesDigest + "@conversion:" + conversion.rawValue,
                missingStatus: statuses, acquisitionMilliseconds: Date().timeIntervalSince(acquisitionStarted) * 1000,
                texts: gathered)
        } catch is CancellationError { return }
        catch {
            AppLogger.error("AI source snapshot preparation failed", error: error)
            return
        }
        guard !Task.isCancelled, aiGatherGeneration == generation, bookId == capturedBook,
              aiSourceIdentity == capturedIdentity else { return }
        aiPreparedSourceIdentity = capturedIdentity
        aiSourceAdapter = prepared
        if let source = aiSourceAdapter { aiLaunch = aiLaunch?.resolvingSelection(in: source) }
        AIAssistantService.shared.activate(aiBookAdapter())
    }

    func refreshAIContentIfVisible() {
        aiSourceAdapter = nil
        guard showAIAssistantPanel || showTTSPanel else { return }
        aiGatherTask?.cancel()
        aiGatherTask = Task { await gatherAIBookText() }
    }

    func openAICitation(_ citation: LLMCitation, boundary: AIReadingBoundary) {
        aiCitationTask?.cancel()
        let source = aiSourceAdapter ?? aiBookAdapter()
        let capturedBook = bookId
        let capturedContext = aiCurrentSourceContext
        aiCitationTask = Task {
            do {
                let offset = try await AIReadingContentService.citationOffset(citation, source: source, boundary: boundary, renderer: epubRenderer)
                guard !Task.isCancelled, bookId == capturedBook, aiCurrentSourceContext == capturedContext else { return }
                showAIAssistantPanel = false
                jumpToChapter(citation.spineIndex, charOffset: offset)
            } catch is CancellationError { }
            catch {
                guard bookId == capturedBook, aiCurrentSourceContext == capturedContext else { return }
                aiCitationError = error.localizedDescription
            }
        }
    }

    /// How far the reader has got, on the same scale the chunks carry.
    ///
    /// This is the spoiler ceiling, so it is derived from the adapter's own character counts
    /// rather than from chapter index — a 200-character preface followed by a 40,000-character
    /// chapter would otherwise read as 50% after the preface.
    func aiReadingProgress() -> Double {
        let position = aiDisplayedReadingPosition()
        return aiBookAdapter().progress(
            forSpine: position?.spineIndex ?? currentChapterIndex,
            charOffset: position?.charOffset ?? 0
        )
    }

}
