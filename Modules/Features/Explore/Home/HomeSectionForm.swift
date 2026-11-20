import SwiftUI

// Unified library 5d-5: one section's form (design §13.3, Rex's 「設定資料來源」; Phase 5 plan,
// decision 23), for 新增欄目 and for a section already on the home, so there is one editor:
// - 新增欄目 asks for a layout first, then shows this form (Rex's order), in a sheet; 新增
//   puts the section at the end of the 首頁配置 shown, 取消 leaves it as it was.
// - A section's card in 編輯首頁, and 設定 in its name's long press, push the same form.
// - On top, a preview: one real page of the section in its layout, loaded as the home loads
//   it. Then 標題 and 副標題 (empty follows what it shows), 呈現方式, 資料來源 (opens 選擇內容來源),
//   and for a section on the home, 在首頁顯示 and 刪除.
// - In a layout of lists (maintainer, 2026-10-27; one card at a time since 2026-11-16), the
//   preview's cards are picked and edited in place of 資料來源; its last card, 加入清單, opens
//   選擇內容來源, where a source's 全部清單 adds every list it offers. With no card yet (a new
//   section where Gutenberg's lists are not chosen for it, FB-227) the preview is 加入清單 alone.

// MARK: - A section on the home

struct HomeSectionPage: View {
    let sectionID: UUID
    @ObservedObject private var pageStore = HomePageStore.shared
    @EnvironmentObject private var store: BookStore

    var body: some View {
        if let section = pageStore.page?.sections.first(where: { $0.id == sectionID }) {
            HomeSectionFormHost(section: section, store: store)
        } else {
            // Deleted, here or from its long press: the page empties as it pops.
            Color.clear.themedAppSurface(for: .explore)
        }
    }
}

/// Makes the form's editor once, with the shelf the preview reads.
///
/// It does not read `dismiss` (刪除 leaves the page, `HomeSectionDeleteButton`): on iOS 17.5, a host
/// reading it while the form pushed 新增來源配置 froze the app, `_dismiss changed.` 13,830 times
/// (5d-5), as the search page did (`Technotes/iOS17SearchWatchdogPostmortem.md`, guardrail 12).
private struct HomeSectionFormHost: View {
    @StateObject private var editor: HomeSectionEditor

    init(section: HomeSection, store: BookStore) {
        _editor = StateObject(wrappedValue: HomeSectionEditor(section: section, preview: .preview(shelf: store)))
    }

    var body: some View {
        HomeSectionForm(editor: editor, isInSheet: false)
    }
}

extension HomeModel {
    /// The form's preview: a home of its own, served by the same sources as the home.
    static func preview(shelf: BookStore) -> HomeModel {
        live(shelf: shelf)
    }
}

// MARK: - 新增欄目

/// 新增欄目, full screen over the home: a layout, then the form. The home closes it (`close`,
/// and after `added`): nothing in it reads `dismiss`, which loops on iOS 17 under a form that
/// pushes (`HomeSectionFormHost`).
struct HomeNewSectionSheet: View {
    /// The section 新增 put on the home; the home closes the sheet.
    var added: (UUID) -> Void = { _ in }
    /// 取消.
    var close: () -> Void = {}
    @EnvironmentObject private var store: BookStore

    var body: some View {
        HomeNewSectionFlow(store: store, added: added, close: close)
    }
}

private struct HomeNewSectionFlow: View {
    let store: BookStore
    let added: (UUID) -> Void
    let close: () -> Void
    @State private var editor: HomeSectionEditor?
    @State private var showsForm = false
    @ObservedObject private var availability = PublicLibraryAvailability.shared

    var body: some View {
        NavigationStack {
            // Every layout, whatever the sources: a layout of lists draws any source's lists.
            HomeLayoutGallery(choices: HomeLayoutStyle.allCases, sample: .standard,
                              identifierPrefix: "homeNewSection.layout") { style in
                let editor = HomeSectionEditor(layout: HomeSectionLayout(style: style), preview: .preview(shelf: store))
                // Gutenberg's lists, chosen already where they are offered; the form can still
                // change them, to any source's. Elsewhere the form starts at 加入清單.
                if style.drawsLists, availability.isAvailable { editor.choose(.gutenbergLists) }
                self.editor = editor
                showsForm = true
            }
            .navigationTitle(localized("新增欄目"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: {
                        Label(localized("取消"), systemImage: "xmark")
                    }
                }
            }
            .navigationDestination(isPresented: $showsForm) {
                if let editor {
                    HomeSectionForm(editor: editor, isInSheet: true, added: { added(editor.draft.id) })
                }
            }
        }
    }
}

// MARK: - The form

/// What 選擇內容來源 is opened for.
private enum HomeSectionPickerMode: Hashable, Identifiable {
    /// 資料來源: the section's one list.
    case choose
    /// 加入清單: cards for a layout of lists.
    case addLists
    /// 資料來源 of a card of a layout of lists, by its place: another list in its place.
    case replaceCard(Int)

    var id: Self { self }
}

/// What the form pushes.
private enum HomeSectionFormPush: Hashable {
    /// 選擇內容來源, when the form is a sheet already on iOS 17.
    case picker(HomeSectionPickerMode)
    /// 最新's 新增來源配置.
    case latestSources
    /// The category a book source stands on in 最新, by source URL.
    case latestCategory(String)
    /// The section's category, picked again under other filters, by source URL.
    case filters(String)
    /// A card's 來源配置 category, picked again under other filters, by the card's place.
    case cardCategory(Int)
    /// 呈現方式's previews (decision 34).
    case layouts
}

/// 刪除, which leaves the page once the reader confirms. The one view of the form that leaves
/// its page itself, through `presentationMode` as `ReaderView` does, never `dismiss`: a view
/// reading `dismiss` under a form that pushes loops on iOS 17 (`HomeSectionFormHost`). A leaf,
/// so whatever it reads invalidates only itself.
private struct HomeSectionDeleteButton: View {
    let title: String
    let delete: () -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var confirms = false

    var body: some View {
        Button(localized("刪除"), role: .destructive) { confirms = true }
            .accessibilityIdentifier("homeSection.delete")
            .homeSectionDeleteConfirmation(isPresented: $confirms, title: title) {
                presentationMode.wrappedValue.dismiss()
                delete()
            }
    }
}

struct HomeSectionForm: View {
    @ObservedObject var editor: HomeSectionEditor
    /// In 新增欄目's sheet: 選擇內容來源 is pushed on iOS 17 rather than stacked (design §13.3).
    let isInSheet: Bool
    /// 新增 put the section on the home.
    var added: () -> Void = {}

    @ObservedObject private var preview: HomeModel
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @ObservedObject private var sources = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var modules: RuleModuleLibrary
    @EnvironmentObject private var store: BookStore
    /// 選擇內容來源 as a sheet.
    @State private var presentedPicker: HomeSectionPickerMode?
    /// The one page the form pushes: one item destination, as on the search page
    /// (`Technotes/iOS17SearchWatchdogPostmortem.md`, guardrail 12).
    @State private var push: HomeSectionFormPush?
    /// The card a layout of lists edits, by its place: the one picked in the preview.
    @State private var pickedCard = 0

    init(editor: HomeSectionEditor, isInSheet: Bool, modules: RuleModuleLibrary? = nil, added: @escaping () -> Void = {}) {
        self.editor = editor
        self.isInSheet = isInSheet
        self.modules = modules ?? .shared
        self.added = added
        preview = editor.preview
    }

    private var draft: HomeSectionEditor.Draft { editor.draft }

    /// What the section is called when the reader names it nothing.
    private var defaultTitle: String {
        guard let binding = draft.binding else { return localized("標題") }
        return HomeSection(layout: draft.layout, binding: binding).editorTitle()
    }

    private var title: String {
        draft.title.isEmpty ? defaultTitle : draft.title
    }

    /// The line under the name when the reader writes none: the binding's own, if it has one.
    private var defaultSubtitle: String {
        draft.binding.flatMap { HomeSection(layout: draft.layout, binding: $0).displaySubtitle } ?? localized("選填")
    }

    /// A layout of lists: the picked card's 名稱, 資料來源 and parameters in place of the
    /// section's own.
    private var drawsLists: Bool { draft.layout.style.drawsLists }

    /// 選擇內容來源 pushed rather than presented: a sheet already, on iOS 17.
    private var pushesPicker: Bool {
        if #available(iOS 18, *) { return false }
        return isInSheet
    }

    var body: some View {
        Form {
            if let page = editor.previewPage {
                // On the page's ground, not in a section's card (maintainer, 2026-11-16: 「預覽不需要
                // 用東西包起來」): the section as the home draws it.
                Section {
                    previewContent
                        .listRowInsets(EdgeInsets(top: DSSpacing.md, leading: 0, bottom: DSSpacing.md, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: {
                    Text(localized("預覽"))
                }
                // Again when 顯示在最新 changes: the preview loads 最新 without those libraries.
                .task(id: [AnyHashable(page), AnyHashable(editor.hiddenFromLatest)]) {
                    await preview.sync(with: page, hiddenFromLatest: editor.hiddenFromLatest)
                    // The reader's own tap: the page loads whatever its source's policy.
                    for row in preview.rows { preview.load(row.id) }
                }
            } else if let addListCard {
                // A layout of lists with no list yet (FB-227: 新增欄目 where Gutenberg's lists are
                // not chosen for it, as in China): no section to preview, so its one card, 加入清單.
                Section {
                    addListOnly(addListCard)
                } header: {
                    Text(localized("預覽"))
                }
            }
            Section {
                LabeledContent(localized("標題")) {
                    TextField(localized("標題"), text: Binding(get: { draft.title }, set: { editor.setTitle($0) }),
                              prompt: Text(defaultTitle))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("homeSection.title")
                }
                LabeledContent(localized("副標題")) {
                    TextField(localized("副標題"), text: Binding(get: { draft.subtitle }, set: { editor.setSubtitle($0) }),
                              prompt: Text(defaultSubtitle))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("homeSection.subtitle")
                }
                if drawsLists {
                    pickedCardNameRows
                } else {
                    layoutRows
                    sourceRow
                    if let category = filteredCategory { filtersRow(category) }
                }
            }
            .interfaceSectionSurface()
            if draft.binding == .latest {
                latestLibraries
                latestParameters
            }
            if drawsLists {
                pickedCardSections
            } else if let entry = moduleEntry, !entry.editableParams.isEmpty {
                HomeModuleParameters(entry: entry, values: draft.parameters) { editor.setParameter($0, to: $1) }
            }
            if !editor.isNew {
                Section {
                    Toggle(localized("在首頁顯示"), isOn: Binding(get: { draft.isEnabled }, set: { editor.setEnabled($0) }))
                }
                .interfaceSectionSurface()
                Section {
                    HomeSectionDeleteButton(title: title) { editor.delete() }
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(editor.isNew ? localized("新增欄目") : title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .toolbar {
            if editor.isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if editor.add() { added() }
                    } label: {
                        Label(localized("動作：新增"), systemImage: "checkmark")
                    }
                    .disabled(draft.binding == nil)
                    .accessibilityIdentifier("homeSection.add")
                }
            }
        }
        .sheet(item: $presentedPicker) { mode in
            NavigationStack { picker(mode, isPushed: false) }
                .environmentObject(store)
        }
        .navigationDestination(item: $push) { destination in
            // Without the tab bar, as the page under it (`homeEditDestinations`).
            Group {
                switch destination {
                case .picker(let mode):
                    picker(mode, isPushed: true)
                case .latestSources:
                    HomeSourceChoices(current: nil, parameters: draft.parameters) { choice in
                        pickLatest(choice)
                        push = nil
                    }
                case .latestCategory(let url):
                    if let source = sources.sources.first(where: { $0.bookSourceUrl == url }) {
                        HomeCategoryChoices(source: source, filterValues: editor.filterValues(forSourceURL: url),
                                            current: editor.latestCategories.first { $0.sourceURL == url }.map { .sourceCategories([$0]) }) { choice in
                            pickLatest(choice)
                            push = nil
                        }
                    }
                case .layouts:
                    HomeLayoutChoicePage(choices: layoutChoices, current: draft.layout, sample: .standard) { style in
                        editor.setLayout(HomeSectionLayout(style: style))
                        push = nil
                    }
                case .filters(let url):
                    if let source = sources.sources.first(where: { $0.bookSourceUrl == url }) {
                        HomeCategoryChoices(source: source, filterValues: editor.filterValues(forSourceURL: url),
                                            current: draft.binding) { choice in
                            editor.choose(choice.binding, parameters: choice.parameters, itemTitle: choice.itemTitle)
                            push = nil
                        }
                    }
                case .cardCategory(let index):
                    if editor.listCards.indices.contains(index), let category = editor.listCards[index].category,
                       let source = sources.sources.first(where: { $0.bookSourceUrl == category.sourceURL }) {
                        let card = editor.listCards[index]
                        HomeCategoryChoices(source: source,
                                            filterValues: HomeSection.filterValues(in: card.parameters, sourceURL: category.sourceURL),
                                            current: card.binding) { choice in
                            editor.replaceCard(at: index, with: .picked(choice.binding, parameters: choice.parameters,
                                                                        name: choice.itemTitle))
                            push = nil
                        }
                    }
                }
            }
            .hidesRootTabBar()
        }
    }

    /// 選擇內容來源: a sheet, or pushed when the form is a sheet already on iOS 17.
    private func openPicker(_ mode: HomeSectionPickerMode) {
        if pushesPicker { push = .picker(mode) } else { presentedPicker = mode }
    }

    private func closePicker() {
        presentedPicker = nil
        push = nil
    }

    // MARK: 最新

    /// 顯示在最新 (decision 36: Emby 4.10 sets a section's libraries in its own options). None in
    /// China without a connection saved.
    @ViewBuilder
    private var latestLibraries: some View {
        let libraries = LibraryListing.available(connections: connections.catalogs,
                                                 librariesAvailable: availability.isAvailable)
        if !libraries.isEmpty {
            Section {
                ForEach(libraries) { library in
                    Toggle(isOn: Binding(get: { editor.isShownInLatest(library.key) },
                                         set: { editor.setShownInLatest($0, for: library.key) })) {
                        SettingsRowLabel(library.name, systemImage: library.systemImage)
                    }
                    .accessibilityIdentifier("homeSection.latest.library.\(library.key.type.rawValue).\(library.key.id)")
                }
            } header: {
                Text(localized("顯示在最新"))
            } footer: {
                Text(localized("每個首頁配置的最新都用這份設定。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
    }

    /// 最新's parameters: the category each book source shows in it (design §13.3). A source
    /// with none picked has no 最新 row; the libraries' are their own.
    private var latestParameters: some View {
        Section {
            ForEach(editor.latestCategories) { reference in
                let name = HomeContentOwner.bookSource(url: reference.sourceURL).name(sources: sources, connections: connections)
                Button { push = .latestCategory(reference.sourceURL) } label: {
                    LabeledContent(name, value: reference.title)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .swipeActions {
                    Button(localized("移除"), role: .destructive) {
                        editor.setLatestCategory(nil, forSourceURL: reference.sourceURL)
                    }
                }
                .accessibilityAction(named: localized("移除")) {
                    editor.setLatestCategory(nil, forSourceURL: reference.sourceURL)
                }
                .accessibilityIdentifier("homeSection.latest.\(name)")
            }
            Button { push = .latestSources } label: {
                Label(localized("新增來源配置"), systemImage: "plus")
            }
            .accessibilityIdentifier("homeSection.latest.add")
        } header: {
            Text(localized("參數"))
        } footer: {
            Text(localized("來源配置要選一個分類代表它的最新，沒選的不會出現在最新。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func pickLatest(_ choice: HomeContentChoice) {
        guard case .sourceCategories(let references) = choice.binding, let reference = references.first else { return }
        editor.setLatestCategory(reference, filterValues: choice.filterValues, forSourceURL: reference.sourceURL)
    }

    // MARK: The picked card

    // A layout of lists edits one card at a time (maintainer, 2026-11-16, from a reference of a
    // 配置數據來源 sheet: 「清單應該是換成資料來源，切換到下一個組件用同樣的ui重新選擇來源」, in place
    // of a list of the cards): the card picked in the preview, outlined there, its name with the
    // section's, then its 資料來源, parameters and 移除. The preview's last card adds one through
    // 選擇內容來源 and picks it. A section keeps one card at least: without it, it shows nothing.

    /// The picked card's place, kept among the cards as they are removed.
    private var pickedIndex: Int {
        min(pickedCard, max(editor.listCards.count - 1, 0))
    }

    private var pickedListCard: HomeListCard? {
        editor.listCards.indices.contains(pickedIndex) ? editor.listCards[pickedIndex] : nil
    }

    /// The preview's cards that are the picked card: its row's, and a 精選書單 list's own id.
    private var pickedCollections: Set<String> {
        guard drawsLists, let card = pickedListCard else { return [] }
        var ids = Set(preview.rows.filter { $0.cardIndex == pickedIndex }.map(\.id))
        if case .gutenbergCollection(let id) = card.binding { ids.insert(id) }
        return ids
    }

    /// A card tapped in the preview: the card it is, by its row, or by a 精選書單 list's id.
    private func pick(_ collection: CollectionSummary) {
        if let index = preview.rows.first(where: { $0.id == collection.id })?.cardIndex {
            pickedCard = index
        } else if let index = editor.listCards.firstIndex(where: { $0.binding == .gutenbergCollection(id: collection.id) }) {
            pickedCard = index
        }
    }

    /// The preview's last card, 加入清單, while the section has room for one.
    private var addListCard: HomeAddListCard? {
        guard drawsLists, editor.canAddCard else { return nil }
        return HomeAddListCard { openPicker(.addLists) }
    }

    /// The picked card's name (maintainer, 2026-11-15: 「大圖卡片的分類也要可以更改名字」; empty
    /// follows its list) and 大圖卡片's photo (「分類卡的圖片可以自定義」), under the section's.
    @ViewBuilder
    private var pickedCardNameRows: some View {
        if let card = pickedListCard {
            let index = pickedIndex
            LabeledContent(localized("名稱")) {
                TextField(localized("名稱"), text: Binding(get: { card.title }, set: { editor.setCardTitle(at: index, to: $0) }),
                          prompt: Text(card.listName(modules: modules)))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("homeSection.listCard.name")
            }
            if draft.layout.style == .bannerCards, let photoID = editor.photoID(of: card) {
                HomeListCardPhotoRow(photos: editor.cardPhotos, id: photoID)
            }
        }
    }

    @ViewBuilder
    private var pickedCardSections: some View {
        if let card = pickedListCard {
            let index = pickedIndex
            Section {
                // 選擇內容來源 again, for another source's list in this card's place (maintainer,
                // 2026-11-15, on the defaults' 熱門精選: 「選不了來源啊」).
                Button { openPicker(.replaceCard(index)) } label: {
                    LabeledContent(localized("資料來源")) {
                        HStack(spacing: DSSpacing.xs) {
                            Text(cardSourceDescription(card))
                                .foregroundStyle(DSColor.textSecondary)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right")
                                .font(DSFont.footnote.weight(.semibold))
                                .foregroundStyle(DSColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(DSColor.textPrimary)
                }
                .accessibilityLabel(localized("資料來源"))
                .accessibilityValue(cardSourceDescription(card))
                .accessibilityIdentifier("homeSection.listCard.source")
                if let category = card.category {
                    Button { push = .cardCategory(index) } label: {
                        LabeledContent(localized("分類")) {
                            HStack(spacing: DSSpacing.xs) {
                                Text(category.title)
                                    .foregroundStyle(DSColor.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(DSFont.footnote.weight(.semibold))
                                    .foregroundStyle(DSColor.textTertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(DSColor.textPrimary)
                    }
                    .accessibilityLabel(localized("分類"))
                    .accessibilityValue(category.title)
                    .accessibilityIdentifier("homeSection.listCard.category")
                }
                layoutRows
            } header: {
                Text(localized("資料來源"))
            }
            .interfaceSectionSurface()
            if let entry = modules.entry(of: card.binding), !entry.editableParams.isEmpty {
                HomeModuleParameters(entry: entry, values: card.parameters) {
                    editor.setCardParameter(at: index, $0, to: $1)
                }
            }
            Section {
                Button(localized("移除"), role: .destructive) {
                    editor.removeCard(at: index)
                    pickedCard = max(index - 1, 0)
                }
                .disabled(editor.listCards.count < 2)
                .accessibilityValue(card.name(modules: modules))
                .accessibilityIdentifier("homeSection.listCard.remove")
            }
            .interfaceSectionSurface()
        }
    }

    /// 「來源 › 清單」, as the section's own 資料來源 reads.
    private func cardSourceDescription(_ card: HomeListCard) -> String {
        let source = card.sourceName(sources: sources, connections: connections, modules: modules)
        let list = card.listName(modules: modules)
        return [source, list == source ? "" : list].filter { !$0.isEmpty }.joined(separator: " › ")
    }

    // MARK: Filters

    /// The section's book source category, when it was picked under the source's filters. A
    /// layout of lists sets each card's on its page instead.
    private var filteredCategory: ExploreCategoryReference? {
        guard !drawsLists,
              case .sourceCategories(let references) = draft.binding, references.count == 1,
              let reference = references.first,
              !editor.filterValues(forSourceURL: reference.sourceURL).isEmpty else { return nil }
        return reference
    }

    /// The section's own filter values, in the order of their keys; changing one picks the
    /// category again under it, in the source's categories.
    private func filtersRow(_ category: ExploreCategoryReference) -> some View {
        let values = editor.filterValues(forSourceURL: category.sourceURL)
        let summary = values.keys.sorted().compactMap { values[$0] }.joined(separator: " · ")
        return Button { push = .filters(category.sourceURL) } label: {
            LabeledContent(localized("篩選")) {
                HStack(spacing: DSSpacing.xs) {
                    Text(summary)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(DSFont.footnote.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(DSColor.textPrimary)
        }
        .accessibilityLabel(localized("篩選"))
        .accessibilityValue(summary)
        .accessibilityIdentifier("homeSection.filters")
    }

    // MARK: Rows

    @ViewBuilder
    private var layoutRows: some View {
        if layoutChoices.count > 1 {
            Button { push = .layouts } label: {
                LabeledContent(localized("呈現方式")) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(localized(draft.layout.style.titleKey))
                            .foregroundStyle(DSColor.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(DSFont.footnote.weight(.semibold))
                            .foregroundStyle(DSColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(DSColor.textPrimary)
            }
            .accessibilityLabel(localized("呈現方式"))
            .accessibilityValue(localized(draft.layout.style.titleKey))
            .accessibilityIdentifier("homeSection.layout")
        }
    }

    private var layoutChoices: [HomeLayoutStyle] {
        draft.binding.map(HomeLayoutStyle.choices(for:)) ?? HomeLayoutStyle.allCases
    }

    private var sourceRow: some View {
        Button { openPicker(.choose) } label: {
            LabeledContent(localized("資料來源")) {
                HStack(spacing: DSSpacing.xs) {
                    Text(sourceDescription)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(DSFont.footnote.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(DSColor.textPrimary)
        }
        .accessibilityLabel(localized("資料來源"))
        .accessibilityValue(sourceDescription)
        .accessibilityIdentifier("homeSection.source")
    }

    /// 「來源 › 子項目」, as Rex's row reads; 未設定 before 選擇內容來源.
    private var sourceDescription: String {
        guard let binding = draft.binding, let owner = binding.contentOwner else { return localized("未設定") }
        // A module's list names itself; an untitled one (the defaults) has no title to fall to.
        let item = HomeSection(layout: draft.layout, binding: binding).displayTitle(sourceName: moduleEntry?.title ?? "")
        return [owner.name(sources: sources, connections: connections, modules: modules), item.isEmpty ? draft.title : item]
            .filter { !$0.isEmpty }
            .joined(separator: " › ")
    }

    @ViewBuilder
    private func picker(_ mode: HomeSectionPickerMode, isPushed: Bool) -> some View {
        switch mode {
        case .choose:
            HomeContentSourcePicker(current: draft.binding, parameters: draft.parameters, isPushed: isPushed) { choice in
                editor.choose(choice.binding, parameters: choice.parameters, itemTitle: choice.itemTitle)
                closePicker()
            } cancel: {
                closePicker()
            }
        case .addLists:
            HomeContentSourcePicker(current: nil, isPushed: isPushed, title: localized("加入清單")) { choice in
                // The card added is the one the form then edits: its name, photo and parameters
                // under the preview, as any card picked there.
                if let index = editor.addCards([.picked(choice.binding, parameters: choice.parameters, name: choice.itemTitle)]) {
                    pickedCard = index
                }
                closePicker()
            } chooseAll: { choices in
                if let index = editor.addCards(choices.map { .picked($0.binding, parameters: $0.parameters, name: $0.itemTitle) }) {
                    pickedCard = index
                }
                closePicker()
            } cancel: {
                closePicker()
            }
        case .replaceCard(let index):
            if editor.listCards.indices.contains(index) {
                let card = editor.listCards[index]
                HomeContentSourcePicker(current: card.binding, parameters: card.parameters, isPushed: isPushed) { choice in
                    editor.replaceCard(at: index, with: .picked(choice.binding, parameters: choice.parameters,
                                                                name: choice.itemTitle))
                    closePicker()
                } cancel: {
                    closePicker()
                }
            }
        }
    }

    // MARK: A module's list

    /// The module list the section shows, while its module is installed.
    private var moduleEntry: RuleModule.Entry? {
        draft.binding.flatMap { modules.entry(of: $0) }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewContent: some View {
        if draft.binding == .aiRecommendations {
            // The stored list, as the home draws it; the preview never asks the AI service.
            AIRecommendationRow(section: HomeSection(layout: draft.layout, binding: .aiRecommendations),
                                title: localized("AI 推薦"), canGenerate: false, open: { _, _ in })
        } else if drawsLists, editor.listCards.isEmpty, let addListCard {
            // A section of lists none of which this build draws: nothing to pick, so 加入清單.
            addListOnly(addListCard)
        } else if !preview.isReady {
            ProgressView().frame(maxWidth: .infinity)
        } else if let group = previewGroup, drawsLists || !group.isSettledEmpty {
            HomeRowView(group: group, content: content(of: group),
                        load: { for row in group.rows { preview.load(row.id) } },
                        request: { for row in group.rows { if case .failed = row.state { preview.request(row.id) } } },
                        open: { _, _ in }, openLocation: { _ in }, openCollection: pick)
                .environment(\.homeSelectedCollections, pickedCollections)
                .environment(\.homeAddListCard, addListCard)
        } else {
            Text(localized("此目錄沒有內容"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    /// The preview of a layout of lists with no card yet: the same 加入清單 its row ends with, alone.
    private func addListOnly(_ action: HomeAddListCard) -> some View {
        HomeAddListTile(action: action)
            .frame(height: DSLayout.homeCategoryCardHeight)
            .padding(.horizontal, DSSpacing.lg)
            .listRowInsets(EdgeInsets(top: DSSpacing.md, leading: 0, bottom: DSSpacing.md, trailing: 0))
            .listRowBackground(Color.clear)
    }

    /// The section as the home groups it; a layout of lists with every card, to be picked.
    private var previewGroup: HomeSectionGroup? {
        guard var group = preview.groups(in: nil, languages: aggregation.readingLanguages).first else { return nil }
        group.keepsEveryCard = drawsLists
        return group
    }

    private func content(of group: HomeSectionGroup) -> HomeRowContent? {
        guard case .loaded(let entries) = group.state else { return nil }
        return HomeRowContent(entries: entries, store: store, withLists: group.section.layout.style.drawsListBooks)
    }
}

// MARK: - A card of a layout of lists

/// 大圖卡片's photo for the picked card: 加入照片, or 更換照片 and 移除照片.
private struct HomeListCardPhotoRow: View {
    @ObservedObject var photos: HomeListCardPhotos
    let id: HomeListCardPhotoID

    var body: some View {
        HomePhotoPicker(photos: photos, id: id) {
            Text(localized(photos.images[id] == nil ? "加入照片" : "更換照片"))
                .font(DSFont.body)
        }
        .accessibilityIdentifier("homeSection.listCard.photo")
    }
}

private extension HomeListCard {
    /// The 來源配置 category the card shows, which can be picked again under other filters.
    var category: ExploreCategoryReference? {
        if case .sourceCategories(let references) = binding { return references.first }
        return nil
    }
}

extension HomeListCard {
    /// The card's name in its section's form: its own, else its list's (a module's with the
    /// options its values pick, as its card on the home reads).
    @MainActor
    func name(modules: RuleModuleLibrary) -> String {
        if !title.isEmpty { return title }
        var listName = ""
        if case .module(_, let entryID) = binding, let entry = modules.entry(of: binding) {
            listName = entry.cardName(entry.title ?? entryID, parameters: parameters)
        }
        return HomeSection(layout: .row, binding: binding, parameters: parameters).displayTitle(sourceName: listName)
    }

    /// Its list's name, whatever the reader named the card; a list with no name of its own (a
    /// feed) has only the card's.
    @MainActor
    func listName(modules: RuleModuleLibrary) -> String {
        guard binding.namesItsList else { return title }
        return HomeListCard(binding: binding, parameters: parameters).name(modules: modules)
    }

    /// Where the card's list is from, as 選擇內容來源 names it.
    @MainActor
    func sourceName(sources: BookSourceStore, connections: RemoteLibraryConnectionStore,
                    modules: RuleModuleLibrary) -> String {
        binding.contentOwner?.name(sources: sources, connections: connections, modules: modules) ?? ""
    }
}

extension RuleModuleLibrary {
    /// The module list `binding` shows, while its module is installed.
    func entry(of binding: HomeSectionBinding) -> RuleModule.Entry? {
        guard case .module(let moduleID, let entryID) = binding else { return nil }
        return module(id: moduleID)?.module.modules.first { $0.id == entryID }
    }
}

// MARK: - A module list's parameters

/// A module list's parameters, written by name (Phase 6f), the section's or a card's
/// (`RuleModuleParameterRows`): only those the values shown make visible (`belongTo`, 3.0.2).
private struct HomeModuleParameters: View {
    let entry: RuleModule.Entry
    let values: [String: String]
    /// A value by the parameter's name; nil goes back to the module's default.
    let set: (String, String?) -> Void
    @ObservedObject private var aggregation = AggregationSettingsStore.shared

    var body: some View {
        Section {
            let language = aggregation.readingLanguages.language
            RuleModuleParameterRows(params: entry.shownParams(in: values, language: language), values: values,
                                    current: RuleModule.Param.currentValues(of: entry.params, in: values, language: language),
                                    identifier: "homeSection.parameter", set: set)
        } header: {
            Text(localized("篩選"))
        }
        .interfaceSectionSurface()
    }
}

extension HomeContentOwner {
    /// The name 選擇內容來源 and the form's 資料來源 give it.
    @MainActor
    func name(sources: BookSourceStore, connections: RemoteLibraryConnectionStore,
              modules: RuleModuleLibrary? = nil) -> String {
        switch self {
        case .module(let id): (modules ?? .shared).installed(id: id)?.module.title ?? id
        case .appData: localized("App 資料")
        case .official: localized("官方模組")
        case .connection(let id): connections.connection(id: id)?.name ?? ""
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .bookSource(let url): sources.sources.first { $0.bookSourceUrl == url }?.bookSourceName ?? url
        }
    }
}

#Preview("新增欄目") {
    HomeNewSectionSheet()
        .environmentObject(BookStore())
}

#Preview("欄目") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .row, binding: .gutenbergCollection(id: PublicLibraryCollection.chinese.id)),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
}

#Preview("新增分類卡片，還沒有清單") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                newSectionIn: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                layout: HomeSectionLayout(style: .categoryCards), preview: .preview(shelf: BookStore())),
            isInSheet: true)
    }
    .environmentObject(BookStore())
}

#Preview("大圖卡片的清單") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .bannerCards, binding: .lists([
                    HomeListCard(binding: .gutenbergCollection(id: PublicLibraryCollection.chinese.id)),
                    HomeListCard(binding: .gutenbergShelf(id: "popular")),
                ])),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
}

#Preview("最新，顯示在最新") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .row, binding: .latest),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
}

#Preview("模組的清單") {
    let module = RuleModulePreviewData.module()
    return NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .row, title: "新書", binding: .module(moduleID: module.id, entryID: "new"),
                                     parameters: ["sort": "new"]),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false, modules: RuleModulePreviewData.listsLibrary())
    }
    .environmentObject(BookStore())
}

#Preview("分類卡片的分類") {
    let categories = ["玄幻", "都市", "仙俠"].map {
        ExploreCategoryReference(sourceURL: "https://preview.example", title: $0, url: "https://preview.example/\($0)")
    }
    return NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .categoryCards, binding: .sourceCategories(categories)),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
}

#Preview("混合來源的清單") {
    let module = RuleModulePreviewData.module()
    let cards = [
        HomeListCard(binding: .module(moduleID: module.id, entryID: "new"), parameters: ["sort": "new"]),
        HomeListCard(binding: .gutenbergShelf(id: "popular")),
        HomeListCard(binding: .sourceCategories([
            ExploreCategoryReference(sourceURL: "https://preview.example", title: "玄幻", url: "https://preview.example/玄幻"),
        ])),
        HomeListCard(binding: .continueReading),
    ]
    return NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .collageCards, binding: .lists(cards)),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false, modules: RuleModulePreviewData.listsLibrary())
    }
    .environmentObject(BookStore())
}
