import SwiftUI

/// 官方模組 or 匯入的模組, each a page of its own on 模組.
enum RuleModuleGroup: Hashable {
    case official, imported
}

extension EnvironmentValues {
    /// 資源庫's one 新增模組 flow, so a page it pushes adds through it: its sheet and file importer
    /// are presented from the root, never a second pair from the pushed page (SwiftUI presents
    /// only one of two file importers on a view).
    @Entry var ruleModuleAddFlow: RuleModuleAddFlow?
}

/// 模組 (M6, maintainer 2026-10-17: 「模組要做到截圖這樣」): where every module comes from — 官方模組,
/// each subscribed repository, 匯入的模組 — and the home sections left pointing at a module no
/// longer installed. 新增模組 is its toolbar's: an address may hold a module or a repository.
struct RuleModuleManagerView: View {
    @ObservedObject var library: RuleModuleLibrary
    @ObservedObject var repositories: RuleModuleRepositoryModel
    @ObservedObject private var home = HomePageStore.shared
    @Environment(\.ruleModuleAddFlow) private var addFlow
    /// Once per visit: back from a repository's page, the indexes are not read again.
    @State private var hasLoaded = false
    @State private var pendingUnsubscription: RuleModuleRepositoryModel.Repository?
    @State private var showsAddChooser = false
    @State private var addSequence = DismissalSequencedPresentation<RuleModuleAddRoute>()

    init(library: RuleModuleLibrary? = nil, repositories: RuleModuleRepositoryModel? = nil) {
        self.library = library ?? .shared
        self.repositories = repositories ?? .shared
    }

    private var referenceCount: Int {
        home.home?.moduleReferences(installed: Set(library.installed.map(\.module.id))).count ?? 0
    }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: ExploreNavigationRoute.moduleGroup(.official)) {
                    RuleModuleOriginRow(title: localized("官方模組"), systemImage: "puzzlepiece.extension.fill", isVerified: true,
                                        subtitle: localized("隨閱讀一起提供的模組"), origin: localized("閱讀"),
                                        count: library.official.count)
                }
                .accessibilityIdentifier("modules.official")

                ForEach(repositories.repositories) { repository in
                    NavigationLink(value: ExploreNavigationRoute.moduleRepository(repository.id)) {
                        RuleModuleOriginRow(title: repository.subscription.name, systemImage: "shippingbox",
                                            subtitle: subtitle(of: repository), origin: repository.id.absoluteString,
                                            count: repository.index?.modules.count)
                    }
                    .swipeActions {
                        Button(localized("取消訂閱"), role: .destructive) { pendingUnsubscription = repository }
                    }
                    .accessibilityIdentifier("modules.repository.\(repository.id.absoluteString)")
                }

                NavigationLink(value: ExploreNavigationRoute.moduleGroup(.imported)) {
                    RuleModuleOriginRow(title: localized("匯入的模組"), systemImage: "arrow.down.circle.fill",
                                        subtitle: localized("你自己加入的模組"), origin: localized("匯入"),
                                        count: library.imported.count + library.failures.count)
                }
                .accessibilityIdentifier("modules.imported")

                NavigationLink(value: ExploreNavigationRoute.homeModuleReferences) {
                    RuleModuleOriginRow(title: localized("首頁欄目引用"), systemImage: "rectangle.stack",
                                        subtitle: localized("管理引用未安裝模組的首頁欄目"), origin: nil, count: referenceCount)
                }
                .accessibilityIdentifier("modules.homeReferences")
            } footer: {
                Text(localized("第三方模組由作者自行維護，閱讀不審核其內容。加入前請確認來源可信；有問題的模組可以在「回饋與改進」回報。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("模組"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .hidesRootTabBar()
        .toolbar {
            if addFlow != nil {
                ToolbarItem(placement: .topBarTrailing) { addControl }
            }
        }
        .confirmationDialog(pendingUnsubscription.map { String(format: localized("取消訂閱「%@」？"), $0.subscription.name) } ?? "",
                            isPresented: Binding(get: { pendingUnsubscription != nil }, set: { if !$0 { pendingUnsubscription = nil } }),
                            titleVisibility: .visible, presenting: pendingUnsubscription) { repository in
            Button(localized("取消訂閱"), role: .destructive) { repositories.unsubscribe(repository.id) }
            Button(localized("取消"), role: .cancel) {}
        } message: { _ in
            Text(localized("已安裝的模組會留下。"))
        }
        .alert(localized("操作失敗"), isPresented: Binding(get: { repositories.message != nil },
                                                          set: { if !$0 { repositories.message = nil } })) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(repositories.message ?? "")
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await library.loadIfNeeded()
            await repositories.load()
        }
    }

    private func subtitle(of repository: RuleModuleRepositoryModel.Repository) -> String {
        switch repository.state {
        case .loading: localized("讀取中")
        case .loaded(let index): String(format: localized("%d 個模組"), index.modules.count)
        case .failed(let message): message
        }
    }

    /// 新增模組's three ways in. A native menu from iOS 18; on iOS 17 a chooser, since the
    /// sheet or file picker would be dropped while the menu dismisses
    /// (`Technotes/iOS17MenuModalPresentation.md`).
    @ViewBuilder
    private var addControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                addSequence.cancel()
                showsAddChooser = true
            } label: {
                Image(systemName: "doc.badge.plus").accessibilityHidden(true)
            }
            .accessibilityLabel(localized("新增模組"))
            .accessibilityIdentifier("modules.add")
            .sheet(isPresented: $showsAddChooser, onDismiss: {
                addSequence.consumeAfterDismissal().map { addFlow?.begin($0) }
            }) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("新增模組"),
                        actions: RuleModuleAddRoute.allCases.map {
                            DismissalSequencedAction(route: $0, title: localized($0.titleKey), systemImage: $0.systemImage)
                        },
                        onSelect: { addSequence.select($0) })
                }
            }
        } else if let addFlow {
            Menu {
                RuleModuleAddMenuItems(flow: addFlow)
            } label: {
                Image(systemName: "doc.badge.plus").accessibilityHidden(true)
            }
            .accessibilityLabel(localized("新增模組"))
            .accessibilityIdentifier("modules.add")
        }
    }
}

/// One row of 模組: where modules come from, what it is, and how many it holds.
struct RuleModuleOriginRow: View {
    let title: String
    let systemImage: String
    var isVerified = false
    let subtitle: String
    /// 來源：…; nil for a row that is not a place modules come from.
    let origin: String?
    /// Shown trailing; nil while it is not known.
    let count: Int?

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: systemImage)
                .font(DSFont.title2)
                .foregroundStyle(.tint)
                .frame(width: DSLayout.minimumTapTarget)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(title)
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                    if isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(DSColor.success)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                if let origin {
                    Text(String(format: localized("來源：%@"), origin))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            if let count {
                Text(count, format: .number)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isVerified ? [title, localized("官方")].joined(separator: ", ") : title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [subtitle]
        if let origin { parts.append(String(format: localized("來源：%@"), origin)) }
        if let count { parts.append(String(format: localized("%d 個"), count)) }
        return parts.joined(separator: ", ")
    }
}

#Preview("模組") {
    NavigationStack {
        RuleModuleManagerView(library: RuleModulePreviewData.officialLibrary())
            .environment(\.ruleModuleAddFlow, RuleModuleAddFlow())
    }
}
