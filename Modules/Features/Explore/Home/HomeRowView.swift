import SwiftUI

// Unified library 5c: a row of Explore's home (design §13.3). The row
// header names the row and its source, Emby's way, and leads to 查看全部; the covers below it
// swipe sideways as Apple Books' shelves do.

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
        case .sourceCategories(let categories): return categories.first?.title ?? sourceName
        case .gutenbergCollection(let id):
            return PublicLibraryCollection.all.first { $0.id == id }.map { localized($0.titleKey) } ?? sourceName
        case .aozoraNew: return localized(AozoraBrowseMode.newest.titleKey)
        case .aozoraIndex(let kind): return AozoraBrowseMode(rawValue: kind).map { localized($0.titleKey) } ?? sourceName
        case .opdsFeed, .gutenbergFeed, .myLibrary, .unknown: return sourceName
        }
    }
}

extension HomeModel.Row {
    /// The row's own title: the one the reader gave the section, else its binding's. 最新's
    /// rows, one per source, are named by their source.
    var title: String {
        if section.title.isEmpty, case .latest = section.binding {
            return String(format: localized("%@・最新"), sourceName)
        }
        return section.displayTitle(sourceName: sourceName)
    }

    /// The source under the title. None for rows that draw from every source, or whose title
    /// already names it.
    var subtitle: String? {
        switch section.binding {
        case .continueReading, .related, .latest: return nil
        default: return title == sourceName ? nil : sourceName
        }
    }
}

/// What a row shows once loaded, resolved against the shelf as it is now.
struct HomeRowContent {
    var cards: [HomeCardContent]
    /// Places inside the source (Aozora's index groups, an OPDS navigation feed), as chips.
    var locations: [CollectionLocation]

    var isEmpty: Bool { cards.isEmpty && locations.isEmpty }

    @MainActor
    init(entries: [CollectionEntry], sourceName: String, status: (SourceItemKey) -> CopyLookup.Status?,
         shelfBooks: [UUID: ReadingBook]) {
        var cards: [HomeCardContent] = []
        var locations: [CollectionLocation] = []
        for entry in entries {
            switch entry {
            case .location(let location): locations.append(location)
            case .item:
                if let card = HomeCardContent(entry, sourceName: sourceName, status: status, shelfBooks: shelfBooks) {
                    cards.append(card)
                }
            }
        }
        self.cards = cards
        self.locations = locations
    }

    /// One pass over the shelf, for the copies this row shows.
    @MainActor
    init(entries: [CollectionEntry], sourceName: String, store: BookStore) {
        let wanted = Set(entries.compactMap { entry -> UUID? in
            if case .item(_, _, .copy(let id)) = entry { return id }
            return nil
        })
        let shelfBooks = wanted.isEmpty ? [:] : Dictionary(
            store.books.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lookup = store.copyLookup()
        self.init(entries: entries, sourceName: sourceName, status: lookup.status(for:), shelfBooks: shelfBooks)
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
    let row: HomeModel.Row
    /// Nil until the row has loaded.
    let content: HomeRowContent?
    /// The row came into view (`HomeModel.load`).
    let load: () -> Void
    /// 重試 (`HomeModel.request`).
    let request: () -> Void
    /// Pushes 查看全部; nil when the source has no page for this row.
    var showAll: (() -> Void)?
    /// A card was tapped; the row's other cards come along for the public-library carousel.
    let open: (HomeCardContent, [HomeCardContent]) -> Void
    let openLocation: (CollectionLocation) -> Void
    /// The section's long press (5d-2, decision 14); none in a fixture.
    var actions: HomeSectionActions?

    var body: some View {
        Group {
            // A loaded row with nothing in it takes no room.
            if case .loaded = row.state, content?.isEmpty ?? true {
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
        let label = HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(row.title)
                    .font(DSFont.title2.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            if showAll != nil {
                Image(systemName: "chevron.right")
                    .font(DSFont.title3.weight(.semibold))
                    .foregroundStyle(DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, DSSpacing.lg)

        if let showAll {
            Button(action: showAll) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(localized("查看全部"))
                .accessibilityIdentifier("home.row.header.\(row.id)")
                .contextMenu { actionsMenu }
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.row.header.\(row.id)")
                .contextMenu { actionsMenu }
        }
    }

    /// Also the header's VoiceOver actions: a context menu's items are offered there.
    @ViewBuilder
    private var actionsMenu: some View {
        if let actions {
            let layout = row.section.layout
            Menu {
                Picker(localized("呈現方式"), selection: Binding(
                    get: { layout.style },
                    set: { actions.setLayout(HomeSectionLayout(style: $0, ranked: layout.showsRanks)) })) {
                    ForEach(HomeLayoutStyle.allCases) { style in
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
            Button(localized("隱藏"), systemImage: "eye.slash", action: actions.hide)
            Button(localized("設定"), systemImage: "slider.horizontal.3", action: actions.openSettings)
            Button(localized("刪除"), systemImage: "trash", role: .destructive, action: actions.delete)
        }
    }

    // MARK: States

    @ViewBuilder
    private var stateContent: some View {
        switch row.state {
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
                    .accessibilityIdentifier("home.row.retry.\(row.id)")
            }
            .padding(.horizontal, DSSpacing.lg)
        case .loaded:
            if let content {
                if !content.locations.isEmpty { locationChips(content.locations) }
                if !content.cards.isEmpty { cards(content.cards) }
            }
        }
    }

    /// The section's layout with blank cards, so the page does not jump when the books arrive.
    private var placeholder: some View {
        HomeSectionCards(layout: row.section.layout, cards: (0..<6).map(HomeCardContent.placeholder), rowID: row.id,
                         hasShowAll: showAll != nil, open: { _, _ in })
            .redacted(reason: .placeholder)
            .scrollDisabled(true)
            .allowsHitTesting(false)
            .overlay { ProgressView() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localized("載入中…"))
    }

    private func cards(_ cards: [HomeCardContent]) -> some View {
        HomeSectionCards(layout: row.section.layout, cards: cards, rowID: row.id, hasShowAll: showAll != nil, open: open)
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

// MARK: - 範圍's symbols

/// A library's symbol in 範圍. A book source has none: it is named by its own name.
enum SourceKindSymbol {
    static func symbol(for type: ProviderType) -> String? {
        switch type {
        case .library: "books.vertical"
        case .opds, .calibre: "server.rack"
        case .webDAV: "externaldrive.connected.to.line.below"
        case .gutenberg, .aozora: "building.columns"
        case .bookSource, .bibliographic: nil
        }
    }
}
