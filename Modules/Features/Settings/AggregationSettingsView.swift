import SwiftUI

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), Emby's aggregation settings
// mapped onto Yuedu's libraries. Pushed from 設定, and from 探索's ••• (decision 36).
// Laid out as Emby's 聚合資料 (search 9d): 數據來源 on top, each purpose with its n/m and its
// checklist, then 中繼資料語言偏好推薦 (a menu, 2026-10-21; 偏好閱讀語言 and 推薦範圍 in 5d-3d)
// and 隱藏已讀 (5d-3g). 書庫順序 (5d-3e) went on 2026-10-25 (maintainer: not needed).
// The home's sections (5d-3h) left in 9d: they are 編輯首頁's (maintainer, 2026-10-15).

struct AggregationSettingsView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared

    var body: some View {
        List {
            AggregationDataSourcesSection()
            metadataLanguageSection

            Section {
                Toggle(localized("隱藏已讀"), isOn: Binding(get: { store.hidesRead }, set: { store.setHidesRead($0) }))
                    .accessibilityIdentifier("aggregation.hideRead")
            } footer: {
                Text(localized("讀到最後或標記為已讀完的書，任何一份都算。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("聚合設定"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    // MARK: 中繼資料語言偏好推薦

    /// One language at a time, from a menu; 跟隨 App 語言 until the reader picks another.
    private var metadataLanguageSection: some View {
        Section {
            Picker(localized("中繼資料語言偏好推薦"), selection: Binding(
                get: { store.metadataLanguageChoice },
                set: { store.setMetadataLanguage($0) })) {
                ForEach(MetadataLanguage.choices, id: \.self) { choice in
                    Text(MetadataLanguage.name(of: choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("aggregation.metadataLanguage")
        } footer: {
            Text(localized("這個語言的書排在前面，其次是沒有標示語言的書（多數來源配置），其他語言的書排在最後。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }
}

#Preview("聚合設定") {
    NavigationStack {
        AggregationSettingsView()
    }
}
