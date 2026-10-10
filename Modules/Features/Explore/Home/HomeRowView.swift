import SwiftUI

// Unified library 5c: a row of Explore's home and the 我的書庫 tiles (design §13.3). The row
// header names the row and its source, Emby's way, and leads to 查看全部; the covers below it
// swipe sideways as Apple Books' shelves do.

extension HomeModel.Row {
    /// The row's own title: the one the reader gave the section, else its binding's.
    var title: String {
        if !section.title.isEmpty { return section.title }
        switch section.binding {
        case .continueReading: return localized("繼續閱讀")
        case .latest: return String(format: localized("%@・最新"), sourceName)
        case .related: return localized("相關")
        case .sourceCategories(let categories): return categories.first?.title ?? sourceName
        case .gutenbergCollection(let id):
            return PublicLibraryCollection.all.first { $0.id == id }.map { localized($0.titleKey) } ?? sourceName
        case .aozoraNew: return localized(AozoraBrowseMode.newest.titleKey)
        case .aozoraIndex(let kind): return AozoraBrowseMode(rawValue: kind).map { localized($0.titleKey) } ?? sourceName
        case .opdsFeed, .gutenbergFeed, .myLibrary, .unknown: return sourceName
        }
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

struct HomeRowView: View {
    let row: HomeModel.Row
    /// Nil until the row has loaded.
    let content: HomeRowContent?
    /// The row came into view (`HomeModel.load`).
    let load: () -> Void
    /// 載入 or 重試 (`HomeModel.request`).
    let request: () -> Void
    /// Pushes 查看全部; nil when the source has no page for this row.
    var showAll: (() -> Void)?
    /// A card was tapped; the row's other cards come along for the public-library carousel.
    let open: (HomeCardContent, [HomeCardContent]) -> Void
    let openLocation: (CollectionLocation) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var scaledCoverWidth = DSLayout.homeCardCoverWidth
    @Environment(\.publicLibraryCoverFrames) private var coverFrames

    private var coverWidth: CGFloat { min(scaledCoverWidth, DSLayout.homeCardCoverMaxWidth) }

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
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.row.header.\(row.id)")
        }
    }

    // MARK: States

    @ViewBuilder
    private var stateContent: some View {
        switch row.state {
        case .idle, .loading:
            placeholder
        case .awaitingRequest:
            Button(localized("載入"), action: request)
                .buttonStyle(.bordered)
                .padding(.horizontal, DSSpacing.lg)
                .accessibilityIdentifier("home.row.load.\(row.id)")
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

    /// Blank covers the size of the real ones, so the page does not jump when they arrive.
    /// Laid out as the loaded row is, in a scroll view that does not scroll.
    private var placeholder: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        RoundedRectangle(cornerRadius: DSRadius.searchListCover, style: .continuous)
                            .fill(DSColor.neutralControlFill)
                            .frame(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
                            .padding(.bottom, DSSpacing.xs)
                        Text(verbatim: "Placeholder").font(DSFont.subheadline.weight(.semibold)).lineLimit(1)
                        Text(verbatim: "Author").font(DSFont.footnote).lineLimit(1)
                    }
                    .frame(width: coverWidth, alignment: .leading)
                    .redacted(reason: .placeholder)
                }
            }
        }
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .overlay { ProgressView() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("載入中…"))
    }

    private func cards(_ cards: [HomeCardContent]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                // By position: a source can list one item twice.
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    Button {
                        coverFrames?.activeScope = row.id
                        open(card, cards)
                    } label: {
                        HomeBookCard(content: card, coverWidth: coverWidth)
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(card.accessibilityLabel)
                    .accessibilityValue(card.accessibilityValue)
                    .accessibilityIdentifier("home.card.\(card.id.instance.type.rawValue).\(card.id.item)")
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .environment(\.publicLibraryCoverScope, row.id)
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

// MARK: - 我的書庫

/// The browser, the custom pages and a tile per source, laid out as 探索's entries always were
/// (the reader's grid, or the list when 格狀 is off or at accessibility text sizes).
struct HomeLibraryTiles<MenuItems: View>: View {
    let tiles: [HomeModel.Tile]
    let open: (HomeModel.Tile) -> Void
    /// A tile's long-press actions: a custom page's or a book source's, as on 探索 before.
    @ViewBuilder let menu: (HomeModel.Tile) -> MenuItems

    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey) private var gridColumnCount = ExploreGridDensity.default.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: ExploreEntryLabel.Layout {
        guard showsGrid, !dynamicTypeSize.isAccessibilitySize else { return .list }
        return .grid(.fitting(gridColumnCount, dynamicTypeSize: dynamicTypeSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("我的書庫"))
                .font(DSFont.title2.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            grid {
                ForEach(tiles, id: \.self) { tile in
                    Button { open(tile) } label: { label(for: tile) }
                        .buttonStyle(ExploreTileButtonStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(tile.name)
                        .accessibilityIdentifier(Self.identifier(for: tile))
                        .contextMenu { menu(tile) }
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch layout {
        case .grid(let density):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: density.rawValue),
                      spacing: DSSpacing.md, content: content)
        case .list:
            LazyVStack(spacing: DSSpacing.md, content: content)
        }
    }

    /// A book source keeps its emoji or first character, as on 探索 today; every other
    /// place has a symbol for its kind.
    private func label(for tile: HomeModel.Tile) -> ExploreEntryLabel {
        switch tile {
        case .browser:
            return ExploreEntryLabel(title: tile.name, artwork: .symbol("safari"), layout: layout)
        case .customPage:
            return ExploreEntryLabel(name: tile.name, layout: layout)
        case .source(let source, _):
            guard let symbol = HomeLibraryTileSymbol.symbol(for: source.type) else {
                return ExploreEntryLabel(name: tile.name, layout: layout)
            }
            return ExploreEntryLabel(title: tile.name, artwork: .symbol(symbol), layout: layout)
        }
    }

    static func identifier(for tile: HomeModel.Tile) -> String {
        switch tile {
        case .browser: "home.tile.browser"
        case .customPage(let id, _): "home.tile.page.\(id.uuidString)"
        case .source(let source, _): "home.tile.\(source.type.rawValue).\(source.id)"
        }
    }
}

extension HomeLibraryTiles where MenuItems == EmptyView {
    init(tiles: [HomeModel.Tile], open: @escaping (HomeModel.Tile) -> Void) {
        self.init(tiles: tiles, open: open) { _ in EmptyView() }
    }
}

enum HomeLibraryTileSymbol {
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
