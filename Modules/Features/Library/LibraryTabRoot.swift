import SwiftUI

/// 資源庫, a tab since Phase 5's 5h (decisions 30 and 31): where every source lives, grouped by
/// kind. The public libraries open their own pages, a remote library its catalog, and the
/// source configurations, the remote-library connections and the RSS feeds are managed here,
/// no longer in 設定 or a tab of their own. 探索 stays the cover wall across them all.
///
/// One stack, with 探索's destinations: every page here is one 探索 already pushes.
struct LibraryTabRoot: View {
    @ObservedObject var browser: BrowserState
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @ObservedObject private var rss = RSSStore.shared
    /// The first-launch card saying what moved here (maintainer's choice, 2026-10-13).
    @AppStorage(Self.noticeDismissedKey) private var noticeDismissed = false

    @State private var path = NavigationPath()
    @State private var browserEntry: BrowserEntryPresentation?

    static let noticeDismissedKey = "library.tabNoticeDismissed"

    private struct BrowserEntryPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    private var libraries: [LibraryListing] {
        LibraryListing.ordered(connections: connections.connections, librariesAvailable: availability.isAvailable,
                               order: aggregation.settings.libraryOrder)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !noticeDismissed {
                    Section { notice.rootTabTitleScrollAnchor() }
                        .interfaceSectionSurface()
                }
                let publicLibraries = libraries.filter { $0.key.type == .gutenberg || $0.key.type == .aozora }
                if !publicLibraries.isEmpty {
                    Section(localized("公有書庫")) {
                        ForEach(publicLibraries) { library in
                            NavigationLink(value: ExploreNavigationRoute.library(library.key)) {
                                Label(library.name, systemImage: library.systemImage)
                                    .labelStyle(IconConsistentLabelStyle())
                            }
                            .accessibilityIdentifier("library.public.\(library.key.id)")
                            .modifier(FirstRowScrollAnchor(isFirstRow: noticeDismissed && library.id == publicLibraries.first?.id))
                        }
                    }
                    .interfaceSectionSurface()
                }
                let remoteLibraries = libraries.filter { $0.key.type != .gutenberg && $0.key.type != .aozora }
                let remoteSectionIsFirst = noticeDismissed && publicLibraries.isEmpty
                Section(localized("遠端書庫")) {
                    ForEach(remoteLibraries) { library in
                        remoteLibraryLink(library)
                            .accessibilityIdentifier("library.remote.\(library.key.id)")
                            .modifier(FirstRowScrollAnchor(isFirstRow: remoteSectionIsFirst && library.id == remoteLibraries.first?.id))
                    }
                    NavigationLink {
                        RemoteLibrarySettingsView()
                    } label: {
                        Label(localized("管理遠端書庫"), systemImage: "externaldrive.connected.to.line.below")
                            .labelStyle(IconConsistentLabelStyle())
                    }
                    .accessibilityIdentifier("library.manageRemote")
                    .modifier(FirstRowScrollAnchor(isFirstRow: remoteSectionIsFirst && remoteLibraries.isEmpty))
                }
                .interfaceSectionSurface()
                Section(localized("來源配置")) {
                    NavigationLink(value: ExploreNavigationRoute.sourceManager) {
                        Label(localized("管理來源配置"), systemImage: "books.vertical.fill")
                            .labelStyle(IconConsistentLabelStyle())
                    }
                    .accessibilityIdentifier("library.sources")
                }
                .interfaceSectionSurface()
                Section {
                    NavigationLink(value: ExploreNavigationRoute.subscriptions) {
                        Label(localized("RSS 訂閱"), systemImage: "newspaper.fill")
                            .labelStyle(IconConsistentLabelStyle())
                    }
                    // RSS's unread count, which its tab carried (maintainer's choice, 2026-10-13).
                    .badge(rss.totalUnreadCount())
                    .accessibilityIdentifier("library.rss")
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .themedAppSurface()
            .rootTabTitle(localized("資源庫"), onScroll: .minimizesBar)
            .fullScreenCover(item: $browserEntry) { presentation in
                NavigationStack {
                    BrowserPage(browser: browser, entry: presentation.entry)
                }
                .environmentObject(store)
            }
            .exploreRouteDestinations(openBrowser: { browserEntry = BrowserEntryPresentation(entry: $0) })
            .remoteLibraryDestinations()
            .publicLibraryDestinations()
        }
        .environment(\.openPublicLibraryBooks) { selection in
            if let book = selection.selectedBook { path.append(WorkDetailRoute(book)) }
        }
        .environment(\.explorePush) { $0.append(to: &path) }
    }

    /// A remote library's catalog: its root feed or folder, as 探索 opens it.
    @ViewBuilder
    private func remoteLibraryLink(_ library: LibraryListing) -> some View {
        let label = Label(library.name, systemImage: library.systemImage).labelStyle(IconConsistentLabelStyle())
        switch ExplorePlace.page(of: library.key, name: library.name) {
        case .feed(let route): NavigationLink(value: route) { label }
        case .folder(let route): NavigationLink(value: route) { label }
        default: label
        }
    }

    /// What moved here, until the reader closes it.
    private var notice: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("所有來源都在這裡"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Text(localized("來源配置、遠端書庫和 RSS 訂閱從設定和 RSS 分頁搬到了資源庫。"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                noticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("關閉"))
            .accessibilityIdentifier("library.noticeClose")
        }
    }
}

/// The root title's scroll anchor on the list's first row, whichever section it is in.
private struct FirstRowScrollAnchor: ViewModifier {
    let isFirstRow: Bool

    func body(content: Content) -> some View {
        if isFirstRow { content.rootTabTitleScrollAnchor() } else { content }
    }
}

#if DEBUG
#Preview("資源庫") {
    LibraryTabRoot(browser: BrowserState())
        .environmentObject(BookStore())
}
#endif
