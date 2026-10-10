import SwiftUI

/// 探索設定, behind 探索's gear: how 探索 lays out its entries, how a source's page lays
/// out its categories, the page 探索 opens straight onto, and how the charts and shelves
/// fill and load.
struct ExploreSettingsSheet: View {
    /// 探索's sources, for 首屏配置 to choose from.
    let sources: [BookSource]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey)
    private var gridColumnCount = ExploreGridDensity.default.rawValue
    @AppStorage(ExploreSettings.sourcePageLayoutKey)
    private var sourcePageLayout = ExploreSourcePageLayout.default
    @AppStorage(ExploreSettings.landingKey) private var landing = ExploreLanding.off.rawValue
    @AppStorage(ExploreSettings.rankedKeywordsKey)
    private var rankedKeywordsRaw = ExploreSettings.encodeKeywords(ExploreSettings.defaultRankedKeywords)
    @AppStorage(ExploreSettings.chartBookCountKey)
    private var chartBookCount = ExploreSettings.defaultChartBookCount
    @AppStorage(ExploreSettings.shelfBookCountKey)
    private var shelfBookCount = ExploreSettings.defaultShelfBookCount
    @AppStorage(ExploreSettings.preloadCountKey)
    private var preloadCount = ExploreSettings.defaultPreloadCount
    @AppStorage(BookCoverLoader.downloadLimitKey) private var coverDownloadLimit = 0
    @ObservedObject private var pageStore = CustomExplorePageStore.shared
    @State private var newKeyword = ""

    private var rankedKeywords: [String] {
        ExploreSettings.decodeKeywords(rankedKeywordsRaw)
    }

    var body: some View {
        NavigationStack {
            Form {
                exploreSection
                layoutSection
                landingSection
                // How the charts and shelves fill and load matters only to the magazine
                // layout; the cover limit applies to every cover in the app.
                if sourcePageLayout == .magazine {
                    keywordsSection
                    restoreKeywordsSection
                    bookCountSection
                    preloadSection
                }
                coverSection
            }
            .animation(reduceMotion ? nil : DSAnimation.standard, value: sourcePageLayout)
            .navigationTitle(localized("探索設定"))
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
    }

    // MARK: Sections

    private var exploreSection: some View {
        Section {
            Toggle(isOn: $showsGrid) {
                SettingsRowLabel(localized("格狀"), systemImage: "square.grid.2x2")
            }
            Picker(selection: $gridColumnCount) {
                ForEach(ExploreGridDensity.allCases) { density in
                    Text(String(format: localized("%d 欄"), density.rawValue))
                        .tag(density.rawValue)
                }
            } label: {
                SettingsRowLabel(localized("每列欄數"), systemImage: "rectangle.split.3x1")
            }
            .pickerStyle(.menu)
            .disabled(!showsGrid)
        } header: {
            sectionHeader(localized("探索頁"))
        }
        .interfaceSectionSurface()
    }

    private var layoutSection: some View {
        Section {
            Picker(selection: $sourcePageLayout) {
                ForEach(ExploreSourcePageLayout.allCases) { layout in
                    Label(localized(layout.titleKey), systemImage: layout.systemImage)
                        .tag(layout)
                }
            } label: {
                SettingsRowLabel(localized("來源配置頁佈局"), systemImage: "rectangle.split.2x1")
            }
            .pickerStyle(.menu)
        } header: {
            sectionHeader(localized("佈局"))
        } footer: {
            Text(localized("列表是上方一排分類、下方所選分類的書；雜誌是每個分類一排書架或一欄榜單。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var landingSection: some View {
        Section {
            Picker(selection: $landing) {
                Text(localized("不啟用")).tag(ExploreLanding.off.rawValue)
                if !pageStore.pages.isEmpty {
                    Section(localized("自訂頁")) {
                        ForEach(pageStore.pages) { page in
                            Text(page.name)
                                .tag(ExploreLanding.customPage(id: page.id).rawValue)
                        }
                    }
                }
                if !sources.isEmpty {
                    Section(localized("來源配置")) {
                        ForEach(sources) { source in
                            Text(source.bookSourceName)
                                .tag(ExploreLanding.source(url: source.bookSourceUrl).rawValue)
                        }
                    }
                }
            } label: {
                SettingsRowLabel(localized("首屏頁面"), systemImage: "arrow.right.circle")
            }
            .pickerStyle(.navigationLink)
        } header: {
            sectionHeader(localized("首屏頁面"))
        } footer: {
            Text(localized("設定後，打開探索時會直接進入這一頁。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var keywordsSection: some View {
        Section {
            ForEach(rankedKeywords, id: \.self) { keyword in
                SettingsRowLabel(keyword, systemImage: "number")
            }
            .onDelete { offsets in
                var keywords = rankedKeywords
                keywords.remove(atOffsets: offsets)
                rankedKeywordsRaw = ExploreSettings.encodeKeywords(keywords)
            }
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
                TextField(localized("新增關鍵詞"), text: $newKeyword)
                    .submitLabel(.done)
                    .onSubmit(addKeyword)
            }
        } header: {
            sectionHeader(localized("豎排榜單關鍵詞"))
        } footer: {
            Text(localized("標題含任一關鍵詞的分類用豎排序號，其餘用橫滑封面。左滑可刪除。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var restoreKeywordsSection: some View {
        Section {
            Button {
                rankedKeywordsRaw = ExploreSettings.encodeKeywords(ExploreSettings.defaultRankedKeywords)
            } label: {
                SettingsRowLabel(
                    localized("恢復預設關鍵詞"),
                    systemImage: "arrow.counterclockwise",
                    role: .action
                )
            }
            .disabled(rankedKeywords == ExploreSettings.defaultRankedKeywords)
        }
        .interfaceSectionSurface()
    }

    private var bookCountSection: some View {
        Section {
            Picker(selection: $chartBookCount) {
                ForEach(ExploreSettings.chartBookCountOptions, id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            } label: {
                SettingsRowLabel(localized("豎排展示數"), systemImage: "list.number")
            }
            .pickerStyle(.menu)
            Picker(selection: $shelfBookCount) {
                ForEach(ExploreSettings.shelfBookCountOptions, id: \.self) { count in
                    Text(count == 0 ? localized("全部") : count.formatted()).tag(count)
                }
            } label: {
                SettingsRowLabel(localized("橫滑展示數"), systemImage: "rectangle.split.3x1")
            }
            .pickerStyle(.menu)
        } header: {
            sectionHeader(localized("榜單展示數量"))
        }
        .interfaceSectionSurface()
    }

    private var preloadSection: some View {
        Section {
            Picker(selection: $preloadCount) {
                ForEach(ExploreSettings.preloadCountOptions, id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            } label: {
                SettingsRowLabel(localized("預加載數量"), systemImage: "arrow.down.circle")
            }
            .pickerStyle(.menu)
        } header: {
            sectionHeader(localized("預加載"))
        } footer: {
            Text(localized("捲到某個分類時，順便排隊載入後面幾個分類。數字越大越少看到載入中，但排隊的來源配置請求也越多。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var coverSection: some View {
        Section {
            Picker(selection: $coverDownloadLimit) {
                ForEach(ExploreSettings.coverDownloadLimitOptions, id: \.self) { limit in
                    Text(limit == 0 ? localized("不限制") : limit.formatted()).tag(limit)
                }
            } label: {
                SettingsRowLabel(localized("封面並發數"), systemImage: "arrow.triangle.2.circlepath")
            }
            .pickerStyle(.menu)
        } header: {
            sectionHeader(localized("封面並發"))
        } footer: {
            Text(localized("同時下載的封面上限，書架和書籍詳情的封面也算在內。數字越低捲動時越不容易發熱，但封面出現得慢一些。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(DSColor.textSecondary)
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        newKeyword = ""
        guard !keyword.isEmpty,
              !rankedKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame })
        else { return }
        rankedKeywordsRaw = ExploreSettings.encodeKeywords(rankedKeywords + [keyword])
    }
}

#Preview {
    ExploreSettingsSheet(sources: [])
}
