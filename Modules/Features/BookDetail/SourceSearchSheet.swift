import SwiftUI

/// 換源 for a book opened outside search: searches the enabled sources for the title
/// and lists every match, grouped by book, with the current source checked.
///
/// On 作品詳情 (unified library 5f-3) the work's other versions come first — its shelf copy,
/// a library's file — so the page has one 來源 control: this sheet, opened by a button, never
/// a modal from a menu (iOS 17 drops those; Technotes/iOS17MenuModalPresentation.md).
struct SourceSearchSheet: View {
    let query: String
    let currentSourceId: UUID
    let currentBookURL: String
    var otherVersions: [BookDetailInfoChoice.Option] = []
    var onSelectVersion: (String) -> Void = { _ in }
    let onSelectOrigin: (BookOrigin) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var aggregator = SearchAggregator()

    var body: some View {
        NavigationStack {
            content
                .background(PageBackgroundView(scope: .global).ignoresSafeArea())
                .pageBackgroundToolbar(for: .global)
                .navigationTitle(localized("選擇來源"))
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SourceSheetCloseButton { dismiss() }
                    }
                    // Results arrive source by source; keep saying so while they do.
                    if aggregator.isSearching && !aggregator.results.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            ProgressView()
                                .accessibilityLabel(localized("搜尋來源配置中…"))
                        }
                    }
                }
        }
        .onAppear {
            aggregator.setResultPresentationActive(scenePhase == .active)
            if aggregator.results.isEmpty {
                let sources = BookSourceStore.shared.enabledSources
                aggregator.search(query: query, sources: sources, origin: .changeSource)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            aggregator.setResultPresentationActive(phase == .active)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !otherVersions.isEmpty {
            List {
                Section(localized("其他版本")) {
                    ForEach(otherVersions) { version in
                        Button {
                            onSelectVersion(version.id)
                            dismiss()
                        } label: {
                            Text(version.title)
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
                if aggregator.isSearching && aggregator.results.isEmpty {
                    Section {
                        ProgressView(localized("搜尋來源配置中…"))
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                } else if aggregator.results.isEmpty {
                    Section {
                        Text(localized("未找到其他來源配置"))
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textSecondary)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    results
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
        } else if aggregator.isSearching && aggregator.results.isEmpty {
            ProgressView(localized("搜尋來源配置中…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if aggregator.results.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(localized("未找到其他來源配置"), systemImage: "magnifyingglass")
            }
        } else {
            List {
                results
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
        }
    }

    /// The sources' matches, one section per book.
    private var results: some View {
        ForEach(aggregator.results) { searchBook in
            Section {
                ForEach(searchBook.origins) { origin in
                    SourceOriginRow(
                        origin: origin,
                        kind: searchBook.contentKind(for: origin) ?? .text,
                        isCurrent: isCurrent(origin),
                        action: {
                            onSelectOrigin(origin)
                            dismiss()
                        }
                    )
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text(searchBook.author.isEmpty
                    ? searchBook.displayName
                    : "\(searchBook.displayName) · \(searchBook.author)")
            }
        }
    }

    private func isCurrent(_ origin: BookOrigin) -> Bool {
        origin.sourceId == currentSourceId
            && ChangeSourceCache.urlKey(origin.bookUrl) == ChangeSourceCache.urlKey(currentBookURL)
    }
}

#Preview("換源，作品的其他版本") {
    SourceSearchSheet(query: "紅樓夢", currentSourceId: UUID(), currentBookURL: "https://example.com/book",
                      otherVersions: [.init(id: "copy", title: "書架 · 已讀 42%"), .init(id: "webdav", title: "家中 NAS")],
                      onSelectOrigin: { _ in })
}
