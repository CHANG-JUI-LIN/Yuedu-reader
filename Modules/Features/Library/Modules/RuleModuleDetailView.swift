import SwiftUI

/// A module's page (Phase 6e), pushed from 資源庫: what it lists, the sites it sends requests to,
/// where it came from with 檢查更新, and 移除模組.
struct RuleModuleDetailView: View {
    let moduleID: String
    @ObservedObject var library: RuleModuleLibrary
    @StateObject private var updates: RuleModuleImportModel
    @State private var showsUpdate = false
    @State private var confirmsRemoval = false
    @State private var removalFailure: String?
    @Environment(\.dismiss) private var dismiss

    init(moduleID: String, library: RuleModuleLibrary? = nil) {
        let library = library ?? .shared
        self.moduleID = moduleID
        self.library = library
        _updates = StateObject(wrappedValue: RuleModuleImportModel(library: library))
    }

    var body: some View {
        Group {
            if let installed = library.module(id: moduleID) {
                page(installed)
            } else if library.isLoaded {
                ContentUnavailableView(localized("找不到這個模組。"), systemImage: "puzzlepiece.extension")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(library.module(id: moduleID)?.module.title ?? localized("模組"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .task { if !library.isLoaded { await library.load() } }
    }

    private func page(_ installed: InstalledRuleModule) -> some View {
        Form {
            RuleModuleManifestSections(module: installed.module)

            Section {
                if let url = installed.subscriptionURL {
                    Text(url.absoluteString)
                        .foregroundStyle(DSColor.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("module.subscription")
                    Button {
                        showsUpdate = true
                        Task { await updates.checkForUpdate(installed) }
                    } label: {
                        SettingsRowLabel(localized("檢查更新"), systemImage: "arrow.triangle.2.circlepath", role: .action)
                    }
                    .accessibilityIdentifier("module.checkUpdate")
                }
            } header: {
                Text(localized("訂閱網址")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                if installed.subscriptionURL == nil {
                    Text(localized("從檔案或剪貼簿加入的模組沒有訂閱網址，無法檢查更新。")).dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            Section {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    SettingsRowLabel(localized("移除模組"), systemImage: "trash", role: .destructive)
                }
                .accessibilityIdentifier("module.remove")
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .sheet(isPresented: $showsUpdate) {
            RuleModuleImportSheet(model: updates, title: localized("檢查更新"))
        }
        .confirmationDialog(String(format: localized("移除「%@」？"), installed.module.title),
                            isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button(localized("移除模組"), role: .destructive) {
                Task { await remove() }
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("它的快取會一起刪除。"))
        }
        .alert(localized("操作失敗"), isPresented: Binding(get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } })) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(removalFailure ?? "")
        }
    }

    private func remove() async {
        do {
            try await library.remove(id: moduleID)
            dismiss()
        } catch {
            AppLogger.error("Module not removed", error: error, context: ["module": moduleID], level: .error)
            removalFailure = (error as? RuleModuleStoreError)?.message ?? error.localizedDescription
        }
    }
}

#Preview("A module's page") {
    NavigationStack {
        RuleModuleDetailView(moduleID: "example.newbooks", library: RuleModulePreviewData.library(["新書速報"]))
    }
}
