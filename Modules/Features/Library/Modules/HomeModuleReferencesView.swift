import SwiftUI

/// 模組's 首頁欄目引用 (M6): home sections drawing from a module no longer installed, which show
/// nothing until the module is back. Each can be removed from its 首頁配置 here.
struct HomeModuleReferencesView: View {
    @ObservedObject var library: RuleModuleLibrary
    @ObservedObject var home: HomePageStore
    @State private var confirmsRemovingAll = false

    init(library: RuleModuleLibrary? = nil, home: HomePageStore? = nil) {
        self.library = library ?? .shared
        self.home = home ?? .shared
    }

    private var references: [HomeModuleReference] {
        home.home?.moduleReferences(installed: Set(library.installed.map(\.module.id))) ?? []
    }

    var body: some View {
        let references = references
        Group {
            if !library.isLoaded {
                ProgressView()
            } else if references.isEmpty {
                ContentUnavailableView(localized("沒有引用未安裝模組的欄目"), systemImage: "rectangle.stack")
            } else {
                Form {
                    Section {
                        ForEach(references) { reference in
                            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                                Text(reference.section.editorTitle())
                                    .foregroundStyle(DSColor.textPrimary)
                                Text(String(format: localized("首頁配置：%1$@ · 模組：%2$@"), reference.configuration.name,
                                            reference.moduleID))
                                    .font(DSFont.footnote)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions {
                                Button(localized("移除"), role: .destructive) { home.removeSections([reference.id]) }
                            }
                            .accessibilityAction(named: localized("移除")) { home.removeSections([reference.id]) }
                        }
                    } footer: {
                        Text(localized("這些欄目的模組已移除，首頁不會顯示它們；重新安裝模組後會再出現。")).dsSectionFooter()
                    }
                    .interfaceSectionSurface()

                    Section {
                        Button(role: .destructive) {
                            confirmsRemovingAll = true
                        } label: {
                            SettingsRowLabel(localized("全部移除"), systemImage: "trash", role: .destructive)
                        }
                        .accessibilityIdentifier("modules.homeReferences.removeAll")
                    }
                    .interfaceSectionSurface()
                }
                .softScrollEdges()
            }
        }
        .navigationTitle(localized("首頁欄目引用"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .hidesRootTabBar()
        .task { await library.loadIfNeeded() }
        .confirmationDialog(String(format: localized("移除 %d 個欄目？"), references.count), isPresented: $confirmsRemovingAll,
                            titleVisibility: .visible) {
            Button(localized("全部移除"), role: .destructive) { home.removeSections(Set(references.map(\.id))) }
            Button(localized("取消"), role: .cancel) {}
        }
    }
}

#Preview("首頁欄目引用") {
    NavigationStack {
        HomeModuleReferencesView(library: RuleModulePreviewData.library([]))
    }
}
