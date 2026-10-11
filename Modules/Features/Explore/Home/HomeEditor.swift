import SwiftUI

// Unified library 5d-2: editing the home in place (Phase 5 plan, 5d-2; decisions 14 and 18).
// 編輯首頁, at the end of the home, turns every section into a card, as the maintainer's
// reference (Rex's home editor) shows: the mark beside a card shows or hides it, a card is
// dragged to reorder, and a tap pushes the section's own page (在首頁顯示, 最新's 排除的來源,
// 刪除), where 5d-5's section form will grow. 完成 ends it. A section name's long press offers
// the same edits outside it. Every change goes through `HomePageStore.edit`, so the home
// builds its rows again from the saved page.

enum HomeEditRoute: Hashable {
    case section(UUID)
}

extension View {
    /// A section's page, in the home's stack.
    func homeEditDestinations(model: HomeModel) -> some View {
        navigationDestination(for: HomeEditRoute.self) { route in
            switch route {
            case .section(let id): HomeSectionPage(sectionID: id, model: model)
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
        case .gutenbergFeed: sourceName = localized("Project Gutenberg")
        default: sourceName = ""
        }
        return displayTitle(sourceName: sourceName)
    }
}

// MARK: - The home, being edited

/// The home's sections as cards, hidden ones included, then 範圍's card.
struct HomeEditingSections<RowContent: View>: View {
    /// `HomePage.editableSections`.
    let sections: [HomeSection]
    /// The home's sections as drawn; a hidden section has none.
    let groups: [HomeSectionGroup]
    let rowContent: (HomeSectionGroup) -> RowContent
    let openSettings: (UUID) -> Void
    @ObservedObject private var pageStore = HomePageStore.shared
    @AppStorage(ExploreSettings.showsBrowserKey) private var showsBrowser = true

    init(sections: [HomeSection], groups: [HomeSectionGroup], openSettings: @escaping (UUID) -> Void,
         @ViewBuilder rowContent: @escaping (HomeSectionGroup) -> RowContent) {
        self.sections = sections
        self.groups = groups
        self.openSettings = openSettings
        self.rowContent = rowContent
    }

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            card(section, at: index)
        }
        scopeCard
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
            .accessibilityValue(localized(section.isEnabled ? "顯示" : "已隱藏"))
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
    }

    /// Puts a section where the card at `target` is now.
    private func move(_ id: UUID, to target: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }), from != target else { return }
        pageStore.edit { $0.moveEditable(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target) }
    }

    /// 範圍's own entries: the browser's switch (settled decision 13).
    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("範圍"))
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

// MARK: - One section

struct HomeSectionPage: View {
    let sectionID: UUID
    let model: HomeModel
    @ObservedObject private var pageStore = HomePageStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    private var section: HomeSection? {
        pageStore.page?.sections.first { $0.id == sectionID }
    }

    var body: some View {
        Form {
            if let section {
                Section {
                    Toggle(localized("在首頁顯示"), isOn: Binding(
                        get: { section.isEnabled },
                        set: { isEnabled in pageStore.edit { $0.setEnabled(isEnabled, section: sectionID) } }))
                }
                .interfaceSectionSurface()
                if case .latest(let excluded) = section.binding {
                    excludedSources(excluded)
                }
                Section {
                    Button(localized("刪除"), role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("homeSection.delete")
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(section?.editorTitle() ?? "")
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .homeSectionDeleteConfirmation(isPresented: $confirmsDelete, title: section?.editorTitle() ?? "") {
            dismiss()
            pageStore.edit { $0.removeSection(sectionID) }
        }
    }

    /// The sources that serve 最新; a checked one has no 最新 row. A source excluded and since
    /// removed stays in the list, unseen, so it stays excluded if it comes back.
    private func excludedSources(_ excluded: [SourceInstanceKey]) -> some View {
        Section(localized("排除的來源")) {
            ForEach(model.latestSources(), id: \.key) { source in
                let isExcluded = excluded.contains(source.key)
                Button {
                    let changed = isExcluded ? excluded.filter { $0 != source.key } : excluded + [source.key]
                    pageStore.edit { $0.setExcluded(changed, section: sectionID) }
                } label: {
                    HStack {
                        Text(source.name).foregroundStyle(DSColor.textPrimary)
                        Spacer()
                        if isExcluded {
                            Image(systemName: "checkmark")
                                .foregroundStyle(DSColor.accent)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(isExcluded ? .isSelected : [])
                .accessibilityIdentifier("homeSection.exclude.\(source.key.type.rawValue).\(source.key.id)")
            }
        }
        .interfaceSectionSurface()
    }
}

extension View {
    /// Deleting a section asks first: a default section cannot be added back until 新增欄目.
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
        HomeSection(layout: .row, binding: .gutenbergCollection(id: PublicLibraryCollection.chinese.id), isEnabled: false),
        HomeSection(layout: .row, binding: .related),
    ]
    ScrollView {
        LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
            HomeEditingSections(sections: sections, groups: [], openSettings: { _ in }) { _ in EmptyView() }
        }
    }
}
