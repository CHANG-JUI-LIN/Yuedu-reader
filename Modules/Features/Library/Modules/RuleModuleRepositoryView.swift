import SwiftUI

/// A subscribed repository's page (M6): its modules against the installed ones, the index read
/// again as the page opens (maintainer, 2026-10-17: updates are checked then and applied only on
/// 更新). One module installs or updates through the import sheet's preview; 選擇 installs
/// several at once, leaving an update that adds a site for its own preview.
struct RuleModuleRepositoryView: View {
    let url: URL
    @ObservedObject var repositories: RuleModuleRepositoryModel
    @ObservedObject var library: RuleModuleLibrary
    @StateObject private var importer: RuleModuleImportModel
    @State private var showsImport = false
    @State private var importTitle = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var isInstalling = false
    @State private var outcome: RuleModuleRepositoryModel.BatchOutcome?
    @State private var hasLoaded = false
    @State private var confirmsUnsubscription = false
    @Environment(\.dismiss) private var dismiss

    init(url: URL, repositories: RuleModuleRepositoryModel? = nil, library: RuleModuleLibrary? = nil) {
        let library = library ?? .shared
        let repositories = repositories ?? .shared
        self.url = url
        self.repositories = repositories
        self.library = library
        _importer = StateObject(wrappedValue: RuleModuleImportModel(library: library, repositories: repositories))
    }

    private var repository: RuleModuleRepositoryModel.Repository? {
        repositories.repositories.first { $0.id == url }
    }

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if let repository {
                content(repository)
            } else {
                ContentUnavailableView(localized("找不到這個模組倉庫。"), systemImage: "shippingbox")
            }
        }
        .navigationTitle(repository?.subscription.name ?? localized("模組倉庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .hidesRootTabBar()
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .sheet(isPresented: $showsImport) {
            RuleModuleImportSheet(model: importer, title: importTitle)
        }
        .confirmationDialog(String(format: localized("取消訂閱「%@」？"), repository?.subscription.name ?? ""),
                            isPresented: $confirmsUnsubscription, titleVisibility: .visible) {
            Button(localized("取消訂閱"), role: .destructive) {
                repositories.unsubscribe(url)
                dismiss()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("已安裝的模組會留下。"))
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await library.loadIfNeeded()
            if repositories.repositories.isEmpty { await repositories.load() } else { await repositories.reload(url) }
        }
    }

    @ViewBuilder
    private func content(_ repository: RuleModuleRepositoryModel.Repository) -> some View {
        switch repository.state {
        case .loading:
            ProgressView(localized("讀取中"))
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("載入失敗"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button(localized("重試")) { Task { await repositories.reload(url) } }
                Button(localized("取消訂閱"), role: .destructive) { confirmsUnsubscription = true }
            }
        case .loaded(let index):
            list(index)
        }
    }

    private func list(_ index: RuleModuleRepositoryIndex) -> some View {
        List(selection: $selection) {
            if let outcome, !outcome.needsReview.isEmpty || !outcome.failed.isEmpty {
                outcomeSection(outcome, index: index)
            }
            Section {
                ForEach(index.modules) { entry in
                    row(entry)
                }
            } header: {
                Text(localized("模組列表")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                if let outcome {
                    Text(summary(outcome)).dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            if !isSelecting {
                Section {
                    Text(url.absoluteString)
                        .foregroundStyle(DSColor.textPrimary)
                        .textSelection(.enabled)
                    Button(role: .destructive) {
                        confirmsUnsubscription = true
                    } label: {
                        SettingsRowLabel(localized("取消訂閱"), systemImage: "minus.circle", role: .destructive)
                    }
                    .accessibilityIdentifier("modules.repository.unsubscribe")
                } header: {
                    Text(localized("訂閱網址")).foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
    }

    @ViewBuilder
    private func row(_ entry: RuleModuleRepositoryIndex.Entry) -> some View {
        let status = repositories.status(of: entry)
        let isInstallable = status == .notInstalled || { if case .updateAvailable = status { true } else { false } }()
        let label = RuleModuleRow(title: entry.title, version: entry.version, description: entry.description, author: entry.author,
                                  isOfficial: status == .official, isEnabled: library.isEnabled(entry.id),
                                  status: statusText(status))
        Group {
            if isInstallable {
                Button {
                    offer(entry, isUpdate: status != .notInstalled)
                } label: {
                    label
                }
                .accessibilityHint(localized(status == .notInstalled ? "新增模組" : "更新模組"))
            } else {
                NavigationLink(value: ExploreNavigationRoute.module(id: entry.id)) { label }
            }
        }
        .tag(entry.id)
        .selectionDisabled(!isInstallable)
        .accessibilityIdentifier("modules.repository.entry.\(entry.id)")
    }

    private func statusText(_ status: RuleModuleRepositoryStatus) -> String? {
        switch status {
        case .notInstalled: localized("模組狀態：安裝")
        case .updateAvailable: localized("模組狀態：更新")
        case .installed, .official: nil
        }
    }

    private func outcomeSection(_ outcome: RuleModuleRepositoryModel.BatchOutcome,
                                index: RuleModuleRepositoryIndex) -> some View {
        Section {
            ForEach(outcome.needsReview, id: \.id) { item in
                Button {
                    if let entry = index.modules.first(where: { $0.id == item.id }) { offer(entry, isUpdate: true) }
                } label: {
                    outcomeLabel(item.title, localized("這次更新會向新的網站送出請求，點一下看過再更新。"))
                }
            }
            ForEach(outcome.failed, id: \.id) { item in
                outcomeLabel(item.title, item.message ?? "")
            }
        } header: {
            Text(localized("需要處理")).foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    private func outcomeLabel(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Text(title).foregroundStyle(DSColor.textPrimary)
            Text(message)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ outcome: RuleModuleRepositoryModel.BatchOutcome) -> String {
        String(format: localized("已安裝 %1$d 個、更新 %2$d 個模組。"), outcome.installed.count, outcome.updated.count)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if repository?.index != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(localized(isSelecting ? "完成" : "列表：選擇")) {
                    withAnimation(DSAnimation.standard) {
                        editMode = isSelecting ? .inactive : .active
                        if !isSelecting { selection.removeAll() }
                    }
                }
                .accessibilityIdentifier("modules.repository.select")
            }
        }
        if !isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await repositories.reload(url) }
                } label: {
                    Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                }
                .accessibilityLabel(localized("重新整理"))
                .disabled(repository?.state == .loading)
                .accessibilityIdentifier("modules.repository.reload")
            }
        } else {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await installSelection() }
                } label: {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Text(selection.isEmpty ? localized("安裝") : String(format: localized("安裝 %d 個"), selection.count))
                    }
                }
                .disabled(selection.isEmpty || isInstalling)
                .accessibilityIdentifier("modules.repository.installSelection")
            }
        }
    }

    private func offer(_ entry: RuleModuleRepositoryIndex.Entry, isUpdate: Bool) {
        importer.reset()
        importTitle = localized(isUpdate ? "更新模組" : "新增模組")
        showsImport = true
        Task { await importer.offer(entry) }
    }

    private func installSelection() async {
        guard let index = repository?.index else { return }
        isInstalling = true
        defer { isInstalling = false }
        let chosen = index.modules.filter { selection.contains($0.id) }
        outcome = await repositories.install(chosen)
        selection.removeAll()
        editMode = .inactive
    }
}

#Preview("模組倉庫") {
    NavigationStack {
        RuleModuleRepositoryView(url: URL(string: "https://modules.example/index.json")!,
                                 library: RuleModulePreviewData.library(["新書速報"]))
    }
}
