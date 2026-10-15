import SwiftUI

// Unified library 5c: a section of Explore's home (design §13.3). The header names the
// section and leads to 查看全部; the books below it are drawn in the section's layout (5d-3).
// Since 5d-3b the home names no source (Phase 5 plan, decision 19): a book's source shows on
// its own page.

extension HomeSection {
    /// The section's name, over its row and in 編輯首頁: the one the reader gave it, else its
    /// binding's. `sourceName` names a binding titled by its source (a feed, a category list
    /// with none).
    func displayTitle(sourceName: String) -> String {
        if !title.isEmpty { return title }
        switch binding {
        case .continueReading: return localized("繼續閱讀")
        case .latest: return localized("最新")
        case .related: return localized("相關")
        case .nextInSeries: return localized("系列下一本")
        case .subscriptionArticles: return localized("訂閱的最新文章")
        case .forYou: return localized("為你推薦")
        case .aiRecommendations: return localized("AI 推薦")
        case .sourceCategories(let categories): return categories.first?.title ?? sourceName
        case .gutenbergCollection(let id):
            return PublicLibraryCollection.all.first { $0.id == id }.map { localized($0.titleKey) } ?? sourceName
        case .gutenbergLists: return localized("精選書單")
        case .gutenbergShelf(let id): return GutenbergShelf.shelf(id: id)?.title ?? sourceName
        case .aozoraNew: return localized(AozoraBrowseMode.newest.titleKey)
        case .aozoraIndex(let kind): return AozoraBrowseMode(rawValue: kind).map { localized($0.titleKey) } ?? sourceName
        case .opdsFeed, .gutenbergFeed, .module, .myLibrary, .unknown: return sourceName
        }
    }
}

/// What a row shows once loaded, resolved against the shelf as it is now.
struct HomeRowContent {
    var cards: [HomeCardContent]
    /// Places inside the source (Aozora's index groups, an OPDS navigation feed), as chips.
    var locations: [CollectionLocation]
    /// 訂閱的最新文章's articles (5g), drawn as articles, not as books.
    var articles: [SubscriptionArticle] = []
    /// 專題集合's lists (decision 37), a card each.
    var collections: [CollectionSummary] = []

    var isEmpty: Bool { cards.isEmpty && locations.isEmpty && articles.isEmpty && collections.isEmpty }

    @MainActor
    init(entries: [CollectionEntry], status: (SourceItemKey) -> CopyLookup.Status?, shelfBooks: [UUID: ReadingBook]) {
        var cards: [HomeCardContent] = []
        var locations: [CollectionLocation] = []
        var articles: [SubscriptionArticle] = []
        var collections: [CollectionSummary] = []
        for entry in entries {
            switch entry {
            case .location(let location): locations.append(location)
            case .article(let article): articles.append(article)
            case .collection(let collection): collections.append(collection)
            case .item:
                if let card = HomeCardContent(entry, status: status, shelfBooks: shelfBooks) {
                    cards.append(card)
                }
            }
        }
        self.cards = cards
        self.locations = locations
        self.articles = articles
        self.collections = collections
    }

    /// One pass over the shelf, for the copies this row shows.
    @MainActor
    init(entries: [CollectionEntry], store: BookStore) {
        let wanted = Set(entries.compactMap { entry -> UUID? in
            if case .item(_, _, .copy(let id)) = entry { return id }
            return nil
        })
        let shelfBooks = wanted.isEmpty ? [:] : Dictionary(
            store.books.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lookup = store.copyLookup()
        self.init(entries: entries, status: lookup.status(for:), shelfBooks: shelfBooks)
    }
}

/// What a section's name offers when long-pressed: the same edits as 編輯首頁 (5d-2), and its
/// 呈現方式 (5d-3).
struct HomeSectionActions {
    let setLayout: (HomeSectionLayout) -> Void
    let hide: () -> Void
    /// Pushes the section's page in 編輯首頁.
    let openSettings: () -> Void
    /// Asks first.
    let delete: () -> Void
}

struct HomeRowView: View {
    let group: HomeSectionGroup
    /// Nil until a row of the section has loaded.
    let content: HomeRowContent?
    /// The section came into view: its rows load (`HomeModel.load`).
    let load: () -> Void
    /// 重試: every failed row of the section (`HomeModel.request`).
    let request: () -> Void
    /// Pushes 查看全部; nil when the source has no page for this row.
    var showAll: (() -> Void)?
    /// A card was tapped; the row's other cards come along for the public-library carousel.
    let open: (HomeCardContent, [HomeCardContent]) -> Void
    let openLocation: (CollectionLocation) -> Void
    /// A list of 專題集合 was tapped; none in a fixture or the form's preview.
    var openCollection: (CollectionSummary) -> Void = { _ in }
    /// An article of 訂閱的最新文章 was tapped (5g); none in a fixture or the form's preview.
    var openArticle: (SubscriptionArticle) -> Void = { _ in }
    /// The section's long press (5d-2, decision 14); none in a fixture.
    var actions: HomeSectionActions?
    /// A shelf copy's ••• on 精簡閱讀卡片 (5d-3c); none in a fixture.
    var bookActions: HomeBookActions?

    var body: some View {
        Group {
            // A loaded row with nothing in it takes no room.
            if case .loaded = group.state, content?.isEmpty ?? true {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    header
                    stateContent
                }
            }
        }
        .task { load() }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        let label = HomeRowTitle(title: group.title, showsChevron: showAll != nil)
            .padding(.horizontal, DSSpacing.lg)

        if let showAll {
            Button(action: showAll) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(localized("查看全部"))
                .accessibilityIdentifier("home.row.header.\(group.id)")
                .contextMenu { actionsMenu }
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.row.header.\(group.id)")
                .contextMenu { actionsMenu }
        }
    }

    /// Also the header's VoiceOver actions: a context menu's items are offered there.
    @ViewBuilder
    private var actionsMenu: some View {
        if let actions { HomeSectionActionsMenu(section: group.section, actions: actions) }
    }

    // MARK: States

    @ViewBuilder
    private var stateContent: some View {
        switch group.state {
        case .idle, .loading:
            placeholder
        case .failed(let message):
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(message)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(3)
                Button(localized("重試"), action: request)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.row.retry.\(group.id)")
            }
            .padding(.horizontal, DSSpacing.lg)
        case .loaded:
            if let content {
                if !content.locations.isEmpty { locationChips(content.locations) }
                if !content.collections.isEmpty {
                    HomeCollectionCards(collections: content.collections, open: openCollection)
                }
                if !content.cards.isEmpty { cards(content.cards) }
                if !content.articles.isEmpty {
                    HomeArticleCards(layout: group.section.layout, articles: content.articles, open: openArticle)
                }
            }
        }
    }

    /// The section's layout with blank cards, so the page does not jump when the books arrive.
    private var placeholder: some View {
        HomeSectionCards(layout: group.section.layout, cards: (0..<6).map(HomeCardContent.placeholder), rowID: group.id,
                         hasShowAll: showAll != nil, open: { _, _ in })
            .redacted(reason: .placeholder)
            .scrollDisabled(true)
            .allowsHitTesting(false)
            .overlay { ProgressView() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localized("載入中…"))
    }

    private func cards(_ cards: [HomeCardContent]) -> some View {
        HomeSectionCards(layout: group.section.layout, cards: cards, rowID: group.id, hasShowAll: showAll != nil, open: open,
                         bookActions: bookActions)
    }

    private func locationChips(_ locations: [CollectionLocation]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(locations, id: \.self) { location in
                    Button(location.title) { openLocation(location) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(DSColor.textPrimary)
                }
            }
        }
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Shared by every row

/// A section's name over its row, in the home's title style; a chevron when it leads to
/// 查看全部, and a line under it when the section says where its books came from (AI 推薦).
struct HomeRowTitle: View {
    let title: String
    var subtitle: String? = nil
    var showsChevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text(title)
                    .font(DSFont.title2.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(DSFont.title3.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// A section's own edits: 呈現方式, 隱藏, 設定 and 刪除. The header's long press offers them,
/// and AI 推薦's ••• after 重新產生.
struct HomeSectionActionsMenu: View {
    let section: HomeSection
    let actions: HomeSectionActions

    var body: some View {
        let layout = section.layout
        let choices = HomeLayoutStyle.choices(for: section.binding)
        // A section of lists has 專題集合 alone: nothing to choose.
        if choices.count > 1 {
            Menu {
                Picker(localized("呈現方式"), selection: Binding(
                    get: { layout.style },
                    set: { actions.setLayout(HomeSectionLayout(style: $0, ranked: layout.showsRanks)) })) {
                    ForEach(choices) { style in
                        Label(localized(style.titleKey), systemImage: style.symbol).tag(style)
                    }
                }
                if layout.style == .list {
                    Toggle(localized("顯示排名"), isOn: Binding(
                        get: { layout.showsRanks },
                        set: { actions.setLayout(HomeSectionLayout(style: .list, ranked: $0)) }))
                }
            } label: {
                Label(localized("呈現方式"), systemImage: "rectangle.3.group")
            }
        }
        Button(localized("動作：隱藏"), systemImage: "eye.slash", action: actions.hide)
        Button(localized("設定"), systemImage: "slider.horizontal.3", action: actions.openSettings)
        Button(localized("刪除"), systemImage: "trash", role: .destructive, action: actions.delete)
    }
}

// MARK: - 範圍's symbols

/// A library's symbol in 範圍. A book source has none: it is named by its own name.
enum SourceKindSymbol {
    static func symbol(for type: ProviderType) -> String? {
        switch type {
        case .library: "books.vertical"
        case .opds, .calibre: "server.rack"
        case .webDAV: "externaldrive.connected.to.line.below"
        case .gutenberg, .aozora: "building.columns"
        case .bookSource, .bibliographic, .module: nil
        }
    }
}
