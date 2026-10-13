import SwiftUI

/// 顯示設定, pushed from 發現頁設定 (Phase 5 plan, decision 31): how a source's discover page
/// lays out its categories, which ones are charts, how many books each shows and how far ahead
/// it loads. 5d-1b deleted them with 探索設定; they are back under the same keys, the same for
/// every source's page for now.
struct DiscoverDisplaySettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ExploreSettings.sourcePageLayoutKey)
    private var sourcePageLayout = ExploreSourcePageLayout.default
    @AppStorage(ExploreSettings.rankedKeywordsKey)
    private var rankedKeywordsRaw = ExploreSettings.encodeKeywords(ExploreSettings.defaultRankedKeywords)
    @AppStorage(ExploreSettings.chartBookCountKey)
    private var chartBookCount = ExploreSettings.defaultChartBookCount
    @AppStorage(ExploreSettings.shelfBookCountKey)
    private var shelfBookCount = ExploreSettings.defaultShelfBookCount
    @AppStorage(ExploreSettings.preloadCountKey)
    private var preloadCount = ExploreSettings.defaultPreloadCount
    @State private var newKeyword = ""

    private var rankedKeywords: [String] {
        ExploreSettings.decodeKeywords(rankedKeywordsRaw)
    }

    var body: some View {
        Form {
            layoutSection
            // How the charts and shelves fill and load matters only to the magazine layout.
            if sourcePageLayout == .magazine {
                keywordsSection
                restoreKeywordsSection
                bookCountSection
                preloadSection
            }
        }
        .animation(reduceMotion ? nil : DSAnimation.standard, value: sourcePageLayout)
        .softScrollEdges()
        .themedAppSurface(for: .explore)
        .navigationTitle(localized("顯示設定"))
        .toolbarTitleDisplayMode(.inline)
    }

    private var layoutSection: some View {
        Section {
            Picker(selection: $sourcePageLayout) {
                ForEach(ExploreSourcePageLayout.allCases) { layout in
                    Label(localized(layout.titleKey), systemImage: layout.systemImage)
                        .tag(layout)
                }
            } label: {
                SettingsRowLabel(localized("佈局"), systemImage: "rectangle.split.2x1")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("discover.display.layout")
        } footer: {
            Text(localized("列表是上方一排分類、下方所選分類的書；雜誌是每個分類一排書架或一欄榜單。這頁的設定套用到每個來源配置的發現頁。"))
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
            Text(localized("豎排榜單關鍵詞"))
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
                SettingsRowLabel(localized("恢復預設關鍵詞"), systemImage: "arrow.counterclockwise", role: .action)
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
            Text(localized("榜單展示數量"))
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
            Text(localized("預加載"))
        } footer: {
            Text(localized("捲到某個分類時，順便排隊載入後面幾個分類。數字越大越少看到載入中，但排隊的來源配置請求也越多。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
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
    NavigationStack {
        DiscoverDisplaySettingsView()
    }
}
