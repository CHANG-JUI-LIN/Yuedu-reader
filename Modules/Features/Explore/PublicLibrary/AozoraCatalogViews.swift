import SwiftUI

// Catalog values are snapshots: pushed pages do not re-read the live store.
enum AozoraBrowseMode: String, CaseIterable, Identifiable {
    case newest, authors, titles, categories
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .newest: "新着作品"
        case .authors: "作家別"
        case .titles: "作品名別"
        case .categories: "分類別"
        }
    }
    var symbol: String {
        switch self {
        case .newest: "clock"
        case .authors: "person"
        case .titles: "textformat.abc"
        case .categories: "books.vertical"
        }
    }
}

struct AozoraCatalogView: View {
    let index: AozoraCatalogIndex
    let mode: AozoraBrowseMode
    @State private var selection: PublicLibraryBookSelection?
    private var groups: [AozoraIndexGroup] {
        switch mode {
        case .authors: index.authorGroups
        case .titles: index.titleGroups
        case .categories: index.classificationGroups
        case .newest: []
        }
    }
    var body: some View {
        Group {
            if mode == .newest {
                AozoraWorksView(index: index, works: index.newWorks, title: localized(mode.titleKey))
            } else {
                AozoraIndexedList(groups: groups, select: mode == .authors ? nil : { id in
                    let books = groups.flatMap(\.ids).compactMap { index.worksByID[$0] }.map { PublicLibraryBook.aozora($0, index) }
                    selection = PublicLibraryBookSelection(books: books, selectedID: "aozora:" + id)
                }) { id in
                    if mode == .authors, let person = index.personsByID[id] {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(person.name).foregroundStyle(DSColor.textPrimary)
                            Text(person.yomi).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }.accessibilityElement(children: .combine)
                    } else if let work = index.worksByID[id] {
                        AozoraWorkRow(work: work, index: index)
                    }
                } destination: { id in
                    if mode == .authors, let person = index.personsByID[id] {
                        AozoraWorksView(index: index, works: index.works(forPerson: id), title: person.name)
                    } else if let work = index.worksByID[id] {
                        AozoraWorkDetailView(work: work, index: index)
                    }
                }
                .overlay {
                    if groups.isEmpty { ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical") }
                }
                .navigationTitle(localized(mode.titleKey))
                .toolbarTitleDisplayMode(.inline)
                .themedAppSurface(for: .explore)
            }
        }
        .sheet(item: $selection) { PublicLibraryBookSheet(selection: $0) }
    }
}

struct AozoraWorksView: View {
    let index: AozoraCatalogIndex
    let works: [AozoraWork]
    let title: String
    @State private var selection: PublicLibraryBookSelection?
    var body: some View {
        ScrollView {
            PublicLibraryBooksGrid(books: works.map { .aozora($0, index) }) { selection = $0 }
        }
        .overlay {
            if works.isEmpty { ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical") }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .sheet(item: $selection) { PublicLibraryBookSheet(selection: $0) }
    }
}

struct AozoraWorkRow: View {
    let work: AozoraWork
    let index: AozoraCatalogIndex
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(work.title).foregroundStyle(DSColor.textPrimary)
            Text(work.credits.compactMap { index.personsByID[$0.person]?.name }.joined(separator: "、"))
                .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
        }.accessibilityElement(children: .combine)
    }
}

struct AozoraWorkDetailView: View {
    let work: AozoraWork
    let index: AozoraCatalogIndex
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.publicLibrarySheet) private var sheet
    @State private var action: Task<Void, Never>?
    @State private var message: String?
    @State private var failed = false
    @State private var opensAfterImport = false
    @State private var readerBookID: UUID?
    private var shelfBook: ReadingBook? { store.books.first { $0.aozora?.catalogWorkID == work.id } }
    private var author: String { work.credits.compactMap { index.personsByID[$0.person]?.name }.joined(separator: "、") }
    private var readAction: BookDetailAction {
        BookDetailAction(title: localized(shelfBook == nil ? "開始閱讀" : "開啟"), systemImage: "book",
            isBusy: action != nil, isEnabled: action == nil, action: {
                if let book = shelfBook { openReader(book.id) }
                else { addToShelf(openAfterImport: true) }
            })
    }

    var body: some View {
        if sheet != nil { detailContent }
        else {
            detailContent.navigationDestination(item: $readerBookID) { id in
                BookReaderView(bookId: id).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            }
        }
    }

    private var detailContent: some View {
        BookDetailScaffold(title: work.title, compactAction: readAction) {
            BookDetailHero(artworkShape: .book, cover: GeneratedBookCover(title: work.title, author: author),
                title: work.title, author: author, meta: localized("青空文庫"), primary: readAction,
                secondary: BookDetailAction(title: localized(shelfBook == nil ? "加入書架" : "已加入書架"),
                    systemImage: shelfBook == nil ? "plus" : "checkmark", isBusy: action != nil,
                    isEnabled: action == nil && shelfBook == nil, action: { addToShelf() }),
                authorActions: work.credits.compactMap { credit in
                    guard let person = index.personsByID[credit.person] else { return nil }
                    return BookDetailAuthorAction(id: person.id + credit.role, name: person.name,
                        action: { sheet?.openAuthor(.aozora(person, index)) })
                }, artworkHeight: sheet?.artworkHeight)
        } content: {
            BookDetailInfoStrip(items: [
                BookDetailInfoItem(id: "published", label: localized("公開日"), value: work.published),
                BookDetailInfoItem(id: "kana", label: localized("文字遣い種別"), value: work.kanaStyle),
            ])
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                if action != nil {
                    ProgressView(localized("正在加入書架"))
                    Button(localized("取消"), role: .cancel) { action?.cancel() }
                }
                if let message {
                    Text(message).foregroundStyle(failed ? DSColor.destructive : DSColor.textSecondary)
                }
                if failed { Button(localized("重試")) { addToShelf(openAfterImport: opensAfterImport) } }
                if !work.yomi.isEmpty { Text(work.yomi).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary) }
                ForEach(Array(work.credits.enumerated()), id: \.offset) { _, credit in
                    if let person = index.personsByID[credit.person] {
                        ThemedLabeledContent(localized(credit.role), value: person.name)
                    }
                }
                if !work.subtitle.isEmpty { Text(work.subtitle).font(DSFont.body).foregroundStyle(DSColor.textPrimary) }
                if !work.source.isEmpty { ThemedLabeledContent(localized("底本"), value: work.source) }
                if !work.sourcePublisher.isEmpty { ThemedLabeledContent(localized("出版社"), value: work.sourcePublisher) }
                if let url = URL(string: work.card), url.scheme == "https", url.host == "www.aozora.gr.jp" {
                    Link(localized("在青空文庫網站查看"), destination: url)
                }
            }.padding(.horizontal, DSSpacing.lg)
        }
        .onDisappear { action?.cancel() }
    }

    private func openReader(_ id: UUID) {
        if let sheet { sheet.openReader(id) }
        else { readerBookID = id }
    }

    private func addToShelf(openAfterImport: Bool = false) {
        guard action == nil else { return }
        opensAfterImport = openAfterImport
        failed = false
        message = nil
        action = Task { @MainActor in
            do {
                let book = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
                try Task.checkCancellation()
                message = localized("已加入書架")
                if openAfterImport { openReader(book.id) }
            } catch is CancellationError {
                message = localized("已取消")
            } catch {
                failed = true
                message = error.localizedDescription
            }
            action = nil
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }
}

/// iOS 26 exposes the native List index. Older systems use UITableView's native
/// section index, not a gesture overlay. Remove the UIKit branch at iOS 26 minimum.
private struct AozoraIndexedList<Row: View, Destination: View>: View {
    let groups: [AozoraIndexGroup]
    var select: ((String) -> Void)? = nil
    @ViewBuilder let row: (String) -> Row
    @ViewBuilder let destination: (String) -> Destination
    @State private var selectedID: String?
    var body: some View {
        if #available(iOS 26, *) {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.ids, id: \.self) { id in
                            if let select {
                                Button { select(id) } label: { row(id) }
                            } else {
                                NavigationLink { destination(id) } label: { row(id) }
                            }
                        }
                    } header: { Text(group.displayTitle) }
                    .interfaceSectionSurface()
                    .sectionIndexLabel(group.indexTitle)
                }
            }.listSectionIndexVisibility(.visible)
        } else {
            AozoraIndexedTable(groups: groups, row: row, select: { id in
                if let select { select(id) } else { selectedID = id }
            })
                .navigationDestination(item: $selectedID, destination: destination)
        }
    }
}

private extension AozoraIndexGroup {
    var displayTitle: String { id.count == 1 ? id : localized(titleKey) }
    var indexTitle: String { id == "latin" ? "A" : id == "other" ? "#" : id }
}

private struct AozoraIndexedTable<Row: View>: UIViewRepresentable {
    let groups: [AozoraIndexGroup]
    let row: (String) -> Row
    let select: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.backgroundColor = .clear
        table.sectionIndexBackgroundColor = .clear
        table.sectionIndexColor = UIColor(DSColor.accent)
        table.rowHeight = UITableView.automaticDimension
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.parent = self
        table.reloadData()
    }
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: AozoraIndexedTable
        init(_ parent: AozoraIndexedTable) { self.parent = parent }
        func numberOfSections(in tableView: UITableView) -> Int { parent.groups.count }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { parent.groups[section].ids.count }
        func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { parent.groups[section].displayTitle }
        func sectionIndexTitles(for tableView: UITableView) -> [String]? { parent.groups.map(\.indexTitle) }
        func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int { index }
        func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "work") ?? UITableViewCell(style: .default, reuseIdentifier: "work")
            let id = parent.groups[path.section].ids[path.row]
            cell.contentConfiguration = UIHostingConfiguration { parent.row(id) }
            cell.backgroundColor = UIColor(DSColor.surface)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
            tableView.deselectRow(at: path, animated: true)
            parent.select(parent.groups[path.section].ids[path.row])
        }
    }
}

extension AozoraCatalogIndex {
    static var preview: Self {
        let person = AozoraPerson(id: "1", name: "夏目 漱石", yomi: "なつめ そうせき", sortYomi: "なつめそうせき", born: "1867-02-09", died: "1916-12-09")
        let work = AozoraWork(id: "1", title: "吾輩は猫である", yomi: "わがはいはねこである", sortYomi: "わかはいはねこてある", subtitle: "", kanaStyle: "新字新仮名", ndc: "NDC 913", published: "2000-01-01", updated: "2000-01-01", card: "https://www.aozora.gr.jp/", text: "https://www.aozora.gr.jp/preview.zip", textUpdated: "2000-01-01", credits: [.init(person: "1", role: "著者")], source: "夏目漱石全集", sourcePublisher: "")
        return Self(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: [work]))
    }
}

#Preview("Aozora authors") { NavigationStack { AozoraCatalogView(index: .preview, mode: .authors) }.environmentObject(BookStore()) }
#Preview("Aozora works") { NavigationStack { AozoraWorksView(index: .preview, works: AozoraCatalogIndex.preview.newWorks, title: localized("新着作品")) }.environmentObject(BookStore()) }
#Preview("Aozora work") { NavigationStack { AozoraWorkDetailView(work: AozoraCatalogIndex.preview.newWorks[0], index: .preview) }.environmentObject(BookStore()) }
#Preview("Aozora row") { List { AozoraWorkRow(work: AozoraCatalogIndex.preview.newWorks[0], index: .preview) } }
#Preview("Aozora legacy index") {
    AozoraIndexedTable(groups: AozoraCatalogIndex.preview.titleGroups, row: { id in
        Text(AozoraCatalogIndex.preview.worksByID[id]?.title ?? "")
    }, select: { _ in })
}
