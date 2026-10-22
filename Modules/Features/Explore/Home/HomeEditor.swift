import SwiftUI

// Unified library 5d-2: editing the home in place (Phase 5 plan, 5d-2; decisions 14 and 18).
// 編輯首頁, at the end of the home, turns every section into a card, as the maintainer's
// reference (Rex's home editor) shows: the mark beside a card shows or hides it, a card is
// dragged to reorder, and a tap pushes the section's form (`HomeSectionForm`, 5d-5). The ＋ in
// the bottom bar, where the tab bar was, opens 新增欄目 (5d-5); 完成 is the bar's and the home's
// last button. Nothing follows the cards: the 首頁配置 is renamed and deleted from •••, and the
// browser has no switch (maintainer, 2026-10-17). Which libraries 最新 shows is 聚合設定's
// 顯示在最新 (5d-3f). A section name's long press offers the same edits outside it. Every change
// goes through `HomePageStore.edit`, so the home builds its rows again from the saved page.

enum HomeEditRoute: Hashable {
    case section(UUID)
    /// 首頁配置's page, from its button on the home (maintainer, 2026-10-22).
    case configurations
}

extension View {
    /// A section's page and 首頁配置's, in the home's stack.
    func homeEditDestinations() -> some View {
        navigationDestination(for: HomeEditRoute.self) { route in
            switch route {
            // Configuration: no tab bar, as in the editor it opens from (maintainer, 2026-10-17).
            // Each page it pushes asks again (`HomeSectionForm`): a page under another one
            // withdraws its request.
            case .section(let id): HomeSectionPage(sectionID: id).hidesRootTabBar()
            case .configurations: HomeConfigurationsPage().hidesRootTabBar()
            }
        }
    }
}

extension HomeSection {
    /// The section's name where no row names its source: its card, its page, its confirmation.
    @MainActor
    func editorTitle(connections: RemoteLibraryConnectionStore = .shared, modules: RuleModuleLibrary = .shared) -> String {
        let sourceName: String
        switch binding {
        case .opdsFeed(let connectionID, _): sourceName = connections.connection(id: connectionID)?.name ?? ""
        case .gutenbergFeed, .gutenbergShelf: sourceName = localized("Project Gutenberg")
        // An untitled module list (the defaults) by its list's title, as its row reads
        // (`ModuleProvider.rowName`); by its id once its module is gone.
        case .module(let moduleID, let entryID):
            let module = modules.installed(id: moduleID)?.module
            sourceName = module?.modules.first { $0.id == entryID }?.title ?? module?.title ?? entryID
        default: sourceName = ""
        }
        return displayTitle(sourceName: sourceName)
    }
}

// MARK: - A section, in and out of 編輯首頁

/// A section in the home's one list, the same in and out of 編輯首頁: every section the home
/// draws and every section 編輯首頁 lists, hidden ones too, in the page's order.
struct HomeSectionEntry: Identifiable {
    let section: HomeSection
    /// The section as the home draws it, and its card too, the same books (maintainer,
    /// 2026-10-22); nil for a hidden one.
    let homeGroup: HomeSectionGroup?
    /// Its place in `HomePage.editableSections`, for 上移 and 下移; nil for one 編輯首頁 does not list.
    let editableIndex: Int?

    var id: UUID { section.id }

    /// The home gives it room: drawn, and not loaded with nothing in it.
    var isOnHome: Bool {
        homeGroup.map { !$0.isSettledEmpty } ?? false
    }
}

extension EnvironmentValues {
    /// How far 編輯首頁's morph has come: 0 on the home, 1 in the editor, and every frame between.
    @Entry var homeEditProgress: Double = 0
}

extension View {
    /// 編輯首頁's morph as one number for every section under it (`homeEditProgress`), animated
    /// with `isEditing`. Held here, once: a row the lazy stack makes during the morph reads where
    /// it has come, where one animating its own would start at its end.
    func homeEditMorph(_ isEditing: Bool) -> some View {
        modifier(HomeEditMorph(progress: isEditing ? 1 : 0))
    }
}

private struct HomeEditMorph: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.homeEditProgress, progress)
    }
}

/// One section of the home, the same view in and out of 編輯首頁, so the switch morphs it into
/// its card and back (maintainer, 2026-10-21) rather than cutting from one to the other: the
/// mark slides in beside it, the card fills in under it, and the row keeps its identity — its
/// carousel's place, and the load it already ran.
struct HomeSectionSlot<RowContent: View>: View {
    let entry: HomeSectionEntry
    let isEditing: Bool
    /// The home's width, which the row keeps in its card; 0 until the home has measured it.
    let pageWidth: CGFloat
    /// How many sections 編輯首頁 lists: 下移.
    let count: Int
    let openSettings: (UUID) -> Void
    let rowContent: (HomeSectionGroup) -> RowContent
    @ObservedObject private var pageStore = HomePageStore.shared

    init(entry: HomeSectionEntry, isEditing: Bool, pageWidth: CGFloat, count: Int,
         openSettings: @escaping (UUID) -> Void, @ViewBuilder rowContent: @escaping (HomeSectionGroup) -> RowContent) {
        self.entry = entry
        self.isEditing = isEditing
        self.pageWidth = pageWidth
        self.count = count
        self.openSettings = openSettings
        self.rowContent = rowContent
    }

    private var section: HomeSection { entry.section }

    var body: some View {
        let title = section.editorTitle()
        content(title)
            .modifier(HomeSectionMorph(isEditing: isEditing, pageWidth: pageWidth, isOnHome: entry.isOnHome,
                                       isOnEditor: entry.editableIndex != nil,
                                       mark: toggle(title), surface: editingSurface(title)))
    }

    /// The row, the same in its card. A section the home gives no room, hidden or with nothing
    /// to draw, has its name in its card, so it is not blank.
    @ViewBuilder
    private func content(_ title: String) -> some View {
        if entry.isOnHome, let group = entry.homeGroup {
            rowContent(group)
        } else {
            Text(title)
                .font(DSFont.title2.weight(.bold))
                .foregroundStyle(DSColor.textSecondary)
                .padding(.horizontal, DSSpacing.lg)
        }
    }

    private func toggle(_ title: String) -> some View {
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
    }

    /// The card while the home is edited: a tap opens the section's form, a drag reorders. Over
    /// the row, whose own buttons and scrolling are off meanwhile.
    private func editingSurface(_ title: String) -> some View {
        let index = entry.editableIndex ?? 0
        return Color.clear
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
            .onTapGesture { openSettings(section.id) }
            .draggable(section.id.uuidString) {
                Text(title).font(DSFont.headline).padding(DSSpacing.md)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                pageStore.moveEditableSection(dragged, to: index)
                return true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(localized("設定"))
            .accessibilityAction { openSettings(section.id) }
            .accessibilityAction(named: localized("上移")) {
                if index > 0 { pageStore.moveEditableSection(section.id, to: index - 1) }
            }
            .accessibilityAction(named: localized("下移")) {
                if index < count - 1 { pageStore.moveEditableSection(section.id, to: index + 1) }
            }
            .accessibilityIdentifier("homeEditor.section.\(section.id.uuidString)")
    }
}

/// A section's card as far into 編輯首頁 as the morph has come (`homeEditProgress`): the mark
/// beside it, its margins, width, fill and clip, and its room on the home, all worked out again on
/// every frame. Laid out once, at the morph's end, the home's lazy stack chose the rows to draw from
/// where they would end while the page still showed where they had been; on the way out, a home a
/// screen shorter than its editor ended above the page's offset, and every row was gone (the
/// maintainer's device, which stayed blank; iOS 27 simulator with ten hidden sections).
private struct HomeSectionMorph<Mark: View, Surface: View>: ViewModifier {
    let isEditing: Bool
    let pageWidth: CGFloat
    let isOnHome: Bool
    let isOnEditor: Bool
    let mark: Mark
    let surface: Surface
    @Environment(\.homeEditProgress) private var progress

    /// The mark and the gap after it.
    private static var markWidth: CGFloat { DSLayout.minimumTapTarget + DSSpacing.sm }

    func body(content: Content) -> some View {
        let edited = CGFloat(progress)
        let shape = RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
        let width = pageWidth > 0 ? pageWidth : nil
        // From its room on the home to its room in the editor; whole in both, never a rounding off.
        let presence: CGFloat = switch (isOnHome, isOnEditor) {
        case (true, true): 1
        case (false, false): 0
        case (true, false): 1 - edited
        case (false, true): edited
        }
        let cardWidth = width.map { $0 - (Self.markWidth + DSSpacing.lg) * edited }
        // Kept, at no height, where it has no room. Left out of the home until the morph, the ten
        // hidden sections joined the lazy stack all at once as it began, and its guess at the rows it
        // had not reached grew by 811 points: the page went after that end and the rows flew off
        // the screen (iOS 27 simulator).
        HomeSectionPresence(presence: presence) {
            content
                // The home's width in its card too: the mark moves the row aside and the card cuts
                // it at its edge. Laid out in the card's own width, the row shrank — a carousel's
                // cards, a grid's covers, a synopsis's lines (maintainer, 2026-10-21 and 2026-10-22).
                .frame(width: width, alignment: .leading)
                .allowsHitTesting(!isEditing)
                // In 編輯首頁 the card is one element, the surface over it.
                .accessibilityHidden(onlyWhen: isEditing || presence < 1)
                .padding(.vertical, DSSpacing.lg * edited)
                .frame(width: cardWidth, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .background(DSColor.surface.opacity(edited), in: shape)
                // The sideways rows draw past their bounds (`scrollClipDisabled`): the card cuts
                // them at its edge; on the home the cut is past the screen's.
                .clipShape(shape.inset(by: -DSSpacing.xxl * (1 - edited)))
                .overlay {
                    if isEditing { surface.accessibilityHidden(presence < 1) }
                }
                .padding(.leading, Self.markWidth * edited)
                .overlay(alignment: .leading) {
                    // Only from the morph on: on the home, off the screen, a mark is a button for
                    // nothing, one for every section, the hidden ones' too.
                    if edited > 0 {
                        mark
                            .offset(x: -Self.markWidth * (1 - edited))
                            .opacity(edited)
                            .allowsHitTesting(isEditing)
                            .accessibilityHidden(!isEditing || presence < 1)
                    }
                }
                .padding(.trailing, DSSpacing.lg * edited)
                // The gap to the next section, going with the section's room.
                .padding(.bottom, DSSpacing.xxl)
        }
        .clipShape(HomeSectionPresenceClip(clips: presence < 1))
        .allowsHitTesting(presence == 1)
        // Hidden where it has no room by the content, mark and surface themselves. Said out here
        // as well, its `false` won over theirs: 編輯首頁's rows and, after 完成, the marks were
        // still VoiceOver elements under the cards (iOS 27 simulator).
    }
}

extension View {
    /// Hidden from VoiceOver while `hides`, and nothing said otherwise: `accessibilityHidden(false)`
    /// over a view overrode the `accessibilityHidden(true)` inside it (iOS 17.5 and 27 simulators),
    /// so around a row it brought back what the row hides — a symbol read out by its name.
    @ViewBuilder
    func accessibilityHidden(onlyWhen hides: Bool) -> some View {
        if #available(iOS 18, *) {
            accessibilityHidden(true, isEnabled: hides)
        } else {
            // iOS 17 has only the one that always says. A container between keeps its `false` off
            // what is inside; a modifier, so the view keeps its identity as `hides` changes.
            accessibilityElement(children: .contain).accessibilityHidden(hides)
        }
    }
}

/// Its content's height times `presence`, drawn from the top.
private struct HomeSectionPresence: Layout {
    let presence: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(proposal) else { return .zero }
        return CGSize(width: size.width, height: size.height * presence)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

/// What a section going to or from nothing cuts at its top and bottom. Nothing sideways, where its
/// rows draw past their bounds, and nothing at all at full height, where its covers' shadows do.
private struct HomeSectionPresenceClip: Shape {
    let clips: Bool

    func path(in rect: CGRect) -> Path {
        Path(clips ? rect.insetBy(dx: -rect.width, dy: 0) : rect.insetBy(dx: -rect.width, dy: -rect.height))
    }
}

extension HomePageStore {
    /// Puts a section where the card at `target` of `HomePage.editableSections` is now.
    func moveEditableSection(_ id: UUID, to target: Int) {
        guard let sections = page?.editableSections,
              let from = sections.firstIndex(where: { $0.id == id }), from != target else { return }
        edit { $0.moveEditable(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target) }
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
    @Previewable @State var isEditing = true
    @Previewable @State var pageWidth: CGFloat = 0
    let entries = [
        HomeSection(layout: .row, binding: .continueReading),
        HomeSection(layout: .row, binding: .nextInSeries),
        HomeSection(layout: .row, binding: .gutenbergCollection(id: PublicLibraryCollection.chinese.id), isEnabled: false),
        HomeSection(layout: .row, binding: .related),
    ].enumerated().map { HomeSectionEntry(section: $1, homeGroup: nil, editableIndex: $0) }
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                HomeSectionSlot(entry: entry, isEditing: isEditing, pageWidth: pageWidth, count: entries.count,
                                openSettings: { _ in }) { _ in EmptyView() }
            }
            Button(isEditing ? "完成" : "編輯首頁") {
                withAnimation(DSAnimation.homeEditMorph) { isEditing.toggle() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .homeEditMorph(isEditing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }
}
