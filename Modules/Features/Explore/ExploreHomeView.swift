import SwiftUI

// MARK: - Explore Tabs

enum ExploreTab: String, CaseIterable, Identifiable {
    case discover
    case web
    var id: String { rawValue }
}

// MARK: - Explore Home

/// The landing screen of the 探索 (Explore) tab. Hosts two segments — 書源發現
/// (book-source discover) and 網頁瀏覽 (web browse) — switched by a native
/// segmented `Picker`. Shown by `BrowserView` when no web page is in front.
struct ExploreHomeView: View {
    @EnvironmentObject private var store: BookStore
    @StateObject private var discover = DiscoverViewModel()
    @ObservedObject private var history = BrowseHistoryStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared

    /// Loads a URL or search keyword in the web browser and dismisses this home.
    var onNavigate: (String) -> Void

    @AppStorage("exploreSelectedTab") private var tabRaw = ExploreTab.discover.rawValue

    @State private var query = ""
    @State private var bookSearchRoute: BookSearchRoute?
    @State private var showSourceManager = false
    @State private var showDiscoverSourcePicker = false
    @State private var showHistory = false
    @State private var showSourceSites = false
    @State private var openingBook: OnlineBook?

    private var tab: ExploreTab { ExploreTab(rawValue: tabRaw) ?? .discover }
    private var tabBinding: Binding<ExploreTab> {
        Binding(get: { tab }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentedPicker
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.sm)

                switch tab {
                case .discover: discoverContent
                case .web: webForm
                }
            }
            .background(DSColor.groupedBackground.ignoresSafeArea())
            .navigationTitle(localized("探索"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if tab == .discover, discover.hasExploreSource {
                    ToolbarItem(placement: .topBarTrailing) { sourceMenu }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜尋書名、作者、網址或關鍵字")
            )
            .onSubmit(of: .search, submitSearch)
            .onAppear { discover.refreshSources() }
            .onChange(of: sourceStore.sources.count) { _, _ in discover.refreshSources() }
            .navigationDestination(item: $bookSearchRoute) { route in
                SearchView(initialQuery: route.query)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showSourceManager) {
                // BookSourceListView already provides its own NavigationStack; wrapping
                // it in another NavigationStack stacks two nav bars (duplicate title on
                // iOS 18). Present it directly, matching SettingsView.
                BookSourceListView()
            }
            .sheet(isPresented: $showDiscoverSourcePicker) {
                NavigationStack {
                    DiscoverSourcePickerView(
                        sources: discover.exploreSources,
                        selectedSourceId: discover.selectedSourceId,
                        onSelect: { source in
                            discover.selectSource(source.id)
                            showDiscoverSourcePicker = false
                        },
                        onDismiss: { showDiscoverSourcePicker = false }
                    )
                }
            }
            .sheet(isPresented: $showHistory) { historySheet }
            .sheet(isPresented: $showSourceSites) { sourceSitesSheet }
            .navigationDestination(item: $openingBook) { book in
                OnlineBookView(book: book).environmentObject(store)
            }
        }
    }

    private var segmentedPicker: some View {
        Picker("", selection: tabBinding) {
            Text(localized("書源發現")).tag(ExploreTab.discover)
            Text(localized("網頁瀏覽")).tag(ExploreTab.web)
        }
        .pickerStyle(.segmented)
    }

    private func submitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch tab {
        case .discover:
            bookSearchRoute = BookSearchRoute(query: trimmed)
            query = ""
        case .web:
            onNavigate(trimmed)
            query = ""
        }
    }

    // MARK: - Discover Segment

    @ViewBuilder
    private var discoverContent: some View {
        if discover.hasExploreSource {
            DiscoverShowcaseView(discover: discover, onOpenBook: { openingBook = $0 })
        } else {
            emptySourceState
        }
    }

    /// Trailing toolbar menu: switch explore source, refresh, open source settings.
    private var sourceMenu: some View {
        Menu {
            Button { showDiscoverSourcePicker = true } label: {
                Label(localized("切換發現頁"), systemImage: "books.vertical")
            }
            .disabled(discover.exploreSources.count <= 1)
            Button { discover.reload() } label: {
                Label(localized("換一批"), systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button { showSourceManager = true } label: {
                Label(localized("書源設定"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(localized("書源設定"))
    }

    private var emptySourceState: some View {
        ContentUnavailableView {
            Label(localized("尚未啟用支援發現的書源"), systemImage: "books.vertical")
        } description: {
            Text(localized("前往書源管理新增並啟用書源"))
        } actions: {
            Button(localized("前往書源管理")) { showSourceManager = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Web Segment

    private var webForm: some View {
        Form {
            searchEnginesSection
            quickEntrySection
            recentSection
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchEnginesSection: some View {
        Section(header: Text(localized("常用搜尋"))) {
            HStack(spacing: DSSpacing.xl) {
                ForEach(SearchEngine.allCases) { engine in
                    searchEngineButton(engine)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DSSpacing.sm)
        }
    }

    private var quickEntrySection: some View {
        Section(header: Text(localized("快捷入口"))) {
            DSSettingsRow(
                icon: "person.crop.circle.badge.plus",
                title: localized("番茄登入"),
                action: { onNavigate("https://fanqienovel.com/") }
            )
            DSSettingsRow(
                icon: "globe",
                title: localized("書源網站"),
                action: { showSourceSites = true }
            )
            DSSettingsRow(
                icon: "clock.arrow.circlepath",
                title: localized("最近瀏覽"),
                action: { showHistory = true }
            )
            DSSettingsRow(
                icon: "slider.horizontal.3",
                title: localized("書源管理"),
                action: { showSourceManager = true }
            )
        }
    }

    private var recentSection: some View {
        Section(header: recentSectionHeader) {
            if history.entries.isEmpty {
                Text(localized("尚無瀏覽記錄"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.lg)
            } else {
                let recent = Array(history.entries.prefix(5))
                ForEach(recent) { entry in
                    Button { onNavigate(entry.url) } label: {
                        HistoryRow(entry: entry, faviconURL: history.faviconURL(for: entry))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { history.remove(entry) } label: {
                            Label(localized("刪除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var recentSectionHeader: some View {
        HStack {
            Text(localized("最近瀏覽"))
            Spacer()
            if !history.entries.isEmpty {
                Button { showHistory = true } label: {
                    HStack(spacing: 2) {
                        Text(localized("查看全部"))
                        Image(systemName: "chevron.right")
                    }
                    .font(DSFont.caption)
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Sheets

    private var historySheet: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    ContentUnavailableView(
                        localized("尚無瀏覽記錄"),
                        systemImage: "clock",
                        description: Text(localized("瀏覽過的網頁會出現在這裡"))
                    )
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            Button {
                                onNavigate(entry.url)
                                showHistory = false
                            } label: {
                                HistoryRow(entry: entry, faviconURL: history.faviconURL(for: entry))
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { history.entries[$0] }.forEach(history.remove)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(localized("最近瀏覽"))
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("完成")) { showHistory = false }
                }
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(localized("清除")) { history.clear() }
                            .foregroundColor(DSColor.destructive)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceSitesSheet: some View {
        NavigationStack {
            List(sourceStore.enabledSources) { source in
                Button {
                    onNavigate(source.bookSourceUrl)
                    showSourceSites = false
                } label: {
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: "globe")
                            .foregroundColor(DSColor.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.bookSourceName)
                                .foregroundColor(DSColor.textPrimary)
                                .lineLimit(1)
                            Text(source.bookSourceUrl)
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(localized("書源網站"))
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { showSourceSites = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Reusable bits

    private func searchEngineButton(_ engine: SearchEngine) -> some View {
        Button {
            onNavigate(engine.startURL)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(DSColor.surface)
                        .frame(width: 52, height: 52)
                    AsyncImage(url: URL(string: engine.faviconURL)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().frame(width: 28, height: 28)
                        } else {
                            Text(engine.icon)
                                .font(.headline.weight(.bold))
                                .foregroundColor(engine.color)
                        }
                    }
                }
                Text(engine.rawValue)
                    .font(DSFont.caption)
            }
            .frame(minWidth: 60)
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Discover Source Picker

private struct DiscoverSourcePickerView: View {
    let sources: [BookSource]
    let selectedSourceId: UUID?
    let onSelect: (BookSource) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filteredSources: [BookSource] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sources }
        return sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(trimmed)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            ForEach(filteredSources) { source in
                Button {
                    onSelect(source)
                } label: {
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: "books.vertical")
                            .foregroundColor(DSColor.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.bookSourceName)
                                .foregroundColor(DSColor.textPrimary)
                                .lineLimit(1)
                            Text(source.bookSourceUrl)
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: DSSpacing.sm)
                        if source.id == selectedSourceId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(DSColor.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if filteredSources.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(localized("切換發現頁"))
        .toolbarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("搜尋書源名稱或網址")
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("完成")) { onDismiss() }
            }
        }
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: BrowseHistoryEntry
    let faviconURL: URL?

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            AsyncImage(url: faviconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "globe").foregroundColor(DSColor.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 15))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
                Text(entry.host)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Self.relativeTime(entry.date))
                .font(.system(size: 11))
                .foregroundColor(DSColor.textSecondary)
        }
        .padding(.vertical, DSSpacing.sm)
        .contentShape(Rectangle())
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return localized("剛剛") }
        if seconds < 3600 { return "\(seconds / 60) " + localized("分鐘前") }
        if seconds < 86400 { return "\(seconds / 3600) " + localized("小時前") }
        if seconds < 86400 * 7 { return "\(seconds / 86400) " + localized("天前") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

// MARK: - Book Search Route

private struct BookSearchRoute: Identifiable, Hashable {
    let id = UUID()
    let query: String
}

#Preview {
    ExploreHomeView(onNavigate: { _ in })
        .environmentObject(BookStore())
}
