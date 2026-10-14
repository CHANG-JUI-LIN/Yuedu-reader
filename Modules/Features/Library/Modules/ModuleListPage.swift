import SwiftUI

/// A module row's 查看全部 (Phase 6f-2): its list as a grid of covers, a page at a time.
struct ModuleListPage: View {
    let route: ModuleListRoute
    @StateObject private var model: ModuleListModel
    @EnvironmentObject private var store: BookStore
    @Environment(\.explorePush) private var push

    init(route: ModuleListRoute, model: ModuleListModel? = nil) {
        self.route = route
        _model = StateObject(wrappedValue: model ?? ModuleListModel(route: route))
    }

    private var cards: [HomeCardContent] {
        HomeRowContent(entries: model.entries, store: store).cards
    }

    var body: some View {
        ScrollView {
            // Not a `LazyVStack`: the grid draws its covers once it has measured its width,
            // which a lazy stack never gives it (the home holds it in a row's `VStack` too).
            // The grid itself is lazy.
            VStack(spacing: DSSpacing.lg) {
                content
            }
            .padding(.bottom, DSSpacing.xxl)
        }
        .softScrollEdges()
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        // Once: back from a book, the pages read stay.
        .task { if !model.hasStarted { await model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView(localized("讀取中"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.xxl)
        case .missing:
            ContentUnavailableView(localized("找不到這個模組。"), systemImage: "puzzlepiece.extension")
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("載入失敗"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button(localized("重試")) { Task { await model.load() } }
            }
        case .loaded:
            let cards = cards
            if cards.isEmpty {
                ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical")
            } else {
                HomeSectionCards(layout: HomeSectionLayout(style: .coverGrid), cards: cards,
                                 rowID: "module.list.\(route.moduleID).\(route.entryID)", hasShowAll: false) { card, _ in
                    if let work = card.route { push?(.work(work)) }
                }
            }
            if let error = model.loadMoreError {
                Text(error)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .padding(.horizontal, DSSpacing.lg)
            }
            if model.canLoadMore {
                Button { Task { await model.loadMore() } } label: {
                    if model.isLoadingMore { ProgressView() } else { Text(localized(model.loadMoreError == nil ? "載入更多" : "重試")) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(model.isLoadingMore)
                .accessibilityIdentifier("module.list.more")
            }
        }
    }
}

#Preview("模組清單：找不到") {
    NavigationStack {
        ModuleListPage(route: ModuleListRoute(moduleID: "missing", entryID: "new", title: "新書", parameters: [:]),
                       model: ModuleListModel(route: ModuleListRoute(moduleID: "missing", entryID: "new", title: "新書", parameters: [:]),
                                              library: RuleModulePreviewData.library([])))
    }
    .environmentObject(BookStore())
}

#Preview("模組清單：讀取") {
    let route = ModuleListRoute(moduleID: "preview.module", entryID: "top", title: "排行", parameters: [:])
    return NavigationStack {
        ModuleListPage(route: route, model: ModuleListModel(route: route, library: RuleModulePreviewData.listsLibrary()))
    }
    .environmentObject(BookStore())
}
