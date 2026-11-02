import SwiftUI

// MARK: - Bookmark actions

/// The long-press actions on a bookmark: open the page, transcode it straight into
/// the reader, or delete it.
struct BrowserBookmarkMenuItems: View {
    let bookmark: BrowserBookmark
    let onOpen: () -> Void
    let onTranscode: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label(localized("開啟網頁"), systemImage: "safari")
        }
        Button(action: onTranscode) {
            Label(localized("直接轉碼閱讀"), systemImage: "book")
        }
        Divider()
        Button(role: .destructive) {
            BrowserBookmarkStore.shared.remove(bookmark)
        } label: {
            Label(localized("刪除"), systemImage: "trash")
        }
    }
}

// MARK: - Bookmarks and history

/// The browser's sites as a list: every bookmark, then the pages browsed recently — what
/// Safari's start page and history hold. The browser shows it while no page is open, and
/// its 書籤 button shows it over a page. Both kinds are removed by swiping.
struct BrowserSitesList: View {
    let onOpen: (String) -> Void
    let onTranscode: (String) -> Void

    @ObservedObject private var store = BrowserBookmarkStore.shared
    @ObservedObject private var history = BrowseHistoryStore.shared
    @State private var confirmsHistoryClear = false

    var body: some View {
        List {
            Section(localized("書籤")) {
                if store.bookmarks.isEmpty {
                    Text(localized("在網頁點「加入書籤」，網站就會出現在這裡。"))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                ForEach(store.bookmarks) { bookmark in
                    Button { onOpen(bookmark.url) } label: {
                        BrowserSiteRow(
                            iconURL: bookmark.faviconURL,
                            title: bookmark.title,
                            detail: bookmark.host,
                            trailing: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        BrowserBookmarkMenuItems(
                            bookmark: bookmark,
                            onOpen: { onOpen(bookmark.url) },
                            onTranscode: { onTranscode(bookmark.url) }
                        )
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.bookmarks[$0] }.forEach(store.remove)
                }
            }
            .interfaceSectionSurface()

            Section {
                if history.entries.isEmpty {
                    Text(localized("瀏覽過的網頁會出現在這裡"))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                ForEach(history.entries) { entry in
                    Button { onOpen(entry.url) } label: {
                        BrowserSiteRow(
                            iconURL: history.faviconURL(for: entry),
                            title: entry.title,
                            detail: entry.host,
                            trailing: Self.relativeTime(entry.date)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { history.entries[$0] }.forEach(history.remove)
                }
            } header: {
                HStack {
                    Text(localized("最近瀏覽"))
                    Spacer()
                    if !history.entries.isEmpty {
                        Button(localized("清除"), role: .destructive) { confirmsHistoryClear = true }
                            .font(DSFont.footnote)
                            .textCase(nil)
                            .confirmationDialog(
                                localized("要清除所有瀏覽記錄嗎？"),
                                isPresented: $confirmsHistoryClear,
                                titleVisibility: .visible
                            ) {
                                Button(localized("清除"), role: .destructive) { history.clear() }
                                Button(localized("取消"), role: .cancel) {}
                            }
                    }
                }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return localized("剛剛") }
        if seconds < 3600 { return String(format: localized("%d 分鐘前"), seconds / 60) }
        if seconds < 86400 { return String(format: localized("%d 小時前"), seconds / 3600) }
        if seconds < 86400 * 7 { return String(format: localized("%d 天前"), seconds / 86400) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

/// The browser's 書籤 button over an open page: the same list, closing as a site opens.
struct BrowserBookmarksSheet: View {
    let onOpen: (String) -> Void
    let onTranscode: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BrowserSitesList(
                onOpen: { dismiss(); onOpen($0) },
                onTranscode: { dismiss(); onTranscode($0) }
            )
            .pageBackgroundToolbar(for: .explore)
            .navigationTitle(localized("書籤"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A site in the browser's lists: its icon, its title, and its host underneath.
private struct BrowserSiteRow: View {
    let iconURL: URL?
    let title: String
    let detail: String
    let trailing: String?

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            AsyncImage(url: iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "globe").foregroundStyle(DSColor.textSecondary)
                }
            }
            .frame(width: DSLayout.browserRowIconSide, height: DSLayout.browserRowIconSide)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            if let trailing {
                Text(trailing)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .frame(minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Start page (Safari)

/// The browser with no page open, laid out as Safari's start page: the bookmarks as a grid
/// of site icons (Safari's Favorites), then the sites visited lately, and 編輯 at the
/// foot to choose which of them show.
struct BrowserStartPage: View {
    let onOpen: (String) -> Void
    let onTranscode: (String) -> Void

    @ObservedObject private var store = BrowserBookmarkStore.shared
    @ObservedObject private var history = BrowseHistoryStore.shared
    @AppStorage("browserStart.showsBookmarks") private var showsBookmarks = true
    @AppStorage("browserStart.showsHistory") private var showsHistory = true
    @State private var showsAllBookmarks = false
    @State private var showsCustomize = false

    /// Two rows of four, as Safari folds its Favorites.
    private static let foldedCount = 8

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DSLayout.browserStartTileMinWidth), spacing: DSSpacing.md, alignment: .top)]
    }

    private var shownBookmarks: [BrowserBookmark] {
        showsAllBookmarks ? store.bookmarks : Array(store.bookmarks.prefix(Self.foldedCount))
    }

    /// The latest visit to each site.
    private var recentSites: [BrowseHistoryEntry] {
        var seen = Set<String>()
        return history.entries
            .filter { seen.insert($0.host.isEmpty ? $0.url : $0.host).inserted }
            .prefix(Self.foldedCount)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                if showsBookmarks {
                    bookmarksSection
                }
                if showsHistory, !recentSites.isEmpty {
                    recentSection
                }
                // Safari's 編輯: a small white capsule lifted off the page; the tap
                // area keeps the full control height around it.
                Button { showsCustomize = true } label: {
                    Text(localized("編輯"))
                        .font(DSFont.body.weight(.semibold))
                        .foregroundStyle(DSColor.textPrimary)
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.vertical, DSSpacing.sm)
                        .background(DSColor.surface, in: Capsule())
                        .shadow(color: DSColor.appIconShadow, radius: DSLayout.browserLiftShadowRadius, y: DSLayout.browserLiftShadowY)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ExploreTileButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityLabel(localized("自訂起始頁"))
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.lg)
        }
        .softScrollEdges()
        .scrollDismissesKeyboard(.immediately)
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .sheet(isPresented: $showsCustomize) {
            BrowserStartCustomizeSheet(showsBookmarks: $showsBookmarks, showsHistory: $showsHistory)
        }
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(localized("書籤"))
                Spacer(minLength: DSSpacing.sm)
                if store.bookmarks.count > Self.foldedCount {
                    Button(showsAllBookmarks ? localized("收合") : localized("顯示全部")) {
                        showsAllBookmarks.toggle()
                    }
                    .font(DSFont.subheadline)
                }
            }
            if store.bookmarks.isEmpty {
                Text(localized("在網頁點「加入書籤」，網站就會出現在這裡。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.lg) {
                    ForEach(shownBookmarks) { bookmark in
                        Button { onOpen(bookmark.url) } label: {
                            BrowserSiteTile(title: bookmark.title, iconURL: bookmark.faviconURL)
                        }
                        .buttonStyle(ExploreTileButtonStyle())
                        .contextMenu {
                            BrowserBookmarkMenuItems(
                                bookmark: bookmark,
                                onOpen: { onOpen(bookmark.url) },
                                onTranscode: { onTranscode(bookmark.url) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            sectionTitle(localized("最近瀏覽"))
            LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.lg) {
                ForEach(recentSites) { entry in
                    Button { onOpen(entry.url) } label: {
                        BrowserSiteTile(
                            title: entry.title.isEmpty ? entry.host : entry.title,
                            iconURL: history.faviconURL(for: entry)
                        )
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) { history.remove(entry) } label: {
                            Label(localized("刪除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DSFont.title3.weight(.bold))
            .foregroundStyle(DSColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A site on the start page as Safari draws a Favorite: its icon on a white rounded
/// square lifted off the page by a soft shadow — its first letter, white on grey, when it
/// has no icon — and its name under it.
private struct BrowserSiteTile: View {
    let title: String
    let iconURL: URL?

    private var monogram: String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            AsyncImage(url: iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .padding(DSSpacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DSColor.surface)
                } else {
                    Text(monogram)
                        .font(DSFont.title.weight(.semibold))
                        .foregroundStyle(DSColor.browserMonogramForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DSColor.browserMonogramFill)
                }
            }
            .frame(width: DSLayout.browserStartTileIconSide, height: DSLayout.browserStartTileIconSide)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .shadow(color: DSColor.appIconShadow, radius: DSLayout.browserLiftShadowRadius, y: DSLayout.browserLiftShadowY)
            .accessibilityHidden(true)
            Text(title)
                .font(DSFont.caption.weight(.medium))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Safari's 自訂起始頁: which sections the start page shows, the bookmarks themselves,
/// and the history.
private struct BrowserStartCustomizeSheet: View {
    @Binding var showsBookmarks: Bool
    @Binding var showsHistory: Bool

    @ObservedObject private var history = BrowseHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsHistoryClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $showsBookmarks) {
                        SettingsRowLabel(localized("書籤"), systemImage: "book")
                    }
                    Toggle(isOn: $showsHistory) {
                        SettingsRowLabel(localized("最近瀏覽"), systemImage: "clock")
                    }
                }
                .interfaceSectionSurface()
                Section {
                    NavigationLink {
                        BrowserBookmarksEditor()
                    } label: {
                        SettingsRowLabel(localized("編輯書籤"), systemImage: "square.and.pencil")
                    }
                    Button(role: .destructive) { confirmsHistoryClear = true } label: {
                        SettingsRowLabel(localized("清除瀏覽記錄"), systemImage: "trash", role: .destructive)
                    }
                    .disabled(history.entries.isEmpty)
                    .confirmationDialog(
                        localized("要清除所有瀏覽記錄嗎？"),
                        isPresented: $confirmsHistoryClear,
                        titleVisibility: .visible
                    ) {
                        Button(localized("清除"), role: .destructive) { history.clear() }
                        Button(localized("取消"), role: .cancel) {}
                    }
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(localized("自訂起始頁"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .explore)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The bookmarks in the order the start page shows them, reordered and removed in place.
private struct BrowserBookmarksEditor: View {
    @ObservedObject private var store = BrowserBookmarkStore.shared

    var body: some View {
        List {
            ForEach(store.bookmarks) { bookmark in
                BrowserSiteRow(
                    iconURL: bookmark.faviconURL,
                    title: bookmark.title,
                    detail: bookmark.host,
                    trailing: nil
                )
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { offsets in
                offsets.map { store.bookmarks[$0] }.forEach(store.remove)
            }
            .interfaceSectionSurface()
        }
        .environment(\.editMode, .constant(.active))
        .overlay {
            if store.bookmarks.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("尚無書籤"), systemImage: "book")
                }
            }
        }
        .navigationTitle(localized("編輯書籤"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

#Preview("起始頁") {
    NavigationStack {
        BrowserStartPage(onOpen: { _ in }, onTranscode: { _ in })
    }
}

#Preview("書籤") {
    BrowserBookmarksSheet(onOpen: { _ in }, onTranscode: { _ in })
}
