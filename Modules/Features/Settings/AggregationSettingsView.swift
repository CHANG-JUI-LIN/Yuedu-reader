import SwiftUI

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), Emby's aggregation settings
// mapped onto Yuedu's libraries. Pushed from 設定 only, as Emby's sit in its user settings.
// This step: 偏好閱讀語言 and 推薦範圍. 書庫順序, 顯示在最新 and 隱藏已讀 follow (5d-3e–g).

struct AggregationSettingsView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared

    var body: some View {
        let preferences = store.readingLanguages
        List {
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
        .navigationTitle(localized("聚合設定"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
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
