import SwiftUI

/// 資源庫's 官方模組 (AI 推薦 plan 8d): the app's own modules, always listed, above 匯入的模組.
struct OfficialModuleSection: View {
    var body: some View {
        LibrarySection(localized("官方模組")) { layout in
            NavigationLink(value: ExploreNavigationRoute.aiRecommendations) {
                ExploreEntryLabel(title: localized("AI 推薦"), artwork: .symbol("sparkles"), layout: layout,
                                  subtitle: localized("依你最近讀的書推薦作品"))
            }
            .buttonStyle(ExploreTileButtonStyle())
            .accessibilityLabel(localized("AI 推薦"))
            .accessibilityValue(localized("依你最近讀的書推薦作品"))
            .accessibilityIdentifier("library.module.official.aiRecommendations")
        }
    }
}

/// 資源庫's 匯入的模組 (Phase 6e): a card per installed module, as the other groups draw theirs,
/// and a card for each folder that could not be read, which can only be removed. Its 新增模組
/// card depends on the imported modules alone; 官方模組 is `OfficialModuleSection`.
struct RuleModuleSection: View {
    @ObservedObject var library: RuleModuleLibrary
    /// 新增模組 from the empty card: by address, as the most common way in.
    let onAdd: () -> Void
    @State private var pendingRemoval: RuleModuleStore.Failure?
    @State private var removalFailure: String?

    var body: some View {
        // Eager, not lazy: with 官方模組 above it, this section's lazy grid stayed in the
        // accessibility tree as an empty, zero-sized element on the iOS 27 simulator, so
        // VoiceOver never reached 新增模組 (2026-10-15; making 官方模組 eager did not help, and
        // neither did dropping the loading spinner). A reader imports a handful of modules, so
        // laziness bought nothing here. Delete `isLazy: false` once `testOfficialModuleIsListed`
        // passes without it.
        LibrarySection(localized("匯入的模組"), isLazy: false) { layout in
            if !library.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if library.modules.isEmpty && library.failures.isEmpty {
                Button(action: onAdd) {
                    ExploreEntryLabel(title: localized("新增模組"), artwork: .neutral("plus"), layout: layout,
                                      subtitle: localized("還沒有模組"))
                }
                .buttonStyle(ExploreTileButtonStyle())
                .accessibilityLabel(localized("新增模組"))
                .accessibilityValue(localized("還沒有模組"))
                .accessibilityIdentifier("library.modules.add")
            } else {
                ForEach(library.modules, id: \.module.id) { installed in
                    card(installed.module, layout: layout)
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

    private func card(_ module: RuleModule, layout: ExploreEntryLabel.Layout) -> some View {
        let version = String(format: localized("版本 %@"), module.version)
        let author = module.author.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let detail = [version, author].compactMap { $0 }.joined(separator: " · ")
        let description = module.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return NavigationLink(value: ExploreNavigationRoute.module(id: module.id)) {
            ExploreEntryLabel(title: module.title, artwork: .symbol("puzzlepiece.extension"), layout: layout,
                              subtitle: description, detail: detail)
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityLabel(module.title)
        .accessibilityValue([description, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("library.module.\(module.id)")
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

#Preview("No modules") {
    ScrollView {
        RuleModuleSection(library: RuleModulePreviewData.library([]), onAdd: {})
            .padding(DSSpacing.lg)
    }
}

#Preview("Two modules") {
    NavigationStack {
        ScrollView {
            RuleModuleSection(library: RuleModulePreviewData.library(["新書速報", "排行榜"]), onAdd: {})
                .padding(DSSpacing.lg)
        }
    }
}
