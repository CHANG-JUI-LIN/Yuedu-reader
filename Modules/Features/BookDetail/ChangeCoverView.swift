import Combine
import SwiftUI

/// 換封面 — covers taken from the book sources the user has installed.
///
/// Streams candidates through the shared `BookOriginSearchService` fan-out — the
/// same search 換源 runs — and keeps the covers whose source actually returned
/// one. Deduped by cover URL: aggregation sources hand back the same CDN image
/// under several channels, and a grid of the identical picture is worthless.
///
/// Legado runs this and its 封面規則 web lookup inside one dialog; here they are
/// two entries, so 封面搜索 (web) stays usable for a book with no matching source.
@MainActor
final class ChangeCoverViewModel: ObservableObject {
    @Published private(set) var candidates: [CoverCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?
    private var seenCoverUrls = Set<String>()

    /// Seeds from the 換源 result cache when one is fresh, so a book whose sources
    /// were already searched shows its covers immediately.
    ///
    /// Read-only on purpose: this search skips sources with no cover rule, so
    /// writing its narrower result set back would degrade 換源's cached list.
    func start(bookId: UUID, title: String, author: String, fetcher: BookSourceFetching) {
        guard !isSearching else { return }
        candidates = []
        seenCoverUrls = []
        hasSearched = true

        if let cached = ChangeSourceCache.shared.freshEntry(
            for: bookId, days: GlobalSettings.shared.searchCacheDays
        ) {
            append(origins: cached.origins)
        }

        let concurrency = NetworkSearchSettings.clampedConcurrency(
            GlobalSettings.shared.searchConcurrency
        )
        let sources = BookSourceStore.shared.enabledSources
        isSearching = true
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await BookOriginSearchService.stream(
                title: title,
                author: author,
                sources: sources,
                concurrency: concurrency,
                fetcher: fetcher,
                // Legado skips sources whose search rule has no cover field:
                // they can never contribute a cover, only latency.
                sourceFilter: { source in
                    !source.ruleSearch.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                },
                onBatch: { origins in
                    self.append(origins: origins)
                }
            )
            guard !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func append(origins: [BookOrigin]) {
        let fresh = origins.compactMap { origin -> CoverCandidate? in
            let url = origin.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seenCoverUrls.insert(url).inserted else { return nil }
            return CoverCandidate(
                coverUrl: url,
                sourceId: origin.sourceId,
                providerName: origin.sourceName
            )
        }
        guard !fresh.isEmpty else { return }
        candidates.append(contentsOf: fresh)
    }
}

/// The 換封面 screen. Picking a cover hands it back to 書籍資訊, which owns the
/// download and the book record.
struct ChangeCoverView: View {
    let bookId: UUID
    let title: String
    let author: String
    let onSelect: (CoverCandidate) -> Void

    @StateObject private var model = ChangeCoverViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
            CoverCandidateGrid(
                bookTitle: title,
                candidates: model.candidates,
                isSearching: model.isSearching,
                hasSearched: model.hasSearched,
                emptyHint: localized("可以改用「封面搜索」上網找，或從相簿選一張圖片。")
            ) { candidate in
                model.stop()
                onSelect(candidate)
                dismiss()
            }
        }
        .navigationTitle(localized("換封面"))
        // Pushed page: the back button is the way out (this screen is entered
        // from 書籍資訊, sheet or push, through a NavigationLink).
        .toolbarTitleDisplayMode(.inlineLarge)
        .themedAppSurface(for: .bookshelf)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // One button whose meaning flips, never an if/else pair:
                // a toolbar item that changes identity drops out on iOS 17.
                Button {
                    if model.isSearching {
                        model.stop()
                    } else {
                        startSearch()
                    }
                } label: {
                    Image(systemName: model.isSearching ? "stop.circle" : "arrow.clockwise")
                }
                .accessibilityLabel(
                    model.isSearching ? localized("停止搜索") : localized("重新搜尋")
                )
            }
        }
        .onAppear(perform: startSearch)
        .onDisappear { model.stop() }
    }

    private func startSearch() {
        model.start(
            bookId: bookId,
            title: title,
            author: author,
            fetcher: AppDependencies.live.bookSourceFetcher
        )
    }
}

#Preview {
    NavigationStack {
        ChangeCoverView(
            bookId: UUID(),
            title: "紅樓夢",
            author: "曹雪芹",
            onSelect: { _ in }
        )
    }
}
