import Foundation

// Phase 6c: a module is a declarative file that lists books from one site (design §14.2). Only
// the top level follows ForwardWidgets; where Forward has a JS function, each entry carries a
// `request` and a `list` of rule-engine rules instead. The file as written is what the store
// keeps, so keys a newer app adds survive this one untouched.

struct RuleModule: Codable, Hashable, Sendable {
    /// File-safe (`[A-Za-z0-9._-]`): it names the module's folder.
    var id: String
    var title: String
    var description: String?
    var author: String?
    var site: String?
    /// Numeric dot form (`1.0.0`); 檢查更新 accepts a higher one.
    var version: String
    /// The lowest app version that reads this file.
    var requiredVersion: String?
    /// The only hosts its requests may go to. A `*.example.org` entry (format 3.0) is a domain a
    /// redirect may follow into, never a request's own host (`RuleModuleHosts`).
    var hosts: [String]
    /// Legado's `concurrentRate` syntax (`SourceRateLimit`).
    var rateLimit: String?
    var modules: [Entry]
    var search: Entry?
    /// A book by its ISBN (`{{isbn}}`): the record is the copy's own, so it may also give a
    /// cover (from `hosts` only), a publisher and a series. Fill only (format 3.0).
    var lookup: Entry?
    /// How its books are read (format 3.0): a list item's `url` is the book's page, which
    /// holds its table of contents; each chapter's page holds its text. Without it the module's
    /// books are data only.
    var reading: Reading?
    /// What its readers wrote about a book (format 3.0.1): asked for the record that is the
    /// work 作品詳情 shows, found by `lookup` or `search`. Without it the module gives none.
    var reviews: Reviews?
    /// The module's picture, an address on `hosts` (format 3.0.2): drawn wherever the module is
    /// named. Without it the module has the symbol every module shares.
    var icon: String?
    /// Parameters of the whole module, Forward's `globalParams` (format 3.0.2): set once on the
    /// module's page, and a `{{name}}` in any request of its lists, search, lookup and reviews.
    /// `RuleModuleLibrary` writes the reader's own into each one's `value`.
    var globalParams: [Param]?
    /// A book's own page as 作品詳情 opens one of the module's books, Forward's `loadDetail`
    /// (format 3.0.2): `{{url}}` is the book's `url`; it gives the description and tags its row
    /// did not. Asked once per opening, or from its `cacheDuration`.
    var detail: Detail?
    /// Works like a book, Forward's `relatedItems` (format 3.0.2): 作品詳情's 相關作品, asked of
    /// the record of the work as `reviews` is.
    var related: Related?
    /// The module's books of one genre, by `{{tag}}` (format 3.0.2): where a genre of one of its
    /// books opens. Without it the genre opens what `search` finds for the word.
    var genre: Entry?
    /// Its rules and requests may run JavaScript (format 3.0.2; `RuleModuleScriptRuntime`): `@js:`
    /// and `<js>` in a rule, and a request's `script`. The script computes and never connects:
    /// every request is still the module's own, to its `hosts`. Without it a rule with JS is
    /// refused at import, as before.
    var javascript: Bool?
    /// What readers wrote about a chapter (format 3.0.2), drawn in the text as a 來源配置's own
    /// are: 段評 (a count at the end of a paragraph), 熱評 (a card under a paragraph), 本章說 (a
    /// card after the chapter) and 作者說. Asked for the record that is the book being read,
    /// found as `reviews` finds a work's, then for the chapter of the site's whose title is the
    /// chapter's. Any book: one from a file, or from a source with no comments.
    var comments: Comments?

    /// A record's chapters on the site, and what the site holds about one chapter.
    struct Comments: Codable, Hashable, Sendable {
        /// Seconds a book's chapter list, and each of a chapter's answers, answer again without a
        /// request.
        var cacheDuration: Int?
        var chapters: CommentChapters
        /// 本章說: the chapter's comments, and the card after the chapter.
        var chapter: ChapterComments
        /// 段評: how many comments each paragraph has. With it, `paragraph` reads one paragraph's.
        var counts: ParagraphCounts?
        /// One paragraph's comments: `{{paragraphId}}` is the paragraph's, as `counts` or `hot`
        /// gave it.
        var paragraph: ChapterComments?
        /// 熱評: a picked comment under a paragraph.
        var hot: HotComments?
        /// 作者說: the author's note on the chapter.
        var authorSay: AuthorSay?
        /// All of one comment's replies (樓中樓): `{{commentId}}` is the comment's `id`, with the
        /// chapter's, the paragraph's and the record's as the comments request has them.
        var replies: Replies?
        /// The 來源配置 comment pages the module reads: a source's bubble or card
        /// whose address is one of these opens the app's own list of the module's comments, when
        /// 使用 App 內建評論列表 is on (`ModuleCommentSourcePages`).
        var sourcePages: [SourcePage]?
    }

    /// One comment's replies, a page at a time: `{{page}}` from 1.
    struct Replies: Codable, Hashable, Sendable {
        var request: Request
        var list: ReplyRules
        /// How many replies there are in all, read on the page itself.
        var total: String?
    }

    /// A 來源配置's comment page, told by its address: the host, the path, and which of its parts
    /// are the record's `{{id}}`, the chapter's `{{chapterId}}` and the paragraph's
    /// `{{paragraphId}}`. Nothing else of the address is read: a source's page can carry the
    /// reader's token, and it never reaches the module's requests.
    struct SourcePage: Codable, Hashable, Sendable {
        /// Host names, written out or as `*.example.org`.
        var hosts: [String]
        /// A regular expression the whole path must match; its named groups `id`, `chapterId`
        /// and `paragraphId` are those values.
        var path: String?
        /// Query parameters that are those values: `{"chapterId": "cid"}` reads `?cid=…`.
        var query: [String: String]?
    }

    /// Which paragraph an item is about. The paragraph is told by its text (`quote`, the
    /// paragraph or its first words), or by its number (`index`, from 1) when the site's count of
    /// the chapter's paragraphs (`paragraphCount`) is the reader's own: the reader's copy and the
    /// site's are two editions, and a number alone would put a comment under another paragraph.
    struct ParagraphRules: Codable, Hashable, Sendable {
        var quote: String?
        var index: String?
        /// The site's own id of the paragraph, `{{paragraphId}}`; its `index` when absent.
        var id: String?
        /// True for an item about the chapter's title, which a site counts comments on as a
        /// paragraph of its own (起點's paragraph -1, QQ閱讀's 0).
        var title: String?
    }

    /// 段評: `{{chapterId}}` is the chapter's; each item is a paragraph and how many comments it has.
    struct ParagraphCounts: Codable, Hashable, Sendable {
        var request: Request
        var list: ParagraphCountRules
        /// How many paragraphs the site's chapter has, read on the page itself.
        var paragraphCount: String?
    }

    struct ParagraphCountRules: Codable, Hashable, Sendable {
        var items: String
        var count: String
        var quote: String?
        var index: String?
        var id: String?
        var title: String?
        /// True for a paragraph the site marks as hot: its bubble wears the emphasis colour.
        var hot: String?
        /// True for a paragraph with a spoken comment: its bubble is the voice version.
        var voice: String?

        var paragraph: ParagraphRules { ParagraphRules(quote: quote, index: index, id: id, title: title) }
    }

    /// 熱評: each item is a comment and the paragraph it is under.
    struct HotComments: Codable, Hashable, Sendable {
        var request: Request
        var list: HotCommentRules
        var paragraphCount: String?
    }

    struct HotCommentRules: Codable, Hashable, Sendable {
        var items: String
        var text: String
        var author: String?
        var likes: String?
        var quote: String?
        var index: String?
        var id: String?
        var title: String?

        var paragraph: ParagraphRules { ParagraphRules(quote: quote, index: index, id: id, title: title) }
    }

    /// 作者說: the note, read on the page itself (no `items`).
    struct AuthorSay: Codable, Hashable, Sendable {
        var request: Request
        var text: String
        var author: String?
    }

    /// The record's chapters as the site lists them: `{{id}}` and `{{url}}` are the record's.
    struct CommentChapters: Codable, Hashable, Sendable {
        var request: Request
        var list: CommentChapterRules
    }

    struct CommentChapterRules: Codable, Hashable, Sendable {
        var items: String
        /// The chapter's own id on the site: the comments request's `{{chapterId}}`.
        var id: String
        var title: String
    }

    /// One chapter's comments: `{{chapterId}}` is the chapter's `id`, `{{id}}` and `{{url}}` the
    /// record's, `{{page}}` the page from 1, `{{sort}}` the chosen order's `value`.
    struct ChapterComments: Codable, Hashable, Sendable {
        var request: Request
        /// The orders the site has (最熱, 最新), the first the default; the reader picks one.
        var sorts: [Option]?
        /// Each comment, read as a review is; `rating` is not drawn.
        var list: ReviewRules
        /// How many comments there are in all, read on the page itself: the card's 「N 則」.
        var total: String?
    }

    /// A record's related works, on one page of the site's.
    struct Related: Codable, Hashable, Sendable {
        /// `{{id}}` is the record's `id`, `{{url}}` its `url`, as for `reviews`.
        var request: Request
        /// Seconds a work's related works answer again without a request.
        var cacheDuration: Int?
        /// Each work, read as a list's are.
        var list: ListRules
    }

    /// A record's reviews, on one page of the site's.
    struct Reviews: Codable, Hashable, Sendable {
        /// `{{id}}` is the record's `id`, `{{url}}` its `url`; the address must be on `hosts`
        /// once it is filled.
        var request: Request
        /// Seconds a work's reviews answer again without a request.
        var cacheDuration: Int?
        var list: ReviewRules
        /// What a review's `rating` and the summary's `score` are out of; 5 when absent.
        var ratingScale: Double?
        /// The book's rating as a whole, read on the page itself (no `items`).
        var rating: RatingRules?
    }

    /// One review, read in the scope `items` selects. Only what the site gives is drawn: a
    /// review without a `rating` rule has no stars.
    struct ReviewRules: Codable, Hashable, Sendable {
        var items: String
        var text: String
        /// The review's own headline.
        var title: String?
        /// Who wrote it, as the site names them.
        var author: String?
        /// When, as the site writes it (`2025-01-02 15:43:23`, an ISO 8601 date, or seconds
        /// since 1970); a date in no such form is left out.
        var date: String?
        /// The writer's own rating of the book, a number out of `ratingScale`.
        var rating: String?
        /// How many readers marked it helpful.
        var likes: String?
        /// The site's own id of the comment: its replies' `{{commentId}}`.
        var id: String?
        /// The writer's picture, an http(s) address.
        var avatar: String?
        /// The title the site gives the writer beside their name (粉絲稱號).
        var badge: String?
        /// Its place in the thread (`3`, `沙發`).
        var floor: String?
        /// The replies the page shows under it, read in its scope.
        var replies: ReplyRules?
        /// How many replies it has in all.
        var replyCount: String?
        /// The words of the book it answers (段落原文引用).
        var quote: String?
        /// When and where, as the site writes it (`11-11 22:10 · 江蘇`).
        var meta: String?
        /// The pictures it carries, several values, http(s) addresses.
        var images: String?
        /// The address of its spoken comment's audio.
        var voice: String?
        /// True when the work's author wrote it.
        var isAuthor: String?
    }

    /// One reply, read in the scope `items` selects. Replies have no replies of their own.
    struct ReplyRules: Codable, Hashable, Sendable {
        var items: String
        var text: String
        var author: String?
        var date: String?
        var likes: String?
        var id: String?
        var avatar: String?
        var badge: String?
        var floor: String?
        var meta: String?
        var images: String?
        var voice: String?
        var isAuthor: String?

        /// As a comment's rules, with nothing below it.
        var asReviewRules: ReviewRules {
            ReviewRules(items: items, text: text, author: author, date: date, likes: likes, id: id, avatar: avatar,
                        badge: badge, floor: floor, meta: meta, images: images, voice: voice, isAuthor: isAuthor)
        }
    }

    struct RatingRules: Codable, Hashable, Sendable {
        /// The average, a number out of `ratingScale`.
        var score: String
        /// How many ratings it is the average of.
        var count: String?
        /// How many ratings each star has, several values, the highest star first.
        var distribution: String?
    }

    struct Reading: Codable, Hashable, Sendable {
        /// Sent with every page of a book (`User-Agent`). No templates.
        var headers: [String: String]?
        var charset: String?
        var toc: TableOfContents
        var content: Content
    }

    /// The book page's chapter list. An item with a title and no url is a volume heading.
    struct TableOfContents: Codable, Hashable, Sendable {
        var items: String
        var title: String
        var url: String
        /// The address of the list's next page; the list ends where it is empty, at a page
        /// already read, or after `RuleModuleClient.maxTOCPages`.
        var nextPage: String?
        /// A rule that matches only on a page that is the book's one chapter (なろう's short
        /// story: `.p-novel__body`). Read before the list: a book is one chapter only when the
        /// page says so, never because its list came back empty.
        var singleChapter: String?
    }

    struct Content: Codable, Hashable, Sendable {
        /// The chapter's text, HTML kept (`@html`), as a 來源配置's content rule.
        var text: String
        var title: String?
        /// A chapter split over several pages.
        var nextPage: String?
    }
    /// The credit the site asks for, shown on the module's page (format 3.0).
    var attribution: Attribution?
    /// Its own words in other languages, by language tag (`en`, `zh-Hans`): the title, the
    /// description and each entry's, shown in the app's language when one matches (format 3.0).
    var localizations: [String: Localization]?

    struct Localization: Codable, Hashable, Sendable {
        var title: String?
        var description: String?
        /// By entry id.
        var entries: [String: EntryText]?
    }

    struct EntryText: Codable, Hashable, Sendable {
        var title: String?
        var description: String?
        /// By parameter name: what the section form shows for it (趨勢's 地區 and its options).
        var params: [String: ParamText]?
    }

    struct ParamText: Codable, Hashable, Sendable {
        var title: String?
        var description: String?
        /// An option's title, by its `value`.
        var options: [String: String]?
    }

    /// A line naming the site, as its terms word it: 楽天's "Supported by Rakuten Developers".
    struct Attribution: Codable, Hashable, Sendable {
        var text: String
        /// Where the credit links; http(s).
        var url: String?
    }

    /// One list: a home section, or the module's search.
    struct Entry: Codable, Hashable, Sendable {
        /// Absent on the search entry.
        var id: String?
        var title: String?
        var description: String?
        /// Seconds a fetched page answers again without a request.
        var cacheDuration: Int?
        var params: [Param]
        var request: Request
        var list: ListRules
        /// `text` (absent) or `comic`: what its items are, unless an item's `contentKind` rule
        /// says `comic` (format 3.0).
        var contentKind: String?
        /// Tags the `tags` rule reads that are not genres on this site (`漫画`, `单行本`), left
        /// out wherever its tags are used (format 3.0).
        var excludeTags: [String]?
        /// On `lookup`: the ISBN-13 prefixes the site has (openBD: `9784`). Any other book's ISBN
        /// never leaves the device (format 3.0).
        var isbnPrefixes: [String]?
        /// On `search` and `lookup`: the record's own page, asked for what its row lacks.
        var detail: Detail?
        /// On `search`: the fewest characters a keyword is sent with (Open Library refuses one
        /// under 3, 「三体」). A shorter one is not asked (format 3.0).
        var minKeywordLength: Int?
        /// On `search`: a keyword that is an author's name finds that author's books, so
        /// 作品詳情's 作者其他作品 may ask it (format 3.0.1). Absent, it is asked for titles only.
        var searchesAuthors: Bool?
        /// On `modules[]`: the list's own store, its sections in order, each the list with some of
        /// its parameters set (format 3.0.2). A card of the list opens it instead of the plain
        /// list (maintainer, 2026-11-15: a genre opens as Apple Books' 愛情 page does). An older
        /// app ignores it.
        var store: [StoreSection]?

        init(id: String?, title: String?, description: String? = nil, cacheDuration: Int? = nil,
             params: [Param] = [], request: Request, list: ListRules, contentKind: String? = nil,
             excludeTags: [String]? = nil, isbnPrefixes: [String]? = nil, detail: Detail? = nil,
             minKeywordLength: Int? = nil, searchesAuthors: Bool? = nil, store: [StoreSection]? = nil) {
            self.id = id
            self.title = title
            self.description = description
            self.cacheDuration = cacheDuration
            self.params = params
            self.request = request
            self.list = list
            self.contentKind = contentKind
            self.excludeTags = excludeTags
            self.isbnPrefixes = isbnPrefixes
            self.detail = detail
            self.minKeywordLength = minKeywordLength
            self.searchesAuthors = searchesAuthors
            self.store = store
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            cacheDuration = try container.decodeIfPresent(Int.self, forKey: .cacheDuration)
            params = try container.decodeIfPresent([Param].self, forKey: .params) ?? []
            request = try container.decode(Request.self, forKey: .request)
            list = try container.decode(ListRules.self, forKey: .list)
            contentKind = try container.decodeIfPresent(String.self, forKey: .contentKind)
            excludeTags = try container.decodeIfPresent([String].self, forKey: .excludeTags)
            isbnPrefixes = try container.decodeIfPresent([String].self, forKey: .isbnPrefixes)
            detail = try container.decodeIfPresent(Detail.self, forKey: .detail)
            minKeywordLength = try container.decodeIfPresent(Int.self, forKey: .minKeywordLength)
            searchesAuthors = try container.decodeIfPresent(Bool.self, forKey: .searchesAuthors)
            store = try container.decodeIfPresent([StoreSection].self, forKey: .store)
        }

        /// Whether `keyword` is long enough to be sent (`minKeywordLength`), counted trimmed.
        nonisolated func takes(keyword: String) -> Bool {
            let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !keyword.isEmpty && keyword.count >= (minKeywordLength ?? 1)
        }
    }

    /// One section of a list's store (`Entry.store`): the list drawn in `layout`, with `params`
    /// over the parameters' own values. Named by the option it sets, as its cards are.
    struct StoreSection: Codable, Hashable, Sendable {
        /// A layout of books (`HomeSectionLayout`): `heroCards`, `multiRow`, `largeRow`…; with
        /// `shelves`, `groupedShelves`.
        var layout: String
        /// Parameter values by name.
        var params: [String: String]?
        /// The section's shelves, a list each (maintainer, 2026-11-16, after Apple Books' More in
        /// Romance: a genre's subgenres). Its layout is then `groupedShelves`.
        var shelves: [StoreShelf]?
    }

    /// One shelf of a store's `groupedShelves` section: the store's list, or another list of the
    /// module (`list`), with `params` over its parameters' own values; named by the option it
    /// sets, or the other list's name. Drawn only while the store's own parameter `belongTo`
    /// names has one of its values (a subgenre one region's wiki has).
    struct StoreShelf: Codable, Hashable, Sendable {
        var list: String?
        var params: [String: String]?
        var belongTo: BelongTo?
    }

    /// A `search` or `lookup` record's own page (Open Library: a work's description is at
    /// `/works/<id>.json`, not in its search). Asked once, for the record that is the copy's,
    /// and only for a field the copy still misses that the row did not give. An app that does
    /// not read it fills less and nothing else.
    struct Detail: Codable, Hashable, Sendable {
        /// `{{url}}` is the record's `url`; the address must be on `hosts` once it is filled.
        var request: Request
        /// Rules read on the page itself (no `items`).
        var intro: String?
        /// Several values.
        var tags: String?
        /// On the module's own `detail` (format 3.0.2): seconds a book's page answers again
        /// without a request.
        var cacheDuration: Int?
    }

    /// Forward's parameter, by its names and types.
    struct Param: Codable, Hashable, Sendable {
        var name: String
        var title: String?
        /// A `ParamType` raw value; anything else is rejected by name rather than by decoding.
        var type: String
        var description: String?
        /// The default. A number in the file reads as its text. On a `page` or `offset`
        /// parameter, the first page's position, a whole number (format 3.0).
        var value: String?
        var enumOptions: [Option]?
        /// An enumeration whose default is the option in the reader's 中繼資料語言偏好推薦 (format
        /// 3.0): 趨勢's 地區. `value` is the default when no option is in that language.
        var followsLanguage: Bool?
        /// Shown, and its own value sent, only while another parameter of the same list (or of
        /// `globalParams`) has one of these values, Forward's `belongTo` (format 3.0.2). Hidden,
        /// it sends its default.
        var belongTo: BelongTo?
        /// Values an `input` offers to fill in, Forward's `placeholders` (format 3.0.2).
        var placeholders: [Placeholder]?

        var kind: ParamType? { ParamType(rawValue: type) }

        init(name: String, title: String? = nil, type: String, description: String? = nil, value: String? = nil,
             enumOptions: [Option]? = nil, followsLanguage: Bool? = nil, belongTo: BelongTo? = nil,
             placeholders: [Placeholder]? = nil) {
            self.name = name
            self.title = title
            self.type = type
            self.description = description
            self.value = value
            self.enumOptions = enumOptions
            self.followsLanguage = followsLanguage
            self.belongTo = belongTo
            self.placeholders = placeholders
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            type = try container.decode(String.self, forKey: .type)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
                value = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .value) {
                value = String(number)
            } else {
                value = try container.decodeIfPresent(Double.self, forKey: .value).map { String($0) }
            }
            enumOptions = try container.decodeIfPresent([Option].self, forKey: .enumOptions)
            followsLanguage = try container.decodeIfPresent(Bool.self, forKey: .followsLanguage)
            belongTo = try container.decodeIfPresent(BelongTo.self, forKey: .belongTo)
            placeholders = try container.decodeIfPresent([Placeholder].self, forKey: .placeholders)
        }
    }

    /// The parameter a `belongTo` follows, by its `name`, and the values that show it.
    struct BelongTo: Codable, Hashable, Sendable {
        var paramName: String
        var value: [String]
    }

    /// An `input`'s suggestion: what the menu says, and what it fills in.
    struct Placeholder: Codable, Hashable, Sendable {
        var title: String
        var value: String
    }

    enum ParamType: String, CaseIterable, Sendable {
        /// Typed by the reader in the section editor.
        case input
        /// A number.
        case count
        /// Fixed.
        case constant
        /// Picked from `enumOptions`.
        case enumeration
        /// Filled by paging.
        case page, offset
    }

    struct Option: Codable, Hashable, Sendable {
        var title: String
        var value: String
        /// The language a `followsLanguage` parameter matches it by, a tag (`zh-Hant`, `ja`);
        /// its `value` when absent (format 3.0).
        var language: String?
        /// Offered, and sent, only while another parameter of the same set has one of these
        /// values (format 3.0.2): 趨勢's 子類型 that only one region's lists have. Picked and then
        /// left behind by that parameter, the parameter sends its default instead.
        var belongTo: BelongTo?
    }

    struct Request: Codable, Hashable, Sendable {
        /// `{{name}}` stands for a parameter (or `page`, `offset`, `keyword` on search).
        var url: String
        /// GET when absent.
        var method: String?
        var body: String?
        var headers: [String: String]?
        var charset: String?
        /// How a value goes into `body`: `form` (absent), percent-encoded, or `json`, escaped as
        /// a JSON string's contents, for a body such as `{"keyword":"{{keyword}}"}` (format 3.0).
        var bodyEncoding: String?
        /// JavaScript run once the templates are filled, in a module that declares `javascript`
        /// (format 3.0.2): `request` is `{url, method, body, headers}` and `values` the templates'
        /// values; the request sent is the object it returns, else `request` as it left it. For a
        /// site that signs its requests. The address it writes is still held to `hosts`.
        var script: String?
    }

    /// `Request.bodyEncoding`'s values.
    enum BodyEncoding: String, CaseIterable, Sendable {
        case form, json
    }

    /// The rule engine's own syntax: CSS, XPath, JSONPath, Regex, with `||` `&&` `%%` `##`.
    struct ListRules: Codable, Hashable, Sendable {
        var items: String
        var title: String
        var author: String?
        var cover: String?
        var intro: String?
        var url: String?
        var kind: String?
        var language: String?
        /// Other names of the work, several values: its titles in other languages (format 3.0).
        var aliases: String? = nil
        /// Its genres and themes, several values (format 3.0).
        var tags: String? = nil
        var publisher: String? = nil
        /// An ISBN-10 or -13; one that fails its check digit is dropped (format 3.0).
        var isbn: String? = nil
        var series: String? = nil
        /// The covers of the series' other volumes, several values, in series order after the
        /// item, which stands for the series (趨勢 lists a series under its first book). 作品詳情
        /// fans them behind the item's cover; only from `hosts`, as `cover` is (format 3.0).
        var seriesCovers: String? = nil
        /// `comic` makes the item a comic; any other value leaves the entry's kind (format 3.0).
        var contentKind: String? = nil
        /// The record's own id on the site, for a request that takes one where its `url` is
        /// another address (`reviews`' `{{id}}`; format 3.0.1).
        var id: String? = nil
        /// The books of the series the item stands for, in series order, the item's own among
        /// them: a rule that selects them inside the item, each then read with this list's own
        /// rules (`title`, `author`, `cover`, `url`…). The item's card opens the series' page,
        /// which lists them; one with a `url` opens as a work of its own (format 3.0.1).
        var volumes: String? = nil
    }
}

extension RuleModule {
    /// The module in `language` (the app's, `Bundle.main.preferredLocalizations`): the words of
    /// the localization of the same language and script, where it has them. Without one it is
    /// as written: `zh-Hans` never stands in for `zh-Hant`, nor `en` for anything.
    func localized(for language: String) -> RuleModule {
        guard let localizations, let text = Self.localization(in: localizations, for: language) else { return self }
        var module = self
        if let title = text.title?.nonBlank { module.title = title }
        if let description = text.description?.nonBlank { module.description = description }
        for (index, entry) in module.modules.enumerated() {
            guard let id = entry.id, let words = text.entries?[id] else { continue }
            if let title = words.title?.nonBlank { module.modules[index].title = title }
            if let description = words.description?.nonBlank { module.modules[index].description = description }
            for (paramIndex, param) in entry.params.enumerated() {
                guard let said = words.params?[param.name] else { continue }
                if let title = said.title?.nonBlank { module.modules[index].params[paramIndex].title = title }
                if let description = said.description?.nonBlank { module.modules[index].params[paramIndex].description = description }
                for (optionIndex, option) in (param.enumOptions ?? []).enumerated() {
                    if let title = said.options?[option.value]?.nonBlank {
                        module.modules[index].params[paramIndex].enumOptions?[optionIndex].title = title
                    }
                }
            }
        }
        return module
    }

    private static func localization(in localizations: [String: Localization], for language: String) -> Localization? {
        if let exact = localizations[language] { return exact }
        let wanted = Locale.Language(identifier: language).maximalIdentifier
        let wantedLanguage = Locale.Language(identifier: wanted)
        return localizations.sorted { $0.key < $1.key }.first { key, _ in
            let candidate = Locale.Language(identifier: Locale.Language(identifier: key).maximalIdentifier)
            return candidate.languageCode == wantedLanguage.languageCode && candidate.script == wantedLanguage.script
        }?.value
    }
}

private extension String {
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// The first app version that reads each field added since Phase 6. A module that uses one
/// must say so in `requiredVersion`, or an older app would import it and run it wrongly
/// (a JSON body sent percent-encoded searches for `%E8…`).
enum RuleModuleFormat {
    static let version3 = "3.0"
    /// `reviews`, a list's `id` and `volumes`, and a search's `searchesAuthors`.
    static let version3_0_1 = "3.0.1"
    /// `icon`, `globalParams`, `detail`, `related`, `genre`, a list's `store`, a parameter's
    /// `belongTo` and `placeholders`, `javascript`, a request's `script`, and `comments`.
    static let version3_0_2 = "3.0.2"
}

extension RuleModule.ListRules {
    /// The same mapping a 來源配置's search list uses.
    var fields: RuleListFields {
        RuleListFields(name: title, author: author ?? "", bookUrl: url ?? "", coverUrl: cover ?? "",
                       intro: intro ?? "", wordCount: "", lastChapter: "", kind: kind ?? "", language: language ?? "",
                       aliases: aliases ?? "", tags: tags ?? "", publisher: publisher ?? "", isbn: isbn ?? "",
                       series: series ?? "", seriesCovers: seriesCovers ?? "", contentKind: contentKind ?? "",
                       id: id ?? "", volumes: volumes ?? "")
    }
}

/// A numeric dot version (`3.0`, `1.2.10`); missing components count as zero.
struct RuleModuleVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// The running app's `CFBundleShortVersionString`.
    static var app: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
