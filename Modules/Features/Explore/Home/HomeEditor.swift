import SwiftUI

// Unified library 5d-2: editing the home in place (Phase 5 plan, 5d-2; decisions 14 and 18).
// 編輯首頁, at the end of the home, turns every section into a card, as the maintainer's
// reference (Rex's home editor) shows: the mark beside a card shows or hides it, a card is
// dragged to reorder, and a tap pushes the section's form (`HomeSectionForm`, 5d-5). ＋ and
// the card after the sections open 新增欄目 (5d-5). Which libraries 最新 shows is 聚合設定's
// 顯示在最新 (5d-3f). 完成 ends it. A section name's long press offers the same edits outside it. Every change goes through `HomePageStore.edit`, so the home
// builds its rows again from the saved page.

enum HomeEditRoute: Hashable {
    case section(UUID)
}

extension View {
    /// A section's page, in the home's stack.
    func homeEditDestinations() -> some View {
        navigationDestination(for: HomeEditRoute.self) { route in
            switch route {
            case .section(let id): HomeSectionPage(sectionID: id)
            }
        }
    }
}

extension HomeSection {
    /// The section's name where no row names its source: its card, its page, its confirmation.
    @MainActor
    func editorTitle(connections: RemoteLibraryConnectionStore = .shared) -> String {
        let sourceName: String
        switch binding {
        case .opdsFeed(let connectionID, _): sourceName = connections.connection(id: connectionID)?.name ?? ""
        case .gutenbergFeed, .gutenbergShelf: sourceName = localized("Project Gutenberg")
        default: sourceName = ""
        }
        return displayTitle(sourceName: sourceName)
    }
}

// MARK: - The home, being edited

/// The home's sections as cards, hidden ones included, then 新增欄目, the 首頁配置's card and
/// •••'s.
struct HomeEditingSections<RowContent: View>: View {
    /// `HomePage.editableSections`.
    let sections: [HomeSection]
    /// The home's sections as drawn; a hidden section has none.
    let groups: [HomeSectionGroup]
    /// The 首頁配置 being edited (5d-4).
    let configuration: HomeConfigurationListing?
    let rowContent: (HomeSectionGroup) -> RowContent
    let openSettings: (UUID) -> Void
    /// Renaming or deleting the 首頁配置, asked by the home.
    let prompt: (HomeConfigurationPrompt) -> Void
    /// 新增欄目, presented by the home.
    let addSection: () -> Void
    @ObservedObject private var pageStore = HomePageStore.shared
    @AppStorage(ExploreSettings.showsBrowserKey) private var showsBrowser = true

    init(sections: [HomeSection], groups: [HomeSectionGroup], configuration: HomeConfigurationListing?,
         openSettings: @escaping (UUID) -> Void, prompt: @escaping (HomeConfigurationPrompt) -> Void,
         addSection: @escaping () -> Void,
         @ViewBuilder rowContent: @escaping (HomeSectionGroup) -> RowContent) {
        self.sections = sections
        self.groups = groups
        self.configuration = configuration
        self.openSettings = openSettings
        self.prompt = prompt
        self.addSection = addSection
        self.rowContent = rowContent
    }

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            card(section, at: index)
        }
        addCard
        if let configuration { configurationCard(configuration) }
        moreCard
    }

    private func card(_ section: HomeSection, at index: Int) -> some View {
        let title = section.editorTitle()
        // A section with nothing to draw shows its name, so its card is not blank.
        let group = groups.first { $0.section.id == section.id && !$0.isSettledEmpty }
        return HStack(spacing: DSSpacing.sm) {
            Button {
                pageStore.edit { $0.setEnabled(!section.isEnabled, section: section.id) }
            } label: {
                Image(systemName: section.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(DSFont.title2)
                    .foregroundStyle(section.isEnabled ? DSColor.textPrimary : DSColor.textTertiary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(localized(section.isEnabled ? "狀態：顯示" : "已隱藏"))
            .accessibilityIdentifier("homeEditor.toggle.\(section.id.uuidString)")

            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                if let group {
                    rowContent(group)
                } else {
                    Text(title)
                        .font(DSFont.title2.weight(.bold))
                        .foregroundStyle(DSColor.textSecondary)
                        .padding(.horizontal, DSSpacing.lg)
                }
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
            .onTapGesture { openSettings(section.id) }
            .draggable(section.id.uuidString) {
                Text(title).font(DSFont.headline).padding(DSSpacing.md)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                move(dragged, to: index)
                return true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(localized("設定"))
            .accessibilityAction { openSettings(section.id) }
            .accessibilityAction(named: localized("上移")) { if index > 0 { move(section.id, to: index - 1) } }
            .accessibilityAction(named: localized("下移")) {
                if index < sections.count - 1 { move(section.id, to: index + 1) }
            }
            .accessibilityIdentifier("homeEditor.section.\(section.id.uuidString)")
        }
        .padding(.trailing, DSSpacing.lg)
        .id(section.id)
    }

    /// Puts a section where the card at `target` is now.
    private func move(_ id: UUID, to target: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }), from != target else { return }
        pageStore.edit { $0.moveEditable(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target) }
    }

    /// 新增欄目 after the last card, where the bar's ＋ is out of reach: at the end of the home
    /// iOS 27's minimized bar hides its buttons.
    private var addCard: some View {
        Button(action: addSection) {
            Label(localized("新增欄目"), systemImage: "plus")
                .font(DSFont.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpacing.lg)
                .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSColor.accent)
        .padding(.leading, DSLayout.minimumTapTarget + DSSpacing.sm)
        .padding(.trailing, DSSpacing.lg)
        .accessibilityIdentifier("homeEditor.addSection")
    }

    /// The 首頁配置 being edited: its name, and for the reader's own, 重新命名 and 刪除 (5d-4).
    /// 預設 and 空白 keep theirs.
    private func configurationCard(_ configuration: HomeConfigurationListing) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("首頁配置"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(configuration.name)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textSecondary)
            if !configuration.id.isBuiltIn {
                HStack(spacing: DSSpacing.md) {
                    Button(localized("重新命名")) { prompt(.rename(configuration)) }
                        .accessibilityIdentifier("homeEditor.renameConfiguration")
                    Button(localized("刪除"), role: .destructive) { prompt(.delete(configuration)) }
                        .accessibilityIdentifier("homeEditor.deleteConfiguration")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.lg)
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        .padding(.leading, DSLayout.minimumTapTarget + DSSpacing.sm)
        .padding(.trailing, DSSpacing.lg)
    }

    /// •••'s own entries: the browser's switch (settled decision 13). Titled 更多, the •••'s
    /// name, since 範圍 left 探索 (decision 36, maintainer, 2026-10-13).
    private var moreCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("更多"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Toggle(localized("瀏覽器"), isOn: $showsBrowser)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        .padding(.leading, DSLayout.minimumTapTarget + DSSpacing.sm)
        .padding(.trailing, DSSpacing.lg)
    }
}

extension View {
    /// Deleting a section asks first.
    func homeSectionDeleteConfirmation(isPresented: Binding<Bool>, title: String,
                                       delete: @escaping () -> Void) -> some View {
        confirmationDialog(String(format: localized("刪除「%@」？"), title), isPresented: isPresented,
                           titleVisibility: .visible) {
            Button(localized("刪除"), role: .destructive, action: delete)
            Button(localized("取消"), role: .cancel) {}
        }
    }
}

#Preview("編輯中的首頁") {
    let sections = [
        HomeSection(layout: .row, binding: .continueReading),
        HomeSection(layout: .row, binding: .nextInSeries),
        HomeSection(layout: .row, binding: .gutenbergCollection(id: PublicLibraryCollection.chinese.id), isEnabled: false),
        HomeSection(layout: .row, binding: .related),
    ]
    ScrollView {
        LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
            HomeEditingSections(sections: sections, groups: [],
                                configuration: HomeConfigurationListing(id: HomeConfigurationID(UUID()), name: "週末"),
                                openSettings: { _ in }, prompt: { _ in }, addSection: {}) { _ in EmptyView() }
        }
    }
}
