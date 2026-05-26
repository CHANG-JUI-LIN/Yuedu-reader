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
    @State private var bookSearchRequest: BookSearchRequest?
    @State private var showSourcePicker = false
    @State private var showSourceManager = false
    @State private var showHistory = false
    @State private var showSourceSites = false
    @State private var openingBook: OnlineBook?

    private var tab: ExploreTab { ExploreTab(rawValue: tabRaw) ?? .discover }
    private var tabBinding: Binding<ExploreTab> {
        Binding(get: { tab }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    segmentedPicker

                    switch tab {
                    case .discover: discoverContent
                    case .web: webContent
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.top, DSSpacing.sm)
                .padding(.bottom, 130)
            }
            .background(DSColor.groupedBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(localized("探索"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜尋書名、作者、網址或關鍵字")
            )
            .onSubmit(of: .search, submitSearch)
            .onAppear { discover.refreshSources() }
            .onChange(of: sourceStore.sources.count) { _, _ in discover.refreshSources() }
            .sheet(isPresented: $showSourcePicker) { sourcePickerSheet }
            .sheet(isPresented: $showSourceManager) {
                NavigationStack { BookSourceListView() }
            }
            .sheet(isPresented: $showHistory) { historySheet }
            .sheet(isPresented: $showSourceSites) { sourceSitesSheet }
            .sheet(item: $openingBook) { book in
                AdaptiveSheetContainer(maxWidth: 900) {
                    OnlineBookView(book: book).environmentObject(store)
                }
            }
            .sheet(item: $bookSearchRequest) { request in
                BookSearchView(initialQuery: request.query).environmentObject(store)
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
            bookSearchRequest = BookSearchRequest(query: trimmed)
        case .web:
            onNavigate(trimmed)
            query = ""
        }
    }

    // MARK: - Discover Segment

    @ViewBuilder
    private var discoverContent: some View {
        if discover.hasExploreSource {
            sourceCard
            discoverSection
            booksSection
        } else {
            emptySourceCard
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("目前書源"))
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)

            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
                Text(discover.selectedSource?.bookSourceName ?? "")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(typeDisplay(discover.selectedType))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DSColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DSColor.accentLight)
                    .clipShape(Capsule())
                Spacer(minLength: 4)
            }

            HStack(spacing: DSSpacing.sm) {
                pillButton(localized("切換書源"), system: "arrow.left.arrow.right") {
                    showSourcePicker = true
                }
                pillButton(localized("書源設定"), system: "gearshape") {
                    showSourceManager = true
                }
            }

            Divider()

            filterRow(localized("類型"), system: "square.grid.2x2",
                      options: discover.typeOptions, selected: discover.selectedType,
                      display: typeDisplay) { discover.setType($0) }
            filterRow(localized("頻道"), system: "person.2",
                      options: discover.channelOptions, selected: discover.selectedChannel,
                      display: channelDisplay) { discover.setChannel($0) }
            filterRow(localized("來源"), system: "circle.grid.2x2",
                      options: discover.platformOptions, selected: discover.selectedPlatform,
                      display: platformDisplay) { discover.setPlatform($0) }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    private var emptySourceCard: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundColor(DSColor.textSecondary.opacity(0.5))
            Text(localized("尚未啟用支援發現的書源"))
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
            Button {
                showSourceManager = true
            } label: {
                Text(localized("前往書源管理"))
                    .font(DSFont.bodyBold)
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.lg).padding(.vertical, 10)
                    .background(DSColor.accent)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.xxl)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                Text(localized("發現")).font(DSFont.headline)
                Spacer()
                Button { discover.reload() } label: {
                    HStack(spacing: 4) {
                        Text(localized("換一批"))
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.accent)
                }
            }

            if discover.isLoadingItems && discover.items.isEmpty {
                loadingRow
            } else if discover.items.isEmpty {
                Text(localized("暫無發現內容"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.lg)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: 3),
                    spacing: DSSpacing.md
                ) {
                    ForEach(discover.items) { item in
                        DiscoverGridCard(item: item) {
                            discover.handleTap(item, onNavigate: onNavigate)
                        }
                    }
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    private var booksSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(discover.booksSectionTitle.isEmpty ? localized("今日必讀") : discover.booksSectionTitle)
                .font(DSFont.headline)

            if discover.isLoadingBooks && discover.books.isEmpty {
                loadingRow
            } else if discover.books.isEmpty {
                Text(localized("選擇上方分類以載入書籍"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(discover.books.enumerated()), id: \.element.id) { index, book in
                        Button { openingBook = book } label: {
                            DiscoverBookRow(book: book)
                        }
                        .buttonStyle(.plain)
                        if index < discover.books.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    // MARK: - Web Segment

    @ViewBuilder
    private var webContent: some View {
        searchEnginesCard
        quickEntryCard
        recentCard
    }

    private var searchEnginesCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("常用搜尋")).font(DSFont.headline)
            HStack(spacing: DSSpacing.xl) {
                ForEach(SearchEngine.allCases) { engine in
                    Button {
                        onNavigate(engine.startURL)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(DSColor.surface).frame(width: 52, height: 52)
                                AsyncImage(url: URL(string: engine.faviconURL)) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFit().frame(width: 28, height: 28)
                                    } else {
                                        Text(engine.icon)
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(engine.color)
                                    }
                                }
                            }
                            Text(engine.rawValue).font(DSFont.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    private var quickEntryCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("快捷入口")).font(DSFont.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: 4),
                spacing: DSSpacing.md
            ) {
                quickEntry(localized("番茄登入"), system: "person.crop.circle.badge.plus", color: .orange) {
                    onNavigate("https://fanqienovel.com/")
                }
                quickEntry(localized("書源網站"), system: "globe", color: .blue) {
                    showSourceSites = true
                }
                quickEntry(localized("最近瀏覽"), system: "clock.arrow.circlepath", color: .green) {
                    showHistory = true
                }
                quickEntry(localized("書源管理"), system: "slider.horizontal.3", color: .purple) {
                    showSourceManager = true
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                Text(localized("最近瀏覽")).font(DSFont.headline)
                Spacer()
                if !history.entries.isEmpty {
                    Button { showHistory = true } label: {
                        HStack(spacing: 2) {
                            Text(localized("查看全部"))
                            Image(systemName: "chevron.right")
                        }
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.accent)
                    }
                }
            }
            if history.entries.isEmpty {
                Text(localized("尚無瀏覽記錄"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.lg)
            } else {
                VStack(spacing: 0) {
                    let recent = Array(history.entries.prefix(5))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        Button { onNavigate(entry.url) } label: {
                            HistoryRow(entry: entry, faviconURL: history.faviconURL(for: entry))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { history.remove(entry) } label: {
                                Label(localized("刪除"), systemImage: "trash")
                            }
                        }
                        if index < recent.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.background)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl))
    }

    // MARK: - Sheets

    private var sourcePickerSheet: some View {
        NavigationStack {
            List(discover.exploreSources) { source in
                Button {
                    discover.selectSource(source.id)
                    showSourcePicker = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.bookSourceName).foregroundColor(DSColor.textPrimary)
                            if !source.bookSourceGroup.isEmpty {
                                Text(source.bookSourceGroup)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if source.id == discover.selectedSourceId {
                            Image(systemName: "checkmark").foregroundColor(DSColor.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(localized("切換書源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { showSourcePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { showSourceSites = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Reusable bits

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, DSSpacing.lg)
    }

    private func pillButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(DSColor.accent)
            .padding(.horizontal, DSSpacing.md).padding(.vertical, 6)
            .overlay(Capsule().stroke(DSColor.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func filterRow(
        _ label: String,
        system: String,
        options: [String],
        selected: String,
        display: @escaping (String) -> String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 12))
                Text(label).font(DSFont.caption)
            }
            .foregroundColor(DSColor.textSecondary)
            .frame(width: 56, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DSSpacing.sm) {
                    ForEach(options, id: \.self) { option in
                        let isOn = option == selected
                        Button { onSelect(option) } label: {
                            Text(display(option))
                                .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                                .foregroundColor(isOn ? .white : DSColor.textPrimary)
                                .padding(.horizontal, DSSpacing.md).padding(.vertical, 6)
                                .background(isOn ? DSColor.accent : DSColor.surface)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func quickEntry(_ title: String, system: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.md)
                        .fill(color.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: system)
                        .font(.system(size: 20))
                        .foregroundColor(color)
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category value → localized display

    private func typeDisplay(_ value: String) -> String {
        switch value {
        case "小说": return localized("小說")
        case "听书": return localized("聽書")
        case "漫画": return localized("漫畫")
        case "短剧": return localized("短劇")
        default: return value
        }
    }

    private func channelDisplay(_ value: String) -> String {
        switch value {
        case "男频": return localized("男頻")
        case "女频": return localized("女頻")
        default: return value
        }
    }

    private func platformDisplay(_ value: String) -> String {
        value == "全部" ? localized("全部") : value
    }
}

// MARK: - Discover Grid Card

private struct DiscoverGridCard: View {
    let item: DiscoverCardItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(style.color.opacity(0.15)).frame(width: 40, height: 40)
                    Image(systemName: style.icon)
                        .font(.system(size: 18))
                        .foregroundColor(style.color)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.md)
            .background(DSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        }
        .buttonStyle(.plain)
    }

    private var style: (icon: String, color: Color) {
        let t = item.title
        if item.isAction { return ("person.crop.circle.badge.plus", .orange) }
        if t.contains("番茄") { return ("books.vertical.fill", .red) }
        if t.contains("推荐") || t.contains("推薦") { return ("star.fill", .yellow) }
        if t.contains("历史") || t.contains("歷史") { return ("clock.fill", .blue) }
        if t.contains("完本") || t.contains("完结") || t.contains("榜") { return ("crown.fill", .green) }
        if t.contains("女") { return ("sparkles", .purple) }
        if t.contains("男") || t.contains("热") || t.contains("熱") { return ("flame.fill", .orange) }
        if t.contains("晴天") { return ("sun.max.fill", .teal) }
        return ("square.grid.2x2.fill", .accentColor)
    }
}

// MARK: - Discover Book Row

private struct DiscoverBookRow: View {
    let book: OnlineBook

    private var statusTag: String {
        book.kind.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            AsyncImage(url: URL(string: book.coverUrl)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .fill(DSColor.surface)
                        .overlay(
                            Text(String(book.name.prefix(1)))
                                .font(DSFont.headline)
                                .foregroundColor(DSColor.textSecondary)
                        )
                }
            }
            .frame(width: 56, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }
                if !book.intro.isEmpty {
                    Text(ReaderHTMLUtilities.displayText(fromHTMLFragment: book.intro))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if !statusTag.isEmpty {
                Text(statusTag)
                    .font(.system(size: 11))
                    .foregroundColor(DSColor.textSecondary)
            }
        }
        .padding(.vertical, DSSpacing.md)
        .contentShape(Rectangle())
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

// MARK: - Book Search Request (sheet item)

private struct BookSearchRequest: Identifiable {
    let id = UUID()
    let query: String
}

#Preview {
    ExploreHomeView(onNavigate: { _ in })
        .environmentObject(BookStore())
}
