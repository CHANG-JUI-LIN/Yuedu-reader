import SwiftUI

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), Emby's aggregation settings
// mapped onto Yuedu's libraries. Pushed from 設定, and from 探索's ••• (decision 36).
// Laid out as Emby's 聚合資料 (search 9d): 數據來源 on top, each purpose with its n/m and its
// checklist, then 中繼資料語言偏好推薦 (a menu, 2026-10-21; 偏好閱讀語言 and 推薦範圍 in 5d-3d),
// 書庫順序 (5d-3e) and 隱藏已讀 (5d-3g).
// The home's sections (5d-3h) left in 9d: they are 編輯首頁's (maintainer, 2026-10-15).

struct AggregationSettingsView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared

    /// The libraries in 書庫順序.
    private var libraries: [LibraryListing] {
        LibraryListing.ordered(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                               order: store.settings.libraryOrder)
    }

    var body: some View {
        let libraries = libraries
        List {
            AggregationDataSourcesSection()
            metadataLanguageSection

            // One library has no order to give (China without a connection saved).
            if libraries.count > 1 {
                Section {
                    ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                        SettingsRowLabel(library.name, systemImage: library.systemImage)
                            .accessibilityValue(String(format: localized("第 %d 個"), index + 1))
                            .accessibilityActions {
                                if index > 0 {
                                    Button(localized("上移")) { moveLibrary(libraries, from: index, to: index - 1) }
                                }
                                if index < libraries.count - 1 {
                                    Button(localized("下移")) { moveLibrary(libraries, from: index, to: index + 2) }
                                }
                            }
                            .accessibilityIdentifier("aggregation.library.\(library.key.type.rawValue).\(library.key.id)")
                    }
                    .onMove { source, destination in
                        var keys = libraries.map(\.key)
                        keys.move(fromOffsets: source, toOffset: destination)
                        store.setLibraryOrder(keys)
                    }
                } header: {
                    Text(localized("書庫順序"))
                } footer: {
                    Text(localized("最新照這個順序；來源配置排在書庫之後，照它們自己的順序。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }

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

    /// 書庫順序's 上移／下移 for VoiceOver, in `onMove`'s offsets.
    private func moveLibrary(_ libraries: [LibraryListing], from index: Int, to destination: Int) {
        var keys = libraries.map(\.key)
        keys.move(fromOffsets: IndexSet(integer: index), toOffset: destination)
        store.setLibraryOrder(keys)
    }
}

#Preview("聚合設定") {
    NavigationStack {
        AggregationSettingsView()
    }
}
