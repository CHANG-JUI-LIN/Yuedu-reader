import SwiftUI

/// 資源庫's 模組, first on the page: the app's own modules, then the ones the reader imported, in
/// one group (maintainer 2026-10-26: 「官方模組跟匯入的模組匯合在一起，然後就叫模組」). In order:
/// the app's own (`AppOfficialModule`: AI 推薦, 古騰堡 and 青空文庫), the bundled module files, then
/// each imported module and each folder that could not be read, which can only be removed.
/// 新增模組 is 設定's (模組's toolbar; maintainer 2026-10-27: 資源庫 lists, 設定 adds).
struct RuleModuleSection<Libraries: View>: View {
    @ObservedObject var library: RuleModuleLibrary
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    /// 古騰堡's and 青空文庫's cards, which show what their catalogs hold.
    private let libraries: (SourceInstanceKey, ExploreEntryLabel.Layout) -> Libraries
    @State private var pendingRemoval: RuleModuleStore.Failure?
    @State private var removalFailure: String?

    init(library: RuleModuleLibrary? = nil,
         @ViewBuilder libraries: @escaping (SourceInstanceKey, ExploreEntryLabel.Layout) -> Libraries) {
        self.library = library ?? .shared
        self.libraries = libraries
    }

    var body: some View {
        // Eager, not lazy: when the imported modules were a section of their own below 官方模組,
        // its lazy grid stayed in the accessibility tree as an empty, zero-sized element on the
        // iOS 27 simulator, so VoiceOver never reached 新增模組 (2026-10-15). A reader has a
        // handful of modules, so laziness buys nothing here.
        // 在資源庫中展示 and 停用 (M6) leave a module's card out; 設定's 模組 still lists it.
        let official = library.official.filter { library.isShownInLibrary($0.module.id) }
        let imported = library.imported.filter { library.isShownInLibrary($0.module.id) }
        LibrarySection(localized("模組"), isLazy: false) { layout in
            ForEach(AppOfficialModule.available(librariesAvailable: availability.isAvailable)) { module in
                switch module {
                case .aiRecommendations:
                    NavigationLink(value: module.route) {
                        ExploreEntryLabel(title: module.title, artwork: .symbol("sparkles"), layout: layout,
                                          subtitle: module.summary)
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityLabel(module.title)
                    .accessibilityValue(module.summary)
                    .accessibilityIdentifier("library.module.official.aiRecommendations")
                case .library(let key):
                    libraries(key, layout)
                }
            }
            if !library.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(official + imported, id: \.module.id) { installed in
                    RuleModuleCard(module: installed.module, layout: layout)
                }
                ForEach(library.failures, id: \.folder) { failure in
                    Button {
                        pendingRemoval = failure
                    } label: {
                        ExploreEntryLabel(title: failure.folder, artwork: .neutral("exclamationmark.triangle"), layout: layout,
                                          subtitle: localized("無法讀取的模組"), detail: localized("檔案損毀，或需要較新版本的閱讀。"))
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityLabel(failure.folder)
                    .accessibilityValue(localized("無法讀取的模組"))
                    .accessibilityHint(localized("移除模組"))
                    .accessibilityIdentifier("library.module.failed.\(failure.folder)")
                }
            }
        }
        .confirmationDialog(pendingRemoval.map { String(format: localized("移除「%@」？"), $0.folder) } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { failure in
            Button(localized("移除模組"), role: .destructive) {
                Task { await remove(failure.folder) }
            }
            Button(localized("取消"), role: .cancel) {}
        } message: { _ in
            Text(localized("它的快取會一起刪除。"))
        }
        .alert(localized("操作失敗"), isPresented: Binding(get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } })) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(removalFailure ?? "")
        }
    }

    private func remove(_ folder: String) async {
        do {
            try await library.remove(id: folder)
        } catch {
            AppLogger.error("Module not removed", error: error, context: ["module": folder], level: .error)
            removalFailure = (error as? RuleModuleStoreError)?.message ?? error.localizedDescription
        }
    }
}

extension RuleModuleSection where Libraries == EmptyView {
    init(library: RuleModuleLibrary? = nil) {
        self.init(library: library) { _, _ in EmptyView() }
    }
}

/// A module's card in 資源庫: its title, description, version and author; opens its page.
struct RuleModuleCard: View {
    let module: RuleModule
    let layout: ExploreEntryLabel.Layout

    var body: some View {
        let version = String(format: localized("版本 %@"), module.version)
        let author = module.author.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let detail = [version, author].compactMap { $0 }.joined(separator: " · ")
        let description = module.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        NavigationLink(value: ExploreNavigationRoute.module(id: module.id)) {
            ExploreEntryLabel(title: module.title, artwork: .symbol("puzzlepiece.extension"), layout: layout,
                              subtitle: description, detail: detail)
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityLabel(module.title)
        .accessibilityValue([description, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("library.module.\(module.id)")
    }
}

#Preview("Official only") {
    NavigationStack {
        ScrollView {
            RuleModuleSection(library: RuleModulePreviewData.officialLibrary())
                .padding(DSSpacing.lg)
        }
    }
}

#Preview("Two imported") {
    NavigationStack {
        ScrollView {
            RuleModuleSection(library: RuleModulePreviewData.library(["新書速報", "排行榜"]))
                .padding(DSSpacing.lg)
        }
    }
}
