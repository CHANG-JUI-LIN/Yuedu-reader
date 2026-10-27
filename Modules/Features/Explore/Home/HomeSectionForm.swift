import SwiftUI

// Unified library 5d-5: one section's form (design §13.3, Rex's 「設定資料來源」; Phase 5 plan,
// decision 23), for 新增欄目 and for a section already on the home, so there is one editor:
// - 新增欄目 asks for a layout first, then shows this form (Rex's order), in a sheet; 新增
//   puts the section at the end of the 首頁配置 shown, 取消 leaves it as it was.
// - A section's card in 編輯首頁, and 設定 in its name's long press, push the same form.
// - On top, a preview: one real page of the section in its layout, loaded as the home loads
//   it. Then 標題 and 副標題 (empty follows what it shows), 呈現方式, 資料來源 (opens 選擇內容來源),
//   and for a section on the home, 在首頁顯示 and 刪除.
// - In a layout of lists (maintainer, 2026-10-27), 清單 in place of 資料來源: the section's
//   cards, from any sources (`HomeListCards.swift`), each with a page of its own parameters;
//   加入清單 opens 選擇內容來源, where a source's 全部清單 adds every list it offers.

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
                // Gutenberg's lists, chosen already where they are offered; 清單 can still
                // change them, to any source's.
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

    var id: Self { self }
}

/// What the form pushes.
private enum HomeSectionFormPush: Hashable {
    /// 選擇內容來源, when the form is a sheet already on iOS 17.
    case picker(HomeSectionPickerMode)
    /// 最新's 新增來源配置.
    case latestSources
    /// 為你推薦's 加入分類: a source, then its category.
    case forYouSources
    /// The category a book source stands on in 最新, by source URL.
    case latestCategory(String)
    /// The section's category, picked again under other filters, by source URL.
    case filters(String)
    /// A card of a layout of lists, by its place.
    case listCard(Int)
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

    /// A layout of lists: 清單 in place of 資料來源 and its parameters.
    private var drawsLists: Bool { draft.layout.style.drawsLists }

    /// 選擇內容來源 pushed rather than presented: a sheet already, on iOS 17.
    private var pushesPicker: Bool {
        if #available(iOS 18, *) { return false }
        return isInSheet
    }

    var body: some View {
        Form {
            if let page = editor.previewPage {
                Section {
                    previewContent
                        .listRowInsets(EdgeInsets(top: DSSpacing.md, leading: 0, bottom: DSSpacing.md, trailing: 0))
                } header: {
                    Text(localized("預覽"))
                }
                .interfaceSectionSurface()
                // Again when 顯示在最新 changes: the preview loads 最新 without those libraries.
                .task(id: [AnyHashable(page), AnyHashable(editor.hiddenFromLatest)]) {
                    await preview.sync(with: page, hiddenFromLatest: editor.hiddenFromLatest)
                    // The reader's own tap: the page loads whatever its source's policy.
                    for row in preview.rows { preview.load(row.id) }
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
                layoutRows
                if !drawsLists {
                    sourceRow
                    if let category = filteredCategory { filtersRow(category) }
                }
            }
            .interfaceSectionSurface()
            if draft.binding == .latest {
                latestLibraries
                latestParameters
            }
            if draft.binding == .forYou {
                forYouCategories
            }
            if drawsLists {
                listCardsSection
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
                case .forYouSources:
                    HomeSourceChoices(current: nil) { choice in
                        if case .sourceCategories(let references) = choice.binding, let reference = references.first {
                            editor.addForYouCategory(reference)
                        }
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
                        editor.setLayout(HomeSectionLayout(style: style, ranked: draft.layout.showsRanks))
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
                case .listCard(let index):
                    HomeListCardPage(editor: editor, index: index, modules: modules) {
                        push = nil
                        editor.removeCard(at: index)
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

    // MARK: 為你推薦

    /// 為你推薦's 來源分類 (Discovery Phase 7a-4, maintainer's decision 1): the home's categories
    /// and its own, each removable; 加入分類 adds one from any source.
    private var forYouCategories: some View {
        Section {
            ForEach(editor.forYouCategories) { reference in
                let name = HomeContentOwner.bookSource(url: reference.sourceURL).name(sources: sources, connections: connections)
                LabeledContent(name, value: reference.title)
                    .swipeActions {
                        Button(localized("移除"), role: .destructive) { editor.removeForYouCategory(reference) }
                    }
                    .accessibilityAction(named: localized("移除")) { editor.removeForYouCategory(reference) }
                    .accessibilityIdentifier("homeSection.forYou.\(name).\(reference.title)")
            }
            Button { push = .forYouSources } label: {
                Label(localized("加入分類"), systemImage: "plus")
            }
            .accessibilityIdentifier("homeSection.forYou.add")
        } header: {
            Text(localized("來源分類"))
        } footer: {
            Text(localized("首頁上的分類都會列在這裡；移除只影響為你推薦。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func pickLatest(_ choice: HomeContentChoice) {
        guard case .sourceCategories(let references) = choice.binding, let reference = references.first else { return }
        editor.setLatestCategory(reference, filterValues: choice.filterValues, forSourceURL: reference.sourceURL)
    }

    // MARK: 清單

    /// The section's lists in a layout of lists (maintainer, 2026-10-27): a card each, in this
    /// order, from any sources. A card opens its own page; 加入清單 opens 選擇內容來源, up to
    /// `HomeSection.listCardLimit`. The last card stays: without it the section shows nothing.
    private var listCardsSection: some View {
        let cards = editor.listCards
        return Section {
            ForEach(Array(cards.enumerated()), id: \.element) { index, card in
                listCardRow(card, at: index, count: cards.count)
            }
            .onMove { editor.moveCards(fromOffsets: $0, toOffset: $1) }
            Button { openPicker(.addLists) } label: {
                Label(localized("加入清單"), systemImage: "plus")
            }
            .disabled(!editor.canAddCard)
            .accessibilityIdentifier("homeSection.lists.add")
        } header: {
            Text(localized("清單"))
        } footer: {
            Text(String(format: localized("每個清單一張卡片，最多 %d 張，可以混合不同來源。"), HomeSection.listCardLimit))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func listCardRow(_ card: HomeListCard, at index: Int, count: Int) -> some View {
        let source = card.sourceName(sources: sources, connections: connections, modules: modules)
        return Button { push = .listCard(index) } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(card.name(modules: modules))
                        .foregroundStyle(DSColor.textPrimary)
                    if !source.isEmpty {
                        Text(source)
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .swipeActions {
            if count > 1 {
                Button(localized("移除"), role: .destructive) { editor.removeCard(at: index) }
            }
        }
        .accessibilityActions {
            if index > 0 {
                Button(localized("上移")) { editor.moveCards(fromOffsets: [index], toOffset: index - 1) }
            }
            if index < count - 1 {
                Button(localized("下移")) { editor.moveCards(fromOffsets: [index], toOffset: index + 2) }
            }
            if count > 1 {
                Button(localized("移除")) { editor.removeCard(at: index) }
            }
        }
        .accessibilityIdentifier("homeSection.listCard.\(index)")
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
        if draft.layout.style.canShowRanks {
            Toggle(localized("顯示排名"), isOn: Binding(
                get: { draft.layout.showsRanks },
                set: { editor.setLayout(HomeSectionLayout(style: draft.layout.style, ranked: $0)) }))
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
                editor.addCards([.picked(choice.binding, parameters: choice.parameters, name: choice.itemTitle)])
                closePicker()
            } chooseAll: { choices in
                editor.addCards(choices.map { .picked($0.binding, parameters: $0.parameters, name: $0.itemTitle) })
                closePicker()
            } cancel: {
                closePicker()
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
        } else if !preview.isReady {
            ProgressView().frame(maxWidth: .infinity)
        } else if let group = preview.groups(in: nil, languages: aggregation.readingLanguages).first,
                  !group.isSettledEmpty {
            HomeRowView(group: group, content: content(of: group),
                        load: { for row in group.rows { preview.load(row.id) } },
                        request: { for row in group.rows { if case .failed = row.state { preview.request(row.id) } } },
                        open: { _, _ in }, openLocation: { _ in })
        } else {
            Text(localized("此目錄沒有內容"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func content(of group: HomeSectionGroup) -> HomeRowContent? {
        guard case .loaded(let entries) = group.state else { return nil }
        return HomeRowContent(entries: entries, store: store)
    }
}

// MARK: - A card of a layout of lists

/// One card of a section of lists: where its list is from, its own parameters (趨勢's 地區,
/// maintainer 2026-10-27), a 來源配置's category picked again under other filters, and 移除.
private struct HomeListCardPage: View {
    @ObservedObject var editor: HomeSectionEditor
    let index: Int
    @ObservedObject var modules: RuleModuleLibrary
    /// 移除, which leaves the page.
    let remove: () -> Void
    @ObservedObject private var sources = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @State private var picksCategory = false

    private var card: HomeListCard? {
        editor.listCards.indices.contains(index) ? editor.listCards[index] : nil
    }

    private var category: ExploreCategoryReference? {
        if case .sourceCategories(let references) = card?.binding { return references.first }
        return nil
    }

    var body: some View {
        if let card {
            Form {
                Section {
                    LabeledContent(localized("來源"), value: card.sourceName(sources: sources, connections: connections, modules: modules))
                    if let category {
                        Button { picksCategory = true } label: {
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
                    } else {
                        LabeledContent(localized("清單"), value: card.name(modules: modules))
                    }
                }
                .interfaceSectionSurface()
                if let entry = modules.entry(of: card.binding), !entry.editableParams.isEmpty {
                    HomeModuleParameters(entry: entry, values: card.parameters) {
                        editor.setCardParameter(at: index, $0, to: $1)
                    }
                }
                Section {
                    Button(localized("移除"), role: .destructive, action: remove)
                        .disabled(editor.listCards.count < 2)
                        .accessibilityIdentifier("homeSection.listCard.remove")
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(card.name(modules: modules))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .explore)
            .navigationDestination(isPresented: $picksCategory) {
                if let category, let source = sources.sources.first(where: { $0.bookSourceUrl == category.sourceURL }) {
                    HomeCategoryChoices(source: source,
                                        filterValues: HomeSection.filterValues(in: card.parameters, sourceURL: category.sourceURL),
                                        current: card.binding) { choice in
                        editor.replaceCard(at: index, with: .picked(choice.binding, parameters: choice.parameters,
                                                                    name: choice.itemTitle))
                        picksCategory = false
                    }
                    .hidesRootTabBar()
                }
            }
        } else {
            // Removed: the page empties as it pops.
            Color.clear.themedAppSurface(for: .explore)
        }
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

/// A module list's parameters, written by name (Phase 6f), the section's or a card's: a choice
/// is a `Picker`, a count a `Stepper`, typed text is kept once the reader is done with it. A
/// choice that follows 中繼資料語言偏好推薦 offers that first, and picking it again clears the
/// reader's own.
private struct HomeModuleParameters: View {
    let entry: RuleModule.Entry
    let values: [String: String]
    /// A value by the parameter's name; nil goes back to the module's default.
    let set: (String, String?) -> Void
    @ObservedObject private var aggregation = AggregationSettingsStore.shared

    /// The picker's tag for following 中繼資料語言偏好推薦: no option's value.
    private static let followsLanguageTag = "\u{1F}followsLanguage"

    var body: some View {
        Section {
            ForEach(entry.editableParams, id: \.name) { param in
                let title = param.title ?? param.name
                let value = param.currentValue(in: values, language: aggregation.readingLanguages.language)
                switch param.kind {
                case .enumeration:
                    let follows = param.followsLanguage == true
                    let selection = follows && values[param.name] == nil ? Self.followsLanguageTag : value
                    Picker(title, selection: Binding(get: { selection }, set: { picked in
                        set(param.name, picked == Self.followsLanguageTag ? nil : picked)
                    })) {
                        if follows {
                            Text(localized("跟隨中繼資料語言偏好推薦")).tag(Self.followsLanguageTag)
                        }
                        ForEach(param.enumOptions ?? [], id: \.value) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .accessibilityIdentifier("homeSection.parameter.\(param.name)")
                case .count:
                    let count = Int(value) ?? 1
                    Stepper(value: Binding(get: { count }, set: { set(param.name, String($0)) }),
                            in: 1...max(100, count)) {
                        LabeledContent(title, value: String(count))
                    }
                    .accessibilityValue(String(count))
                    .accessibilityIdentifier("homeSection.parameter.\(param.name)")
                default:
                    HomeModuleTextParameter(title: title, committed: value) { set(param.name, $0) }
                        .accessibilityIdentifier("homeSection.parameter.\(param.name)")
                }
            }
        } header: {
            Text(localized("篩選"))
        }
        .interfaceSectionSurface()
    }
}

/// A module list's `input` parameter. Kept on submit or when the field loses focus, never on
/// each keystroke: every value written reloads the preview with a real request.
private struct HomeModuleTextParameter: View {
    let title: String
    let committed: String
    let commit: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
        }
        .onAppear { text = committed }
        .onChange(of: committed) { _, value in if !focused { text = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        guard text != committed else { return }
        commit(text.isEmpty ? nil : text)
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

#Preview("為你推薦") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .row, binding: .forYou),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
}

#Preview("為你推薦，大字") {
    NavigationStack {
        HomeSectionForm(
            editor: HomeSectionEditor(
                section: HomeSection(layout: .row, binding: .forYou),
                store: HomePageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-home.json")),
                preview: .preview(shelf: BookStore())),
            isInSheet: false)
    }
    .environmentObject(BookStore())
    .dynamicTypeSize(.accessibility3)
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
