import SwiftUI

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), Emby's aggregation settings
// mapped onto Yuedu's libraries. Pushed from 設定, and from 探索's ••• (decision 36).
// Laid out as Emby 4.10's Home Screen page (decision 36): 偏好閱讀語言 and 推薦範圍 (5d-3d) on
// top, then 書庫順序 (5d-3e), the home's sections (5d-3h), each opening its own options, and
// 隱藏已讀 (5d-3g) at the bottom. 顯示在最新 (5d-3f) is in 最新's own options.

struct AggregationSettingsView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared

    /// The libraries in 書庫順序.
    private var libraries: [LibraryListing] {
        LibraryListing.ordered(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                               order: store.settings.libraryOrder)
    }

    var body: some View {
        let preferences = store.readingLanguages
        let libraries = libraries
        List {
            languageSection(preferences)
            scopeSection(preferences)

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

            homeSections

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

    // MARK: 偏好閱讀語言

    private func languageSection(_ preferences: ReadingLanguagePreferences) -> some View {
        Section {
            ForEach(Array(preferences.languages.enumerated()), id: \.element) { index, code in
                Text(ReadingLanguage.name(of: code))
                    .foregroundStyle(DSColor.textPrimary)
                    .deleteDisabled(preferences.languages.count == 1)
                    .accessibilityValue(String(format: localized("第 %d 優先"), index + 1))
                    .accessibilityActions {
                        if index > 0 {
                            Button(localized("上移")) { move(from: index, to: index - 1) }
                        }
                        if index < preferences.languages.count - 1 {
                            Button(localized("下移")) { move(from: index, to: index + 2) }
                        }
                    }
                    .accessibilityIdentifier("aggregation.language.\(code)")
            }
            .onMove { source, destination in
                var changed = preferences
                changed.languages.move(fromOffsets: source, toOffset: destination)
                store.setReadingLanguages(changed)
            }
            .onDelete { offsets in
                var changed = preferences
                changed.languages.remove(atOffsets: offsets)
                guard !changed.languages.isEmpty else { return }
                store.setReadingLanguages(changed)
            }
            if preferences.languages.count < ReadingLanguage.offered.count {
                NavigationLink {
                    AddReadingLanguageView()
                } label: {
                    SettingsRowLabel(localized("新增語言"), systemImage: "plus")
                }
                .accessibilityIdentifier("aggregation.addLanguage")
            }
        } header: {
            Text(localized("偏好閱讀語言"))
        } footer: {
            Text(localized("排在前面的語言優先推薦。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func scopeSection(_ preferences: ReadingLanguagePreferences) -> some View {
        Section {
            Picker(localized("推薦範圍"), selection: Binding(
                get: { preferences.scope },
                set: { scope in
                    var changed = preferences
                    changed.scope = scope
                    store.setReadingLanguages(changed)
                })) {
                ForEach(ReadingLanguagePreferences.Scope.allCases) { scope in
                    Text(localized(scope.titleKey)).tag(scope)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("aggregation.scope")
        } header: {
            Text(localized("推薦範圍"))
        } footer: {
            Text(localized("沒有標示語言的書（多數來源配置）一律保留，排在偏好語言之後。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    // MARK: 首頁欄目

    /// The home's sections, as Emby lists its Home Sections on the page: each opens its own
    /// options, the page 編輯首頁 pushes; drag to reorder.
    @ViewBuilder
    private var homeSections: some View {
        if let page = pageStore.page {
            let sections = page.editableSections
            Section {
                if let configuration = selectedConfiguration {
                    LabeledContent(localized("首頁配置"), value: configuration.name)
                        .accessibilityIdentifier("aggregation.homeConfiguration")
                }
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    NavigationLink {
                        HomeSectionPage(sectionID: section.id)
                    } label: {
                        // A shown section's row is its name alone: with an empty value,
                        // LabeledContent left the row's own element unlabelled on iOS 27.
                        if section.isEnabled {
                            Text(section.editorTitle())
                                .foregroundStyle(DSColor.textPrimary)
                        } else {
                            LabeledContent(section.editorTitle(), value: localized("已隱藏"))
                                .foregroundStyle(DSColor.textPrimary)
                        }
                    }
                    .accessibilityActions {
                        if index > 0 {
                            Button(localized("上移")) { moveSection(from: index, to: index - 1) }
                        }
                        if index < sections.count - 1 {
                            Button(localized("下移")) { moveSection(from: index, to: index + 2) }
                        }
                    }
                    .accessibilityIdentifier("aggregation.homeSection.\(section.id.uuidString)")
                }
                .onMove { source, destination in
                    pageStore.edit { $0.moveEditable(fromOffsets: source, toOffset: destination) }
                }
            } header: {
                Text(localized("首頁欄目"))
            } footer: {
                Text(localized("和探索的編輯首頁是同一份。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        } else {
            // The home is made the first time 探索 opens (`HomePageStore.pageOrDefaults`), once
            // it knows whether the reader has book sources.
            Section {
            } header: {
                Text(localized("首頁欄目"))
            } footer: {
                Text(localized("打開探索後，首頁欄目會列在這裡。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
    }

    /// The 首頁配置 探索 shows, which these sections are.
    private var selectedConfiguration: HomeConfigurationListing? {
        pageStore.configurations.first { $0.id == pageStore.selectedConfiguration }
    }

    /// 首頁欄目's 上移／下移 for VoiceOver, in `onMove`'s offsets.
    private func moveSection(from index: Int, to destination: Int) {
        pageStore.edit { $0.moveEditable(fromOffsets: IndexSet(integer: index), toOffset: destination) }
    }

    /// 書庫順序's 上移／下移 for VoiceOver, in `onMove`'s offsets.
    private func moveLibrary(_ libraries: [LibraryListing], from index: Int, to destination: Int) {
        var keys = libraries.map(\.key)
        keys.move(fromOffsets: IndexSet(integer: index), toOffset: destination)
        store.setLibraryOrder(keys)
    }

    /// 上移／下移 for VoiceOver, in `onMove`'s offsets.
    private func move(from index: Int, to destination: Int) {
        var changed = store.readingLanguages
        changed.languages.move(fromOffsets: IndexSet(integer: index), toOffset: destination)
        store.setReadingLanguages(changed)
    }
}

/// 新增語言: the offered languages not chosen yet; one tap adds it last and comes back.
private struct AddReadingLanguageView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chosen = store.readingLanguages.languages
        List {
            Section {
                ForEach(ReadingLanguage.offered.filter { !chosen.contains($0) }, id: \.self) { code in
                    Button {
                        var changed = store.readingLanguages
                        changed.languages.append(code)
                        store.setReadingLanguages(changed)
                        dismiss()
                    } label: {
                        Text(ReadingLanguage.name(of: code))
                            .foregroundStyle(DSColor.textPrimary)
                    }
                    .accessibilityIdentifier("aggregation.offer.\(code)")
                }
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("新增語言"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

#Preview("聚合設定") {
    NavigationStack {
        AggregationSettingsView()
    }
}
