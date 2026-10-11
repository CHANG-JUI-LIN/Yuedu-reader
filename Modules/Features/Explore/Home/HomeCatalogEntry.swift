import SwiftUI

// Unified library 5d-3b: the full catalogs, always in reach (Phase 5 plan, decision 20).
// The home shows what sections hold; a library's whole catalog is its own page, the one it
// already had (Gutenberg's popular, latest and categories; 青空's indexes; a book source's
// discover page; an OPDS or WebDAV root). At the top of the home: 瀏覽書庫 under 全部, which
// lists every library, and 瀏覽完整目錄 under one library, which opens its page. Neither
// depends on what the sections hold.

/// 瀏覽書庫's page.
struct HomeLibrariesRoute: Hashable {}

/// A link to whichever page an `ExplorePush` names, by its own route type, so it reaches the
/// destination registered for that type.
struct ExplorePushLink<Label: View>: View {
    let push: ExplorePush
    @ViewBuilder let label: () -> Label

    var body: some View {
        switch push {
        case .reader(let route): NavigationLink(value: route, label: label)
        case .remoteBook(let route): NavigationLink(value: route, label: label)
        case .explore(let route): NavigationLink(value: route, label: label)
        case .feed(let route): NavigationLink(value: route, label: label)
        case .folder(let route): NavigationLink(value: route, label: label)
        case .publicLibrary(let route): NavigationLink(value: route, label: label)
        }
    }
}

/// The look of the entry at the top of the home; the caller wraps it in its link.
struct HomeCatalogEntryLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: systemImage)
                .font(DSFont.body)
                .foregroundStyle(DSColor.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
            Spacer(minLength: DSSpacing.sm)
            Image(systemName: "chevron.right")
                .font(DSFont.footnote.weight(.semibold))
                .foregroundStyle(DSColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .frame(minHeight: DSLayout.minimumTapTarget)
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }
}

/// 瀏覽書庫: every library and book source 範圍 offers, each opening its own page. The
/// libraries are one section in 書庫順序 (5d-3e), which may put a public library before a
/// remote one; book sources follow in 探索's order.
struct HomeLibrariesPage: View {
    let libraries: [LibraryListing]
    let sources: [BookSource]

    var body: some View {
        List {
            if !libraries.isEmpty {
                Section(localized("書庫")) {
                    ForEach(libraries) { library in
                        row(library.key, name: library.name, symbol: library.systemImage)
                    }
                }
                .interfaceSectionSurface()
            }
            if !sources.isEmpty {
                Section(localized("來源配置")) {
                    ForEach(sources) { source in
                        row(SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl), name: source.bookSourceName,
                            symbol: nil)
                    }
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("瀏覽書庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }

    @ViewBuilder
    private func row(_ key: SourceInstanceKey, name: String, symbol: String?) -> some View {
        if let page = ExplorePlace.page(of: key, name: name) {
            ExplorePushLink(push: page) {
                if let symbol {
                    Label(name, systemImage: symbol)
                } else {
                    Text(name)
                }
            }
            .accessibilityIdentifier("home.libraries.\(key.type.rawValue).\(key.id)")
        }
    }
}

#Preview("瀏覽書庫") {
    NavigationStack {
        HomeLibrariesPage(libraries: LibraryListing.ordered(connections: [], librariesAvailable: true, order: nil),
                          sources: [])
    }
}
