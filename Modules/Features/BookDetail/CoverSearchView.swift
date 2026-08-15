import Combine
import SwiftUI

/// One cover offered by 封面搜索, with the source it came from — the source is
/// what supplies the download headers, so it travels with the URL.
struct CoverCandidate: Identifiable, Equatable {
    let id: String
    let coverUrl: String
    let sourceId: UUID
    let sourceName: String
}

/// Cross-source cover search, Legado's 换封面 dialog.
///
/// Streams candidates through the shared `BookOriginSearchService` fan-out — the
/// same search 換源 runs — and keeps the covers whose source actually returned
/// one. Deduped by cover URL: aggregation sources hand back the same CDN image
/// under several channels, and a grid of the identical picture is worthless.
@MainActor
final class CoverSearchViewModel: ObservableObject {
    @Published private(set) var candidates: [CoverCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?
    private var seenCoverUrls = Set<String>()

    var isEmpty: Bool { candidates.isEmpty }

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
                id: url,
                coverUrl: url,
                sourceId: origin.sourceId,
                sourceName: origin.sourceName
            )
        }
        guard !fresh.isEmpty else { return }
        candidates.append(contentsOf: fresh)
    }
}

/// The 封面搜索 grid. Picking a cover hands it back to 書籍資訊, which owns the
/// download and the book record.
struct CoverSearchView: View {
    let bookId: UUID
    let title: String
    let author: String
    let onSelect: (CoverCandidate) -> Void

    @StateObject private var model = CoverSearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 3
    }

    var body: some View {
        AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
            content
        }
        .navigationTitle(localized("封面搜索"))
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

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DSSpacing.md),
                    count: columnCount
                ),
                spacing: DSSpacing.lg
            ) {
                ForEach(model.candidates) { candidate in
                    coverCell(candidate)
                }
            }
            .padding(DSSpacing.lg)

            statusFooter
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.xxl)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if model.isSearching {
            HStack(spacing: DSSpacing.sm) {
                ProgressView()
                Text(
                    model.isEmpty
                        ? localized("正在搜尋封面…")
                        : localized("正在搜尋更多封面…")
                )
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        } else if model.isEmpty && model.hasSearched {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(DSFont.fixed(size: 36))
                    .foregroundStyle(DSColor.textSecondary.opacity(0.4))
                    // Decorative: the text below says the same thing.
                    .accessibilityHidden(true)
                Text(localized("沒有找到其他封面"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                Text(localized("可以改用相簿裡的圖片，或直接貼上封面網址。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DSSpacing.xxl)
        }
    }

    private func coverCell(_ candidate: CoverCandidate) -> some View {
        Button {
            model.stop()
            onSelect(candidate)
            dismiss()
        } label: {
            VStack(spacing: DSSpacing.xs) {
                BookCoverImage(
                    coverURL: candidate.coverUrl,
                    title: title,
                    sourceBaseURL: source(for: candidate)?.bookSourceUrl,
                    sourceHeaders: source(for: candidate)?.parsedHeaders ?? [:]
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .stroke(DSColor.textSecondary.opacity(0.2), lineWidth: 0.5)
                )

                Text(candidate.sourceName)
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("封面") + "，" + candidate.sourceName)
        .accessibilityHint(localized("點兩下使用這張封面"))
        .accessibilityAddTraits(.isButton)
    }

    private func source(for candidate: CoverCandidate) -> BookSource? {
        BookSourceStore.shared.sources.first { $0.id == candidate.sourceId }
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
        CoverSearchView(
            bookId: UUID(),
            title: "紅樓夢",
            author: "曹雪芹",
            onSelect: { _ in }
        )
    }
}
