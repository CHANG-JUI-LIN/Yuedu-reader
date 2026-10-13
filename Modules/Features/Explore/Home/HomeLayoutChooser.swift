import SwiftUI

// Phase 5 plan, decision 34 (the maintainer, with Emby's 選擇模板): choosing a section's layout
// shows what each one looks like. Each choice is the layout's name, plain, over a live
// preview: the real layout drawn small with books whose covers suit it. In 新增欄目's first
// page and behind the form's 呈現方式.
//
// The maintainer, 2026-10-13: each layout gets the covers that suit it best, no book in two
// layouts, and not only Gutenberg's. Painted covers for 精選 and 大型閱讀卡片, comic books for
// 多行橫向輪播, illustrated and comic magazines for 固定封面網格, Japanese and Chinese first
// editions for 精簡閱讀卡片 and 圖文資訊清單, and two lists, 漫畫 and 東方經典, for 專題集合.

/// One book a preview is drawn with: its cover, bundled as `layout-sample-<cover>.jpg`, and its
/// title and author as its edition has them. Every cover is in the public domain worldwide:
/// Standard Ebooks' (CC0), or a scan on Wikimedia Commons of a work whose artist died before
/// 1956 or is unknown and published before 1900 (Technotes/LayoutSampleCovers.md lists each).
struct HomeLayoutSampleBook: Hashable {
    let cover: String
    let title: String
    let author: String
    var language: String
    var kind: ContentKind = .text
}

/// The books and lists the previews are drawn with, carried by the app so every preview looks
/// its best offline.
struct HomeLayoutSample {
    /// Each layout's own cards; a layout with none draws placeholders.
    var cards: [HomeLayoutStyle: [HomeCardContent]]
    var collections: [CollectionSummary]

    func cards(for style: HomeLayoutStyle) -> [HomeCardContent] {
        cards[style] ?? []
    }

    /// Each layout's books, as many as its preview shows on a phone. No book is in two layouts
    /// or in a list (`LayoutPreviewTests`).
    static let books: [HomeLayoutStyle: [HomeLayoutSampleBook]] = [
        .featured: [
            .init(cover: "pride-and-prejudice", title: "Pride and Prejudice", author: "Jane Austen", language: "en"),
            .init(cover: "the-odyssey", title: "The Odyssey", author: "Homer", language: "en"),
            .init(cover: "dorian-gray", title: "The Picture of Dorian Gray", author: "Oscar Wilde", language: "en"),
        ],
        .readingCard: [
            .init(cover: "wuthering-heights", title: "Wuthering Heights", author: "Emily Brontë", language: "en"),
            .init(cover: "treasure-island", title: "Treasure Island", author: "Robert Louis Stevenson", language: "en"),
            .init(cover: "alice", title: "Alice's Adventures in Wonderland", author: "Lewis Carroll", language: "en"),
        ],
        .row: [
            .init(cover: "moby-dick", title: "Moby Dick", author: "Herman Melville", language: "en"),
            .init(cover: "dracula", title: "Dracula", author: "Bram Stoker", language: "en"),
            .init(cover: "jane-eyre", title: "Jane Eyre", author: "Charlotte Brontë", language: "en"),
            .init(cover: "monte-cristo", title: "The Count of Monte Cristo", author: "Alexandre Dumas", language: "en"),
            .init(cover: "frankenstein", title: "Frankenstein", author: "Mary Shelley", language: "en"),
            .init(cover: "war-and-peace", title: "War and Peace", author: "Leo Tolstoy", language: "en"),
        ],
        .compactReadingCard: [
            .init(cover: "seito", title: "青鞜", author: "長沼智恵子", language: "ja"),
            .init(cover: "myojo", title: "明星", author: "藤島武二", language: "ja"),
            .init(cover: "yoimachigusa", title: "宵待草", author: "竹久夢二", language: "ja"),
        ],
        .list: [
            .init(cover: "aiaigasa", title: "相合傘", author: "泉鏡花", language: "ja"),
            .init(cover: "uzurakago", title: "鶉籠", author: "夏目漱石", language: "ja"),
            .init(cover: "wagahai", title: "吾輩ハ猫デアル", author: "夏目漱石", language: "ja"),
        ],
        .multiRow: [
            .init(cover: "little-nemo", title: "Little Nemo in Slumberland", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "becassine", title: "Bécassine chez les Alliés", author: "Caumery, J.-P. Pinchon", language: "fr", kind: .comic),
            .init(cover: "rarebit-fiend", title: "Dreams of the Rarebit Fiend", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "fenouillard", title: "La Famille Fenouillard", author: "Christophe", language: "fr", kind: .comic),
            .init(cover: "yellow-kid", title: "The Yellow Kid", author: "R. F. Outcault", language: "en", kind: .comic),
            .init(cover: "tintin-lutin", title: "Tintin-Lutin", author: "Benjamin Rabier, Fred Isly", language: "fr", kind: .comic),
            .init(cover: "mutt-and-jeff", title: "Mutt and Jeff", author: "Bud Fisher", language: "en", kind: .comic),
            .init(cover: "sammy-sneeze", title: "Little Sammy Sneeze", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "my-resolutions", title: "My Resolutions", author: "R. F. Outcault", language: "en", kind: .comic),
            .init(cover: "upside-downs", title: "The Upside Downs", author: "Gustave Verbeek", language: "en", kind: .comic),
            .init(cover: "tige", title: "Tige: His Story", author: "R. F. Outcault", language: "en", kind: .comic),
            .init(cover: "buster-brown", title: "Buster Brown", author: "R. F. Outcault", language: "en", kind: .comic),
        ],
        .coverGrid: [
            .init(cover: "jugend-1896-12", title: "Jugend, 1896 Nr. 12", author: "Ludwig von Zumbusch", language: "de"),
            .init(cover: "life-1909", title: "Life, August 19, 1909", author: "Coles Phillips", language: "en"),
            .init(cover: "tokyo-puck-1909", title: "東京パック 1909年2月", author: "北沢楽天", language: "ja"),
            .init(cover: "punch-1872", title: "Punch, 27 April 1872", author: "Richard Doyle", language: "en"),
            .init(cover: "hototogisu-1908", title: "ホトトギス 1908年1月", author: "高浜虚子", language: "ja"),
            .init(cover: "simplicissimus-1913", title: "Simplicissimus, Badenummer 1913", author: "Brynolf Wennerberg", language: "de"),
            .init(cover: "ally-sloper-1892", title: "Ally Sloper's Half Holiday, 1 October 1892", author: "W. Fletcher Thomas", language: "en"),
            .init(cover: "good-housekeeping-1915", title: "Good Housekeeping, February 1915", author: "Coles Phillips", language: "en"),
            .init(cover: "jugend-1896-31", title: "Jugend, 1896 Nr. 31", author: "Fritz Erler", language: "de"),
            .init(cover: "hototogisu-1907", title: "ホトトギス 1907年7月", author: "高浜虚子", language: "ja"),
            .init(cover: "comic-cuts-1890", title: "Comic Cuts, No. 1, 1890", author: "", language: "en"),
            .init(cover: "life-1921", title: "Life, March 3, 1921", author: "Coles Phillips", language: "en"),
        ],
    ]

    /// 專題集合's sample: two lists of the books no layout has. They open nothing (a preview is not
    /// touched); `.gutenbergCollection` is only the one case `CollectionOpening` has.
    static let lists: [(id: String, titleKey: String, books: [HomeLayoutSampleBook])] = [
        (id: "comics", titleKey: "漫畫", books: [
            .init(cover: "chojugiga", title: "鳥獣人物戯画", author: "伝 鳥羽僧正", language: "ja", kind: .comic),
            .init(cover: "hokusai-manga", title: "北斎漫画", author: "葛飾北斎", language: "ja", kind: .comic),
            .init(cover: "max-und-moritz", title: "Max und Moritz", author: "Wilhelm Busch", language: "de", kind: .comic),
        ]),
        (id: "easternClassics", titleKey: "東方經典", books: [
            .init(cover: "midaregami", title: "みだれ髪", author: "与謝野晶子", language: "ja"),
            .init(cover: "kokoro", title: "心", author: "夏目漱石", language: "ja"),
            .init(cover: "panghuang", title: "彷徨", author: "魯迅", language: "zh"),
        ]),
    ]

    @MainActor
    static var standard: HomeLayoutSample {
        HomeLayoutSample(
            cards: books.mapValues { books in
                books.map { HomeCardContent(sample: $0.title, author: $0.author, kind: $0.kind,
                                           cover: bundledCover(of: $0) ?? .generated(seed: $0.title)) }
            },
            collections: lists.map { list in
                CollectionSummary(id: list.id, title: localized(list.titleKey),
                                  books: list.books.map { book in
                                      WorkSummary(title: book.title, authors: book.author.isEmpty ? [] : [book.author],
                                                  cover: bundledCover(of: book) ?? .generated(seed: book.title), blurb: nil,
                                                  language: book.language, contentKind: book.kind)
                                  },
                                  languages: list.books.map(\.language),
                                  opening: .gutenbergCollection(id: list.id))
            })
    }

    /// The bundled cover of a sample book. A missing file is a packaging bug, logged, and the
    /// book is drawn with a generated cover (`LayoutPreviewTests` checks every file is there).
    static func bundledCover(of book: HomeLayoutSampleBook) -> CoverReference? {
        guard let path = Bundle.main.path(forResource: "layout-sample-\(book.cover)", ofType: "jpg") else {
            AppLogger.error("Layout sample cover missing from the app bundle", context: ["cover": book.cover])
            return nil
        }
        return .copyFile(path)
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
        } else if sample.cards(for: layout.style).isEmpty {
            HomeSectionCards(layout: layout, cards: (0..<6).map(HomeCardContent.placeholder),
                             rowID: "layoutPreview.\(layout.rawValue)", hasShowAll: false, open: { _, _ in })
                .redacted(reason: .placeholder)
        } else {
            HomeSectionCards(layout: layout, cards: sample.cards(for: layout.style), rowID: "layoutPreview.\(layout.rawValue)",
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
                             sample: HomeLayoutSample(cards: [:], collections: []), choose: { _ in })
    }
}
#endif
