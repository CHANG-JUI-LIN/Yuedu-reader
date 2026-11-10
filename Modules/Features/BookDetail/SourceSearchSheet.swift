import SwiftUI

/// 換源 for a book opened outside search: searches the enabled sources for the book and lists
/// every source that has it — the same `ChangeSourceSearch` as the reader's 換源 sheet, so
/// 停止／分組／篩選／校驗作者／加載字數／評分 and the long-press 來源配置 actions work alike.
///
/// On 作品詳情 (unified library 5f-3) the work's other known reading sources come first — its
/// shelf copy, a library's file read from (decision 32) — so the page has one 來源 control: this sheet, opened by a button, never
/// a modal from a menu (iOS 17 drops those; Technotes/iOS17MenuModalPresentation.md).
///
/// A pick goes back through `onSelectOrigin`; the detail page asks 「是否確認換源」 itself when
/// the kind differs (`sourceKindMismatchAlert`), so this sheet does not ask twice.
struct SourceSearchSheet: View {
    let query: String
    var author: String = ""
    let currentSourceId: UUID
    let currentBookURL: String
    /// The book's kind: deleting its 來源配置 switches to the first origin of the same kind.
    var kind: OnlineBookContentKind = .text
    /// The origin in use's name and latest chapter, for its 目前來源 row.
    var currentSourceName: String = ""
    var currentLastChapter: String = ""
    var otherVersions: [BookDetailInfoChoice.Option] = []
    var onSelectVersion: (String) -> Void = { _ in }
    let onSelectOrigin: (BookOrigin) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = ChangeSourceSearch(fetcher: AppDependencies.live.bookSourceFetcher)
    /// Legado's `autoChangeSource` after the current 來源配置 is deleted here.
    @State private var autoSwitchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                ChangeSourceCurrentSection(
                    search: search,
                    name: currentSourceTitle,
                    lastChapter: currentLastChapter,
                    source: currentSource,
                    onDeletedCurrent: switchAfterDeletingCurrent
                )
                .listRowBackground(Color.clear)

                if !otherVersions.isEmpty {
                    Section(localized("已知的閱讀來源")) {
                        ForEach(otherVersions) { version in
                            SourceVersionRow(title: version.title) {
                                onSelectVersion(version.id)
                                dismiss()
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                ChangeSourceResultsSection(
                    search: search,
                    isSwitching: autoSwitchTask != nil,
                    onSelect: { origin in
                        onSelectOrigin(origin)
                        dismiss()
                    }
                )
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
            .changeSourceFilter(search)
            .changeSourceEditor(search)
            .background(PageBackgroundView(scope: .global).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            .navigationTitle(localized("選擇來源"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SourceSheetCloseButton { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ChangeSourceSearchButton(search: search)
                    ChangeSourceOptionsMenu(search: search)
                }
            }
        }
        .onAppear {
            guard search.target == nil else { return }
            search.start(ChangeSourceTarget(
                title: query,
                author: author,
                bookId: nil,
                currentSourceId: currentSourceId,
                currentBookURL: currentBookURL,
                readingChapter: nil,
                kind: kind
            ))
        }
        .onDisappear {
            autoSwitchTask?.cancel()
            search.stop()
        }
    }

    private var currentSource: BookSource? {
        BookSourceStore.shared.source(id: currentSourceId)
    }

    private var currentSourceTitle: String {
        let name = currentSource?.bookSourceName ?? currentSourceName
        return name.isEmpty ? localized("未知來源配置") : name
    }

    /// The book's own 來源配置 was deleted: switch to the first result of its kind whose
    /// 目錄 loads, as Legado's change-source dialog does.
    private func switchAfterDeletingCurrent() {
        autoSwitchTask?.cancel()
        autoSwitchTask = Task { @MainActor in
            defer { autoSwitchTask = nil }
            guard let found = await search.firstLoadable(kind: kind, excluding: currentSourceId) else {
                guard !Task.isCancelled else { return }
                search.reportError(localized("自動換源失敗：沒有可用的來源配置"))
                return
            }
            guard !Task.isCancelled else { return }
            search.stop()
            onSelectOrigin(found.0)
            dismiss()
        }
    }
}

#Preview("換源，作品的其他版本") {
    SourceSearchSheet(query: "紅樓夢", author: "曹雪芹", currentSourceId: UUID(),
                      currentBookURL: "https://example.com/book",
                      currentSourceName: "示範來源配置",
                      currentLastChapter: "第一百二十回 甄士隱詳說太虛情",
                      otherVersions: [.init(id: "copy", title: "書架 · 已讀 42%"), .init(id: "webdav", title: "家中 NAS")],
                      onSelectOrigin: { _ in })
}
