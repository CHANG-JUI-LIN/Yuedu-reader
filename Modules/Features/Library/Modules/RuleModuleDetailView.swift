import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A module's page (Phase 6e), pushed from 資源庫: what it lists, the sites it sends requests to,
/// where it came from with 檢查更新, and 移除模組. Since M6 its toolbar has 匯出 and 停用, and
/// 在資源庫中展示 decides whether its card is in 資源庫.
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
            // `installed(id:)`, not `module(id:)`: a module turned off keeps its page, where it is
            // turned back on.
            if let installed = library.installed(id: moduleID) {
                page(installed)
            } else if library.isLoaded {
                ContentUnavailableView(localized("找不到這個模組。"), systemImage: "puzzlepiece.extension")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(library.installed(id: moduleID)?.module.title ?? localized("模組"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            if let installed = library.installed(id: moduleID) {
                // Not in a menu: on iOS 17 a ShareLink inside a Menu loses its share sheet.
                if let file = library.file(of: installed) {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: RuleModuleExport(file: file, id: installed.module.id),
                                  preview: SharePreview(installed.module.title)) {
                            Text(localized("匯出"))
                        }
                        .accessibilityIdentifier("module.export")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let enabled = library.isEnabled(moduleID)
                    Button(localized(enabled ? "停用" : "模組：啟用")) {
                        library.setEnabled(!enabled, id: moduleID)
                    }
                    .accessibilityIdentifier("module.enabled")
                }
            }
        }
        .task { if !library.isLoaded { await library.load() } }
    }

    private func page(_ installed: InstalledRuleModule) -> some View {
        Form {
            if !library.isEnabled(moduleID) {
                Section {
                    Label(localized("已停用"), systemImage: "pause.circle")
                        .foregroundStyle(DSColor.textPrimary)
                } footer: {
                    Text(localized("停用時不會用它搜尋或補資料，首頁也不顯示它的欄目；它的書要啟用後才能讀。")).dsSectionFooter()
                }
                .interfaceSectionSurface()
            }

            RuleModuleManifestSections(module: installed.module)

            Section {
                Toggle(isOn: Binding(get: { library.isShownInLibrary(moduleID) },
                                     set: { library.setShownInLibrary($0, id: moduleID) })) {
                    Text(localized("在資源庫中展示")).foregroundStyle(DSColor.textPrimary)
                }
                .disabled(!library.isEnabled(moduleID))
                .accessibilityIdentifier("module.showsInLibrary")
            }
            .interfaceSectionSurface()

            if installed.isOfficial {
                officialSection
            } else {
                importedSections(installed)
            }
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

    /// Bundled with the app (M2): nothing to update or remove, so the page says how to stop using it.
    private var officialSection: some View {
        Section {
            Text(localized("官方模組")).foregroundStyle(DSColor.textPrimary)
        } footer: {
            Text(localized("隨閱讀一起更新，不能移除；不想用時，在「搜尋來源」和「資料來源」取消勾選。")).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private func importedSections(_ installed: InstalledRuleModule) -> some View {
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

#Preview("An official module's page") {
    NavigationStack {
        RuleModuleDetailView(moduleID: "bangumi", library: RuleModulePreviewData.officialLibrary())
    }
}

/// A module's file as 匯出 sends it: named after the module, not the store's `module.json`.
struct RuleModuleExport: Transferable {
    let file: URL
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleExport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("\(export.id).json")
            try FileManager.default.copyItem(at: export.file, to: copy)
            return SentTransferredFile(copy)
        }
    }
}
