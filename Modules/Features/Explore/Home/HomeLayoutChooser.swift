import SwiftUI

// Phase 5 plan, decision 34 (the maintainer, with Emby's 選擇模板): choosing a section's layout
// shows what each one looks like. Each choice is the layout's name, plain, over a live
// preview: the real layout drawn small with a sample of classics with fine covers. In 新增欄目's
// first page and behind the form's 呈現方式.

/// The books and lists a preview is drawn with: classics whose covers the app carries, so
/// every preview looks its best offline and wherever the public libraries are not offered.
/// The covers are Gutenberg's own, in `Resources/Assets/layout-sample-<id>.jpg`.
struct HomeLayoutSample {
    var cards: [HomeCardContent]
    var collections: [CollectionSummary]

    /// Real Gutenberg books, as their pages name them, with covers of different colours.
    static let books: [GutenbergBook] = [
        .init(id: 64317, title: "The Great Gatsby", author: "F. Scott Fitzgerald", language: "en"),
        .init(id: 1342, title: "Pride and Prejudice", author: "Jane Austen", language: "en"),
        .init(id: 11, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll", language: "en"),
        .init(id: 120, title: "Treasure Island", author: "Robert Louis Stevenson", language: "en"),
        .init(id: 174, title: "The Picture of Dorian Gray", author: "Oscar Wilde", language: "en"),
        .init(id: 158, title: "Emma", author: "Jane Austen", language: "en"),
        .init(id: 55, title: "The Wonderful Wizard of Oz", author: "L. Frank Baum", language: "en"),
        .init(id: 16, title: "Peter Pan", author: "J. M. Barrie", language: "en"),
    ]

    /// 專題集合's sample: the two bundled lists whose first books are these classics.
    static let lists: [PublicLibraryCollection] = [.fiction, .children]

    @MainActor
    static var standard: HomeLayoutSample {
        let entries = books.map { withBundledCover(.bundledGutenberg($0), of: $0) }
        return HomeLayoutSample(
            cards: entries.compactMap { HomeCardContent($0, status: { _ in nil }, shelfBooks: [:]) },
            collections: lists.map { list in
                let books = list.books.compactMap { book -> WorkSummary? in
                    guard case .item(_, let summary, _) = withBundledCover(.bundledGutenberg(book), of: book) else { return nil }
                    return summary
                }
                return CollectionSummary(id: list.id, title: localized(list.titleKey), books: books,
                                         languages: list.books.compactMap(\.language),
                                         opening: .gutenbergCollection(id: list.id))
            })
    }

    /// The bundled cover of a sample book, `layout-sample-<Gutenberg number>.jpg`. A missing
    /// file is a packaging bug, logged, and the book keeps the cover it had
    /// (`LayoutPreviewTests` checks every file is there).
    static func bundledCover(of book: GutenbergBook) -> CoverReference? {
        guard let number = ExternalIdentifier.gutenbergNumber(from: book.id),
              let path = Bundle.main.path(forResource: "layout-sample-\(number)", ofType: "jpg") else {
            AppLogger.error("Layout sample cover missing from the app bundle", context: ["book": book.id])
            return nil
        }
        return .copyFile(path)
    }

    private static func withBundledCover(_ entry: CollectionEntry, of book: GutenbergBook) -> CollectionEntry {
        guard case .item(let record, var summary, let opening) = entry else { return entry }
        summary.cover = bundledCover(of: book) ?? summary.cover
        return .item(record, summary, opening)
    }
}

/// One row per layout: its name, a checkmark on the current one, and its preview. Rows of a
/// `List` section, so 新增欄目 and the form's page lay them out alike.
struct HomeLayoutChoiceRows: View {
    let choices: [HomeLayoutStyle]
    var current: HomeSectionLayout?
    let sample: HomeLayoutSample
    /// The rows' accessibility identifiers, `<prefix>.<layout>`.
    let identifierPrefix: String
    let choose: (HomeLayoutStyle) -> Void

    var body: some View {
        ForEach(choices) { style in
            let isCurrent = current?.style == style
            Button { choose(style) } label: {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    HStack(spacing: DSSpacing.sm) {
                        Text(localized(style.titleKey))
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer(minLength: DSSpacing.sm)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(DSFont.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    // The current layout as set (圖文資訊清單 with or without ranks).
                    HomeLayoutPreview(layout: current.flatMap { $0.style == style ? $0 : nil } ?? HomeSectionLayout(style: style),
                                      sample: sample)
                }
                .padding(.vertical, DSSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The name is the choice; the preview shows it and is not read.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localized(style.titleKey))
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("\(identifierPrefix).\(style.rawValue)")
        }
    }
}

/// A layout drawn small: the real layout at a phone's width, scaled down into a short frame and
/// cut off below, so each shows its own shape. Nothing in it can be touched or read.
struct HomeLayoutPreview: View {
    let layout: HomeSectionLayout
    let sample: HomeLayoutSample

    var body: some View {
        GeometryReader { proxy in
            let scale = DSLayout.homeLayoutPreviewScale
            content
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .frame(height: DSLayout.homeLayoutPreviewHeight)
        .clipped()
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if layout.style == .collection {
            HomeCollectionCards(collections: sample.collections, open: { _ in })
        } else if sample.cards.isEmpty {
            HomeSectionCards(layout: layout, cards: (0..<6).map(HomeCardContent.placeholder),
                             rowID: "layoutPreview.\(layout.rawValue)", hasShowAll: false, open: { _, _ in })
                .redacted(reason: .placeholder)
        } else {
            HomeSectionCards(layout: layout, cards: sample.cards, rowID: "layoutPreview.\(layout.rawValue)",
                             hasShowAll: false, open: { _, _ in })
        }
    }
}

/// The form's 呈現方式, pushed.
struct HomeLayoutChoicePage: View {
    let choices: [HomeLayoutStyle]
    let current: HomeSectionLayout
    let sample: HomeLayoutSample
    let choose: (HomeLayoutStyle) -> Void

    var body: some View {
        List {
            Section {
                HomeLayoutChoiceRows(choices: choices, current: current, sample: sample,
                                     identifierPrefix: "homeSection.layoutChoice", choose: choose)
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("呈現方式"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

#if DEBUG
#Preview("呈現方式，即時預覽") {
    NavigationStack {
        HomeLayoutChoicePage(choices: HomeLayoutStyle.allCases, current: .featured,
                             sample: .standard, choose: { _ in })
    }
}

#Preview("呈現方式，沒有書時") {
    NavigationStack {
        HomeLayoutChoicePage(choices: HomeLayoutStyle.choices(for: .latest), current: .row,
                             sample: HomeLayoutSample(cards: [], collections: []), choose: { _ in })
    }
}
#endif
