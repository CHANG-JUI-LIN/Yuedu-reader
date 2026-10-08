import SwiftUI

/// 換源 for a book opened outside search: searches the enabled sources for the title
/// and lists every match, grouped by book, with the current source checked.
struct SourceSearchSheet: View {
    let query: String
    let currentSourceId: UUID
    let currentBookURL: String
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
                aggregator.search(query: query, sources: sources)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            aggregator.setResultPresentationActive(phase == .active)
        }
    }

    @ViewBuilder
    private var content: some View {
        if aggregator.isSearching && aggregator.results.isEmpty {
            ProgressView(localized("搜尋來源配置中…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if aggregator.results.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(localized("未找到其他來源配置"), systemImage: "magnifyingglass")
            }
        } else {
            List {
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
        }
    }

    private func isCurrent(_ origin: BookOrigin) -> Bool {
        origin.sourceId == currentSourceId
            && ChangeSourceCache.urlKey(origin.bookUrl) == ChangeSourceCache.urlKey(currentBookURL)
    }
}
