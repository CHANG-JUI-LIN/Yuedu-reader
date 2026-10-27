import SwiftUI

/// 模組's 官方模組 and 匯入的模組: each module with its version and author, a module turned off
/// said so, and a folder that could not be read, which can only be removed. 官方模組 lists the
/// app's own first (`AppOfficialModule`), as 資源庫 does, with the app's version: they update with it.
struct RuleModuleGroupView: View {
    let group: RuleModuleGroup
    @ObservedObject var library: RuleModuleLibrary
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @State private var pendingRemoval: RuleModuleStore.Failure?
    @State private var removalFailure: String?

    init(group: RuleModuleGroup, library: RuleModuleLibrary? = nil) {
        self.group = group
        self.library = library ?? .shared
    }

    private var modules: [InstalledRuleModule] {
        group == .official ? library.official : library.imported
    }

    private var failures: [RuleModuleStore.Failure] {
        group == .imported ? library.failures : []
    }

    private var appModules: [AppOfficialModule] {
        group == .official ? AppOfficialModule.available(librariesAvailable: availability.isAvailable) : []
    }

    var body: some View {
        Group {
            if !library.isLoaded {
                ProgressView()
            } else if appModules.isEmpty && modules.isEmpty && failures.isEmpty {
                ContentUnavailableView(localized("還沒有模組"), systemImage: "puzzlepiece.extension")
            } else {
                Form {
                    Section {
                        ForEach(appModules) { module in
                            NavigationLink(value: module.route) {
                                RuleModuleRow(title: module.title, version: RuleModuleVersion.app, description: module.summary,
                                              author: localized("閱讀"), isOfficial: true)
                            }
                            .accessibilityIdentifier("modules.module.\(module.id)")
                        }
                        ForEach(modules, id: \.module.id) { installed in
                            NavigationLink(value: ExploreNavigationRoute.module(id: installed.module.id)) {
                                RuleModuleRow(module: installed.module, isEnabled: library.isEnabled(installed.module.id))
                            }
                            .accessibilityIdentifier("modules.module.\(installed.module.id)")
                        }
                        ForEach(failures, id: \.folder) { failure in
                            Button {
                                pendingRemoval = failure
                            } label: {
                                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                                    Text(failure.folder).foregroundStyle(DSColor.textPrimary)
                                    Text(localized("檔案損毀，或需要較新版本的閱讀。"))
                                        .font(DSFont.footnote)
                                        .foregroundStyle(DSColor.textSecondary)
                                }
                            }
                            .accessibilityLabel(failure.folder)
                            .accessibilityValue(localized("無法讀取的模組"))
                            .accessibilityHint(localized("移除模組"))
                        }
                    }
                    .interfaceSectionSurface()
                }
                .softScrollEdges()
            }
        }
        .navigationTitle(localized(group == .official ? "官方模組" : "匯入的模組"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .hidesRootTabBar()
        .task { await library.loadIfNeeded() }
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

/// A module in a list: its title, version trailing, its description and author.
struct RuleModuleRow: View {
    let title: String
    let version: String
    let description: String?
    let author: String?
    var isOfficial = false
    var isEnabled = true
    /// Trailing, in place of the version: 安裝, 更新 and the like on a repository's page.
    var status: String?

    init(title: String, version: String, description: String?, author: String?, isOfficial: Bool = false,
         isEnabled: Bool = true, status: String? = nil) {
        self.title = title
        self.version = version
        self.description = description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.author = author.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.isOfficial = isOfficial
        self.isEnabled = isEnabled
        self.status = status
    }

    init(module: RuleModule, isEnabled: Bool) {
        self.init(title: module.title, version: module.version, description: module.description, author: module.author,
                  isOfficial: OfficialRuleModules.reservedIDs.contains(module.id), isEnabled: isEnabled)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(title)
                        .font(DSFont.headline)
                        .foregroundStyle(isEnabled ? DSColor.textPrimary : DSColor.textSecondary)
                    if isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(DSColor.success)
                            .accessibilityHidden(true)
                    }
                }
                if let description {
                    Text(description)
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
                if let author {
                    Text(String(format: localized("作者：%@"), author))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                if !isEnabled {
                    Text(localized("已停用"))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.warning)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            Text(status ?? version)
                .font(DSFont.subheadline)
                .foregroundStyle(status == nil ? DSColor.textSecondary : DSColor.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOfficial ? [title, localized("官方")].joined(separator: ", ") : title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [String(format: localized("版本 %@"), version)]
        if let status { parts.append(status) }
        if !isEnabled { parts.append(localized("已停用")) }
        if let description { parts.append(description) }
        if let author { parts.append(String(format: localized("作者：%@"), author)) }
        return parts.joined(separator: ", ")
    }
}

#Preview("官方模組") {
    NavigationStack {
        RuleModuleGroupView(group: .official, library: RuleModulePreviewData.officialLibrary())
    }
}

#Preview("匯入的模組") {
    NavigationStack {
        RuleModuleGroupView(group: .imported, library: RuleModulePreviewData.library(["新書速報", "排行榜"]))
    }
}
