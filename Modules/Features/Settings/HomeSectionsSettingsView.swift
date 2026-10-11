import SwiftUI

// Unified library 5d-3h: 聚合設定 → 首頁欄目 (Phase 5 plan, decision 21), Emby's home screen
// sections. The same sections and the same edits as 探索's 編輯首頁: the saved home
// (`HomePageStore`), `moveEditable` to reorder, and each section's own page
// (`HomeSectionPage`: 在首頁顯示, 刪除). No second copy of the home.

struct HomeSectionsSettingsView: View {
    @ObservedObject private var pageStore = HomePageStore.shared

    var body: some View {
        Group {
            if let page = pageStore.page {
                let sections = page.editableSections
                List {
                    Section {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            NavigationLink {
                                HomeSectionPage(sectionID: section.id)
                            } label: {
                                LabeledContent(section.editorTitle(), value: section.isEnabled ? "" : localized("已隱藏"))
                                    .foregroundStyle(DSColor.textPrimary)
                            }
                            .accessibilityActions {
                                if index > 0 {
                                    Button(localized("上移")) { move(from: index, to: index - 1) }
                                }
                                if index < sections.count - 1 {
                                    Button(localized("下移")) { move(from: index, to: index + 2) }
                                }
                            }
                            .accessibilityIdentifier("aggregation.homeSection.\(section.id.uuidString)")
                        }
                        .onMove { source, destination in
                            pageStore.edit { $0.moveEditable(fromOffsets: source, toOffset: destination) }
                        }
                    } footer: {
                        Text(localized("和探索的編輯首頁是同一份。"))
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()
                }
            } else {
                // The home is made the first time 探索 opens (`HomePageStore.pageOrDefaults`),
                // once it knows whether the reader has book sources.
                ContentUnavailableView(localized("首頁欄目"), systemImage: "rectangle.stack",
                                       description: Text(localized("打開探索後，首頁欄目會列在這裡。")))
            }
        }
        .navigationTitle(localized("首頁欄目"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    /// 上移／下移 for VoiceOver, in `onMove`'s offsets.
    private func move(from index: Int, to destination: Int) {
        pageStore.edit { $0.moveEditable(fromOffsets: IndexSet(integer: index), toOffset: destination) }
    }
}

#Preview("首頁欄目") {
    NavigationStack {
        HomeSectionsSettingsView()
    }
}
