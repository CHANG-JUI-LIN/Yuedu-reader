import SwiftUI

// Phase 5 plan, decision 34 (the maintainer, with Emby's 選擇模板): choosing a section's layout
// shows what each one looks like. The maintainer, 2026-10-15, after Forward's 選擇模板: a
// gallery, not a list. Each choice is the real layout at its real size, cut off by the screen's
// edge, with its name centred under it; a layout read downwards shows two rows. In 新增欄目's
// first page and behind the form's 呈現方式.
//
// The maintainer, 2026-10-13: each layout gets the covers that suit it best, no book in two
// layouts, and not only Gutenberg's. Painted covers for 精選 and 大型閱讀卡片, comic books for
// 多行橫向輪播, illustrated and comic magazines for 固定封面網格, Japanese and Chinese first
// editions for 精簡閱讀卡片 and 圖文資訊清單, and two lists, 漫畫 and 東方經典, for 專題集合.
// 2026-10-25, with Apple Books' layouts: illustrated children's books for 大型封面書架, dime novels
// for 一大四小, and two lists each for 分類卡片 (詩歌, 博物誌) and 拼貼卡片 (推理, 冒險).
// 2026-10-27: the colour band left 呈現方式 for the 頂部輪播圖, and its boldly coloured Japanese
// and Chinese first editions went to 大圖卡片's two lists (日本裝幀, 新文學), whose cards take their
// first cover's colour.

/// One book a preview is drawn with: its cover, bundled as `layout-sample-<cover>.jpg`, and its
/// title and author as its edition has them. Every cover is in the public domain worldwide:
/// Standard Ebooks' (CC0, made from paintings whose painters died before 1956), or a scan on
/// Wikimedia Commons of a work whose artist died before 1956 or is unknown and published before
/// 1931 (Technotes/LayoutSampleCovers.md lists each).
struct HomeLayoutSampleBook: Hashable {
    let cover: String
    let title: String
    /// The series or magazine it belongs to: two issues of one magazine are a repeat.
    let work: String
    let author: String
    var language: String
    var kind: ContentKind = .text
}

/// The books and lists the previews are drawn with, carried by the app so every preview looks
/// its best offline.
struct HomeLayoutSample {
    /// Each layout's own cards; a layout with none draws placeholders.
    var cards: [HomeLayoutStyle: [HomeCardContent]]
    /// Each layout of lists' own lists.
    var collections: [HomeLayoutStyle: [CollectionSummary]]

    func cards(for style: HomeLayoutStyle) -> [HomeCardContent] {
        cards[style] ?? []
    }

    func collections(for style: HomeLayoutStyle) -> [CollectionSummary] {
        collections[style] ?? []
    }

    /// Each layout's books, as many as its preview shows on a phone. No book is in two layouts
    /// or in a list (`LayoutPreviewTests`).
    static let books: [HomeLayoutStyle: [HomeLayoutSampleBook]] = [
        .featured: [
            .init(cover: "pride-and-prejudice", title: "Pride and Prejudice", work: "Pride and Prejudice", author: "Jane Austen", language: "en"),
            .init(cover: "the-odyssey", title: "The Odyssey", work: "The Odyssey", author: "Homer", language: "en"),
            .init(cover: "dorian-gray", title: "The Picture of Dorian Gray", work: "The Picture of Dorian Gray", author: "Oscar Wilde", language: "en"),
        ],
        .readingCard: [
            .init(cover: "wuthering-heights", title: "Wuthering Heights", work: "Wuthering Heights", author: "Emily Brontë", language: "en"),
            .init(cover: "treasure-island", title: "Treasure Island", work: "Treasure Island", author: "Robert Louis Stevenson", language: "en"),
            .init(cover: "alice", title: "Alice's Adventures in Wonderland", work: "Alice", author: "Lewis Carroll", language: "en"),
        ],
        .row: [
            .init(cover: "moby-dick", title: "Moby Dick", work: "Moby Dick", author: "Herman Melville", language: "en"),
            .init(cover: "dracula", title: "Dracula", work: "Dracula", author: "Bram Stoker", language: "en"),
            .init(cover: "jane-eyre", title: "Jane Eyre", work: "Jane Eyre", author: "Charlotte Brontë", language: "en"),
            .init(cover: "crime-and-punishment", title: "Crime and Punishment", work: "Crime and Punishment", author: "Fyodor Dostoevsky", language: "en"),
            .init(cover: "frankenstein", title: "Frankenstein", work: "Frankenstein", author: "Mary Shelley", language: "en"),
            .init(cover: "war-and-peace", title: "War and Peace", work: "War and Peace", author: "Leo Tolstoy", language: "en"),
        ],
        .compactReadingCard: [
            .init(cover: "tangsong-chuanqi", title: "唐宋傳奇集", work: "唐宋傳奇集", author: "魯迅", language: "zh"),
            .init(cover: "omoigusa", title: "思ひ草", work: "思ひ草", author: "佐佐木信綱", language: "ja"),
            .init(cover: "sishui", title: "死水", work: "死水", author: "聞一多", language: "zh"),
        ],
        .list: [
            .init(cover: "aiaigasa", title: "相合傘", work: "相合傘", author: "泉鏡花", language: "ja"),
            .init(cover: "canshijie", title: "慘世界", work: "慘世界", author: "蘇曼殊、陳由己", language: "zh"),
            .init(cover: "wagahai", title: "吾輩ハ猫デアル", work: "吾輩ハ猫デアル", author: "夏目漱石", language: "ja"),
        ],
        .multiRow: [
            .init(cover: "little-nemo", title: "Little Nemo in Slumberland", work: "Little Nemo", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "becassine", title: "Bécassine chez les Alliés", work: "Bécassine", author: "Caumery, J.-P. Pinchon", language: "fr", kind: .comic),
            .init(cover: "kyosai-manga", title: "暁斎漫画", work: "暁斎漫画", author: "河鍋暁斎", language: "ja", kind: .comic),
            .init(cover: "rarebit-fiend", title: "Dreams of the Rarebit Fiend", work: "Dreams of the Rarebit Fiend", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "fenouillard", title: "La Famille Fenouillard", work: "La Famille Fenouillard", author: "Christophe", language: "fr", kind: .comic),
            .init(cover: "yellow-kid", title: "The Yellow Kid", work: "The Yellow Kid", author: "R. F. Outcault", language: "en", kind: .comic),
            .init(cover: "monsieur-jabot", title: "Histoire de M. Jabot", work: "Histoire de M. Jabot", author: "Rodolphe Töpffer", language: "fr", kind: .comic),
            .init(cover: "mutt-and-jeff", title: "Mutt and Jeff", work: "Mutt and Jeff", author: "Bud Fisher", language: "en", kind: .comic),
            .init(cover: "tintin-lutin", title: "Tintin-Lutin", work: "Tintin-Lutin", author: "Benjamin Rabier, Fred Isly", language: "fr", kind: .comic),
            .init(cover: "sammy-sneeze", title: "Little Sammy Sneeze", work: "Little Sammy Sneeze", author: "Winsor McCay", language: "en", kind: .comic),
            .init(cover: "my-resolutions", title: "My Resolutions", work: "Buster Brown", author: "R. F. Outcault", language: "en", kind: .comic),
            .init(cover: "upside-downs", title: "The Upside Downs", work: "The Upside Downs", author: "Gustave Verbeek", language: "en", kind: .comic),
        ],
        .coverGrid: [
            .init(cover: "jugend-1896-12", title: "Jugend, 1896 Nr. 12", work: "Jugend", author: "Ludwig von Zumbusch", language: "de"),
            .init(cover: "cocorico-1898", title: "Cocorico, n° 1, 1898", work: "Cocorico", author: "Alfons Mucha", language: "fr"),
            .init(cover: "life-1909", title: "Life, August 19, 1909", work: "Life", author: "Coles Phillips", language: "en"),
            .init(cover: "tokyo-puck-1909", title: "東京パック 1909年2月", work: "東京パック", author: "北沢楽天", language: "ja"),
            .init(cover: "assiette-au-beurre-1901", title: "L'Assiette au beurre, n° 37, 1901", work: "L'Assiette au beurre", author: "Albert Guillaume", language: "fr"),
            .init(cover: "yellow-book-1894", title: "The Yellow Book, Volume I", work: "The Yellow Book", author: "Aubrey Beardsley", language: "en"),
            .init(cover: "simplicissimus-1913", title: "Simplicissimus, Badenummer 1913", work: "Simplicissimus", author: "Brynolf Wennerberg", language: "de"),
            .init(cover: "punch-1872", title: "Punch, 27 April 1872", work: "Punch", author: "Richard Doyle", language: "en"),
            .init(cover: "gil-blas-1898", title: "Gil Blas illustré, 1898 n° 21", work: "Gil Blas", author: "Théophile Alexandre Steinlen", language: "fr"),
            .init(cover: "ally-sloper-1892", title: "Ally Sloper's Half Holiday, 1 October 1892", work: "Ally Sloper's Half Holiday", author: "W. Fletcher Thomas", language: "en"),
            .init(cover: "pele-mele-1895", title: "Le Pêle-Mêle, n° 1, 1895", work: "Le Pêle-Mêle", author: "", language: "fr"),
            .init(cover: "comic-cuts-1890", title: "Comic Cuts, No. 1, 1890", work: "Comic Cuts", author: "", language: "en"),
        ],
        .largeRow: [
            .init(cover: "princess-and-goblin", title: "The Princess and the Goblin", work: "The Princess and the Goblin", author: "George MacDonald", language: "en"),
            .init(cover: "bluebeard", title: "Bluebeard", work: "Bluebeard", author: "Walter Crane", language: "en"),
            .init(cover: "vasilisa", title: "Василиса Прекрасная", work: "Василиса Прекрасная", author: "Иван Билибин", language: "ru"),
            .init(cover: "peter-pan-kensington", title: "Peter Pan in Kensington Gardens", work: "Peter Pan", author: "J. M. Barrie", language: "en"),
        ],
        .heroGrid: [
            .init(cover: "nick-carter-stories", title: "Nick Carter Stories, No. 120, 1914", work: "Nick Carter Stories", author: "Nicholas Carter", language: "en"),
            .init(cover: "work-and-win", title: "Work and Win, No. 7, 1899", work: "Work and Win", author: "Hal Standish", language: "en"),
            .init(cover: "pluck-and-luck", title: "Pluck and Luck, No. 282, 1903", work: "Pluck and Luck", author: "Noname", language: "en"),
            .init(cover: "tip-top-weekly", title: "Tip Top Weekly, No. 243, 1900", work: "Tip Top Weekly", author: "Burt L. Standish", language: "en"),
            .init(cover: "my-queen", title: "My Queen, No. 8, 1900", work: "My Queen", author: "Grace Shirley", language: "en"),
            .init(cover: "varney-the-vampire", title: "Varney the Vampire", work: "Varney the Vampire", author: "James Malcolm Rymer", language: "en"),
        ],
    ]

    /// Each layout of lists' sample: two lists of the books no layout has. They open nothing (a
    /// preview is not touched); `.gutenbergCollection` is only the one case `CollectionOpening` has.
    /// A layout that names a list's source (大圖卡片) is given where its covers come from.
    static let lists: [(style: HomeLayoutStyle, id: String, titleKey: String, sourceName: String?, books: [HomeLayoutSampleBook])] = [
        (style: .collection, id: "comics", titleKey: "漫畫", sourceName: nil, books: [
            .init(cover: "chojugiga", title: "鳥獣人物戯画", work: "鳥獣人物戯画", author: "伝 鳥羽僧正", language: "ja", kind: .comic),
            .init(cover: "hokusai-manga", title: "北斎漫画", work: "北斎漫画", author: "葛飾北斎", language: "ja", kind: .comic),
            .init(cover: "max-und-moritz", title: "Max und Moritz", work: "Max und Moritz", author: "Wilhelm Busch", language: "de", kind: .comic),
        ]),
        (style: .collection, id: "easternClassics", titleKey: "東方經典", sourceName: nil, books: [
            .init(cover: "midaregami", title: "みだれ髪", work: "みだれ髪", author: "与謝野晶子", language: "ja"),
            .init(cover: "kokoro", title: "心", work: "心", author: "夏目漱石", language: "ja"),
            .init(cover: "panghuang", title: "彷徨", work: "彷徨", author: "魯迅", language: "zh"),
        ]),
        (style: .categoryCards, id: "poetry", titleKey: "詩歌", sourceName: nil, books: [
            .init(cover: "songs-of-innocence", title: "Songs of Innocence", work: "Songs of Innocence", author: "William Blake", language: "en"),
            .init(cover: "goblin-market", title: "Goblin Market and Other Poems", work: "Goblin Market", author: "Christina Rossetti", language: "en"),
            .init(cover: "leaves-of-grass", title: "Leaves of Grass", work: "Leaves of Grass", author: "Walt Whitman", language: "en"),
        ]),
        (style: .categoryCards, id: "naturalHistory", titleKey: "博物誌", sourceName: nil, books: [
            .init(cover: "kunstformen-der-natur", title: "Kunstformen der Natur", work: "Kunstformen der Natur", author: "Ernst Haeckel", language: "de"),
            .init(cover: "british-algae", title: "Photographs of British Algae", work: "Photographs of British Algae", author: "Anna Atkins", language: "en"),
            .init(cover: "psittacidae", title: "Illustrations of the Family of Psittacidae, or Parrots", work: "Illustrations of the Family of Psittacidae", author: "Edward Lear", language: "en"),
        ]),
        (style: .collageCards, id: "mystery", titleKey: "推理", sourceName: nil, books: [
            .init(cover: "study-in-scarlet", title: "A Study in Scarlet", work: "Sherlock Holmes", author: "Arthur Conan Doyle", language: "en"),
            .init(cover: "arsene-lupin", title: "Arsène Lupin, gentleman-cambrioleur", work: "Arsène Lupin", author: "Maurice Leblanc", language: "fr"),
            .init(cover: "fantomas", title: "Fantômas", work: "Fantômas", author: "Pierre Souvestre, Marcel Allain", language: "fr"),
        ]),
        (style: .collageCards, id: "adventure", titleKey: "冒險", sourceName: nil, books: [
            .init(cover: "call-of-the-wild", title: "The Call of the Wild", work: "The Call of the Wild", author: "Jack London", language: "en"),
            .init(cover: "jungle-book", title: "The Jungle Book", work: "The Jungle Book", author: "Rudyard Kipling", language: "en"),
            .init(cover: "naufrages-du-jonathan", title: "Les Naufragés du « Jonathan »", work: "Voyages extraordinaires", author: "Jules Verne", language: "fr"),
        ]),
        (style: .bannerCards, id: "japaneseBookDesign", titleKey: "日本裝幀", sourceName: "Wikimedia Commons", books: [
            .init(cover: "kuwana-shinju", title: "桑名心中", work: "桑名心中", author: "長田幹彦", language: "ja"),
            .init(cover: "nihon-otogibanashi", title: "日本お伽噺集", work: "日本児童文庫", author: "巖谷小波", language: "ja"),
            .init(cover: "tako", title: "凧", work: "凧", author: "竹久夢二", language: "ja"),
        ]),
        (style: .bannerCards, id: "newLiterature", titleKey: "新文學", sourceName: "Wikimedia Commons", books: [
            .init(cover: "nahan", title: "吶喊", work: "吶喊", author: "魯迅", language: "zh"),
            .init(cover: "menghu-ji", title: "猛虎集", work: "猛虎集", author: "徐志摩", language: "zh"),
            .init(cover: "hongzhu", title: "紅燭", work: "紅燭", author: "聞一多", language: "zh"),
        ]),
    ]

    @MainActor
    static var standard: HomeLayoutSample {
        HomeLayoutSample(
            cards: books.mapValues { books in
                books.map { HomeCardContent(sample: $0.title, author: $0.author, kind: $0.kind,
                                           cover: bundledCover(of: $0)) }
            },
            collections: Dictionary(grouping: lists, by: { $0.style }).mapValues { lists in
                lists.map { list in
                    CollectionSummary(id: list.id, title: localized(list.titleKey),
                                      books: list.books.map { book in
                                          WorkSummary(title: book.title, authors: book.author.isEmpty ? [] : [book.author],
                                                      cover: bundledCover(of: book), blurb: nil,
                                                      language: book.language, contentKind: book.kind)
                                      },
                                      languages: list.books.map(\.language),
                                      opening: .gutenbergCollection(id: list.id),
                                      sourceName: list.sourceName)
                }
            })
    }

    /// The bundled cover of a sample book. A missing file is a packaging bug: logged, and the
    /// book drawn without a cover (`LayoutPreviewTests` checks every file is there).
    static func bundledCover(of book: HomeLayoutSampleBook) -> CoverReference? {
        guard let path = Bundle.main.path(forResource: "layout-sample-\(book.cover)", ofType: "jpg") else {
            AppLogger.error("Layout sample cover missing from the app bundle", context: ["cover": book.cover])
            return nil
        }
        return .copyFile(path)
    }
}

/// The layouts as a gallery: each one's preview, then its name centred under it, with a
/// checkmark on the current one. 新增欄目 and the form's page lay them out alike.
struct HomeLayoutGallery: View {
    let choices: [HomeLayoutStyle]
    var current: HomeSectionLayout?
    let sample: HomeLayoutSample
    /// The choices' accessibility identifiers, `<prefix>.<layout>`.
    let identifierPrefix: String
    let choose: (HomeLayoutStyle) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DSSpacing.xxl) {
                ForEach(choices) { style in
                    choice(style)
                }
            }
            .padding(.vertical, DSSpacing.xl)
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
    }

    private func choice(_ style: HomeLayoutStyle) -> some View {
        let isCurrent = current?.style == style
        return Button { choose(style) } label: {
            VStack(spacing: DSSpacing.md) {
                // The current layout as set (圖文資訊清單 and 橫向單排書架 with or without ranks).
                HomeLayoutPreview(layout: current.flatMap { $0.style == style ? $0 : nil } ?? HomeSectionLayout(style: style),
                                  sample: sample)
                HStack(spacing: DSSpacing.xs) {
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(DSFont.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(localized(style.titleKey))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DSSpacing.lg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ExploreTileButtonStyle())
        // The name is the choice; the preview shows it and is not read.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized(style.titleKey))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("\(identifierPrefix).\(style.rawValue)")
    }
}

/// A layout at its real size, with the books that suit it: a sideways one runs past the
/// screen's edge, one read downwards stops after `DSLayout.homeLayoutPreviewRows` rows. Nothing
/// in it can be touched or read.
struct HomeLayoutPreview: View {
    let layout: HomeSectionLayout
    let sample: HomeLayoutSample

    var body: some View {
        content
            .scrollDisabled(true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if layout.style.drawsLists {
            HomeSectionLists(layout: layout, collections: sample.collections(for: layout.style), open: { _ in })
        } else if sample.cards(for: layout.style).isEmpty {
            HomeSectionCards(layout: layout, cards: (0..<6).map(HomeCardContent.placeholder),
                             rowID: "layoutPreview.\(layout.rawValue)", hasShowAll: false, open: { _, _ in },
                             previewRows: DSLayout.homeLayoutPreviewRows)
                .redacted(reason: .placeholder)
        } else {
            HomeSectionCards(layout: layout, cards: sample.cards(for: layout.style), rowID: "layoutPreview.\(layout.rawValue)",
                             hasShowAll: false, open: { _, _ in }, previewRows: DSLayout.homeLayoutPreviewRows)
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
        HomeLayoutGallery(choices: choices, current: current, sample: sample,
                          identifierPrefix: "homeSection.layoutChoice", choose: choose)
            .navigationTitle(localized("呈現方式"))
            .toolbarTitleDisplayMode(.inline)
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
                             sample: HomeLayoutSample(cards: [:], collections: [:]), choose: { _ in })
    }
}
#endif
