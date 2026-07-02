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
    @State private var showDiscoverSettings = false
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
            .toolbarTitleDisplayModeInlineLarge()
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
            .sheet(isPresented: $showDiscoverSettings) {
                NavigationStack {
                    DiscoverSettingsView(
                        discover: discover,
                        onNavigate: { url in
                            showDiscoverSettings = false
                            onNavigate(url)
                        },
                        onDismiss: { showDiscoverSettings = false }
                    )
                }
                .presentationDetents([.large])
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
                if BookSourceStore.shared.isAudiobook(book) {
                    AudiobookDetailView(book: book).environmentObject(store)
                } else {
                    OnlineBookView(book: book).environmentObject(store)
                }
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

    /// Trailing toolbar menu: configure discover, switch explore source, refresh.
    private var sourceMenu: some View {
        Menu {
            Button { showDiscoverSettings = true } label: {
                Label(localized("發現頁設定"), systemImage: "slider.horizontal.3")
            }
            Divider()
            Button { showDiscoverSourcePicker = true } label: {
                Label(localized("切換發現頁"), systemImage: "books.vertical")
            }
            .disabled(discover.exploreSources.count <= 1)
            Button { discover.reload() } label: {
                Label(localized("換一批"), systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(localized("發現頁設定"))
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
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showHistory = false
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
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
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showSourceSites = false
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
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

// MARK: - Discover Settings

private struct DiscoverSettingsView: View {
    @ObservedObject var discover: DiscoverViewModel
    let onNavigate: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var settingsGroups: [DiscoverSettingsGroup] {
        DiscoverViewModel.discoverSettingsGroups(
            from: discover.rawItems,
            defaultTitle: localized("發現")
        )
    }

    private var filteredGroups: [DiscoverSettingsGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return settingsGroups }
        return settingsGroups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(trimmed) {
                return group
            }
            let items = group.items.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
            }
            guard !items.isEmpty else { return nil }
            return DiscoverSettingsGroup(id: group.id, title: group.title, items: items)
        }
    }

    var body: some View {
        AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    sourceCard
                    if !discover.filters.isEmpty {
                        filtersCard
                    }
                    categoriesCard
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.lg)
            }
            .background(DSColor.groupedBackground)
        }
        .navigationTitle(localized("發現頁設定"))
        .toolbarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("搜尋發現項目")
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onDismiss()
                } label: {
                    Label(localized("完成"), systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(localized("完成"))
            }
        }
    }

    private var sourceCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                sectionTitle(localized("目前發現頁"))
                Menu {
                    ForEach(discover.exploreSources) { source in
                        Button {
                            discover.selectSource(source.id)
                        } label: {
                            if source.id == discover.selectedSourceId {
                                Label(source.bookSourceName, systemImage: "checkmark")
                            } else {
                                Text(source.bookSourceName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: "books.vertical")
                            .foregroundColor(DSColor.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(discover.selectedSource?.bookSourceName ?? localized("尚未啟用支援發現的書源"))
                                .font(DSFont.subheadline.weight(.semibold))
                                .foregroundColor(DSColor.textPrimary)
                                .lineLimit(1)
                            if let url = discover.selectedSource?.bookSourceUrl {
                                Text(url)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: DSSpacing.sm)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(discover.exploreSources.count <= 1)
            }
        }
    }

    private var filtersCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                sectionTitle(localized("篩選條件"))
                VStack(spacing: 0) {
                    ForEach(Array(discover.filters.enumerated()), id: \.offset) { index, filter in
                        filterRow(filter)
                        if index < discover.filters.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private var categoriesCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        sectionTitle(localized("顯示分區"))
                        Text(categorySummary)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Spacer(minLength: DSSpacing.md)
                    Menu {
                        Button {
                            discover.resetCategorySelection()
                        } label: {
                            Label(localized("恢復自動"), systemImage: "arrow.counterclockwise")
                        }
                        .disabled(!discover.usesCustomCategorySelection)
                        Button {
                            discover.selectAllCategories()
                        } label: {
                            Label(localized("全部顯示"), systemImage: "checklist.checked")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .medium))
                    }
                    .accessibilityLabel(localized("顯示分區"))
                }

                if discover.isLoadingItems && discover.rawItems.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, DSSpacing.xl)
                } else if filteredGroups.isEmpty {
                    Text(localized("沒有符合的發現項目"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DSSpacing.xl)
                } else {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        ForEach(filteredGroups) { group in
                            categoryGroup(group)
                        }
                    }
                }
            }
        }
    }

    private var categorySummary: String {
        if discover.usesCustomCategorySelection {
            return String(format: localized("已自訂 %d 個分區"), discover.selectedCategoryCount)
        }
        return String(format: localized("自動顯示前 %d 個分區"), discover.maxShowcaseSections)
    }

    private func filterRow(_ filter: DiscoverFilter) -> some View {
        Menu {
            ForEach(filter.options, id: \.self) { option in
                Button {
                    discover.selectFilter(filter, value: option)
                } label: {
                    if option == filter.selected {
                        Label(displayName(option), systemImage: "checkmark")
                    } else {
                        Text(displayName(option))
                    }
                }
            }
        } label: {
            HStack(spacing: DSSpacing.md) {
                Text(filterTitle(filter.title))
                    .font(DSFont.subheadline)
                    .foregroundColor(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.sm)
                Text(displayName(filter.selected))
                    .font(DSFont.subheadline)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DSFont.caption2)
                    .foregroundColor(DSColor.textSecondary)
            }
            .padding(.vertical, DSSpacing.sm + 2)
            .contentShape(Rectangle())
        }
    }

    private func categoryGroup(_ group: DiscoverSettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(group.title)
                .font(DSFont.caption.weight(.semibold))
                .foregroundColor(DSColor.textSecondary)
                .textCase(.uppercase)
            DiscoverSettingsFlowLayout(spacing: DSSpacing.sm) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    categoryChip(item)
                }
            }
        }
    }

    private func categoryChip(_ item: DiscoverCardItem) -> some View {
        let selected = item.isFetchable && discover.isCategorySelected(item)
        let isAction = item.isAction
        return Button {
            if isAction, let url = item.actionURL {
                onNavigate(url)
            } else {
                discover.toggleCategoryVisibility(item)
            }
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
                if isAction {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(DSFont.caption.weight(selected ? .semibold : .regular))
            .foregroundColor(selected ? DSColor.textOnAccent : DSColor.textPrimary)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(selected ? DSColor.accent : DSColor.surface)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? DSColor.accent.opacity(0.25) : DSColor.separator,
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isAction && item.actionURL == nil)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md, content: content)
            .padding(DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DSFont.headline)
            .foregroundColor(DSColor.textPrimary)
    }

    private func filterTitle(_ title: String) -> String {
        switch title {
        case "线路", "線路":
            return localized("線路")
        case "类型", "類型":
            return localized("類型")
        case "频道", "頻道":
            return localized("頻道")
        case "平台":
            return localized("平台")
        default:
            return title
        }
    }

    private func displayName(_ value: String) -> String {
        guard value.hasPrefix("http") else { return value }
        return value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

/// Left-to-right wrapping layout for source-emitted discover chips.
private struct DiscoverSettingsFlowLayout: Layout {
    var spacing: CGFloat = DSSpacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, origin.x - spacing)
        }
        let width = maxWidth.isFinite ? maxWidth : totalWidth
        return CGSize(width: width, height: origin.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
        .toolbarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("搜尋書源名稱或網址")
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onDismiss()
                } label: {
                    Label(localized("完成"), systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(localized("完成"))
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
