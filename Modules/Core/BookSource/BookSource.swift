import Combine
import Foundation

// MARK: - Safe Decoding Extensions (null / missing key / type mismatch tolerance)

extension KeyedDecodingContainer {
    /// Returns "" when encountering null or missing key, without throwing
    func safeString(forKey key: Key) -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        // Some Legado fields may be serialized as numbers instead of strings
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return ""
    }

    /// Int tolerant decoding: accepts Int, String("0"), Double, Bool
    func safeInt(forKey key: Key) -> Int {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return 0
    }

    /// Int64 tolerant decoding: accepts Int64, Int, String, Double
    func safeInt64(forKey key: Key) -> Int64 {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Int64(i) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int64(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return 0
    }

    /// Bool tolerant decoding: accepts Bool, Int(0/1), String("true"/"false"/"0"/"1")
    func safeBool(forKey key: Key, defaultValue: Bool = false) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let lower = s.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
        }
        return defaultValue
    }

    /// Legado rules may be objects or JSON strings (double-encoded during backup/export)
    func decodeRule<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        if let obj = try? decodeIfPresent(T.self, forKey: key) { return obj }
        if let str = try? decodeIfPresent(String.self, forKey: key),
           let data = str.data(using: .utf8),
           let obj = try? JSONDecoder().decode(T.self, from: data) { return obj }
        return nil
    }
}

// MARK: - Rule Structures (Legado compatible, high tolerance)

struct SearchRule: Codable {
    var checkKeyWord: String = ""
    var bookList: String = ""
    var name: String = ""
    var author: String = ""
    var coverUrl: String = ""
    var intro: String = ""
    var bookUrl: String = ""
    var wordCount: String = ""
    var lastChapter: String = ""
    var updateTime: String = ""
    var kind: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkKeyWord  = c.safeString(forKey: .checkKeyWord)
        bookList      = c.safeString(forKey: .bookList)
        name          = c.safeString(forKey: .name)
        author        = c.safeString(forKey: .author)
        coverUrl      = c.safeString(forKey: .coverUrl)
        intro         = c.safeString(forKey: .intro)
        bookUrl       = c.safeString(forKey: .bookUrl)
        wordCount     = c.safeString(forKey: .wordCount)
        lastChapter   = c.safeString(forKey: .lastChapter)
        updateTime    = c.safeString(forKey: .updateTime)
        kind          = c.safeString(forKey: .kind)
    }
}

struct BookInfoRule: Codable {
    var initScript: String = ""   // Legado JSON key: "init"
    var name: String = ""
    var author: String = ""
    var coverUrl: String = ""
    var intro: String = ""
    var kind: String = ""
    var wordCount: String = ""
    var lastChapter: String = ""
    var updateTime: String = ""
    var tocUrl: String = ""
    var canReName: String = ""
    var downloadUrls: String = ""  // Legado: download URL rule
    var ttsDice: String = ""       // Legado: TTS random selector

    enum CodingKeys: String, CodingKey {
        case initScript = "init"
        case name, author, coverUrl, intro, kind, wordCount, lastChapter, updateTime, tocUrl, canReName
        case downloadUrls, ttsDice
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        initScript    = c.safeString(forKey: .initScript)
        name          = c.safeString(forKey: .name)
        author        = c.safeString(forKey: .author)
        coverUrl      = c.safeString(forKey: .coverUrl)
        intro         = c.safeString(forKey: .intro)
        kind          = c.safeString(forKey: .kind)
        wordCount     = c.safeString(forKey: .wordCount)
        lastChapter   = c.safeString(forKey: .lastChapter)
        updateTime    = c.safeString(forKey: .updateTime)
        tocUrl        = c.safeString(forKey: .tocUrl)
        canReName     = c.safeString(forKey: .canReName)
        downloadUrls  = c.safeString(forKey: .downloadUrls)
        ttsDice       = c.safeString(forKey: .ttsDice)
    }
}

struct TOCRule: Codable {
    var preUpdateJs: String = ""
    var chapterList: String = ""
    var chapterName: String = ""
    var chapterUrl: String = ""
    var formatJs: String = ""   // Legado: chapter formatting JS
    var isVolume: String = ""
    var isVip: String = ""
    var isPay: String = ""
    var updateTime: String = ""
    var nextTocUrl: String = ""

    enum CodingKeys: String, CodingKey {
        case preUpdateJs, chapterList, chapterName, chapterUrl, formatJs
        case isVolume, isVip, isPay, updateTime, nextTocUrl
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preUpdateJs = c.safeString(forKey: .preUpdateJs)
        chapterList = c.safeString(forKey: .chapterList)
        chapterName = c.safeString(forKey: .chapterName)
        chapterUrl  = c.safeString(forKey: .chapterUrl)
        formatJs    = c.safeString(forKey: .formatJs)
        isVolume    = c.safeString(forKey: .isVolume)
        isVip       = c.safeString(forKey: .isVip)
        isPay       = c.safeString(forKey: .isPay)
        updateTime  = c.safeString(forKey: .updateTime)
        nextTocUrl  = c.safeString(forKey: .nextTocUrl)
    }
}

struct ContentRule: Codable {
    var content: String = ""
    var title: String = ""
    var nextContentUrl: String = ""
    var webJs: String = ""
    var sourceRegex: String = ""
    var replaceRegex: String = ""
    var imageStyle: String = ""
    var imageDecode: String = ""   // Legado: image decode rule
    var payAction: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content        = c.safeString(forKey: .content)
        title          = c.safeString(forKey: .title)
        nextContentUrl = c.safeString(forKey: .nextContentUrl)
        webJs          = c.safeString(forKey: .webJs)
        sourceRegex    = c.safeString(forKey: .sourceRegex)
        replaceRegex   = c.safeString(forKey: .replaceRegex)
        imageStyle     = c.safeString(forKey: .imageStyle)
        imageDecode    = c.safeString(forKey: .imageDecode)
        payAction      = c.safeString(forKey: .payAction)
    }
}

// MARK: - Discover Page Rules (Legado ExploreRule)

struct ExploreRule: Codable {
    var bookList: String = ""
    var name: String = ""
    var author: String = ""
    var intro: String = ""
    var kind: String = ""
    var lastChapter: String = ""
    var updateTime: String = ""
    var bookUrl: String = ""
    var coverUrl: String = ""
    var wordCount: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookList    = c.safeString(forKey: .bookList)
        name        = c.safeString(forKey: .name)
        author      = c.safeString(forKey: .author)
        intro       = c.safeString(forKey: .intro)
        kind        = c.safeString(forKey: .kind)
        lastChapter = c.safeString(forKey: .lastChapter)
        updateTime  = c.safeString(forKey: .updateTime)
        bookUrl     = c.safeString(forKey: .bookUrl)
        coverUrl    = c.safeString(forKey: .coverUrl)
        wordCount   = c.safeString(forKey: .wordCount)
    }
}

// MARK: - Review Rules (Legado ReviewRule)

struct ReviewRule: Codable {
    var review: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        review = c.safeString(forKey: .review)
    }
}

// MARK: - Book Source

struct BookSource: Identifiable, Codable {
    var id: UUID = UUID()
    var bookSourceName: String = ""
    var bookSourceUrl: String = ""
    var bookSourceGroup: String = ""
    var bookSourceComment: String = ""
    var bookSourceType: Int = 0       // 0 = text, 1 = audio, 2 = image, 3 = file
    var bookUrlPattern: String = ""   // Legado: URL match pattern
    var customOrder: Int = 0          // Legado: custom ordering
    var enabled: Bool = true
    var enabledExplore: Bool = true   // Legado: discover page toggle
    var enabledCookieJar: Bool = false // Legado: automatic cookie management
    var enabledReview: Bool = false   // Legado: newer version field
    var searchUrl: String = ""
    var exploreUrl: String = ""       // Discover/category page URL (common Legado field)
    var concurrentRate: String = ""   // Concurrency rate limit
    var header: String = ""           // JSON string, e.g. {"User-Agent":"..."}
    var loginUrl: String = ""
    var loginUi: String = ""          // Legado: login UI configuration JSON
    var loginCheckJs: String = ""     // Legado: executed after search response; skip parsing if login is required
    var respondTime: Int64 = 180000   // Legado: response time (milliseconds)
    var lastUpdateTime: Int64 = 0     // Legado: last update timestamp
    var weight: Int = 0
    var variableComment: String = ""  // Legado: variable comment
    var exploreScreen: String = ""    // Legado: discover page configuration
    var coverDecodeJs: String = ""    // Legado: cover decode JS
    var jsLib: String = ""            // Legado: shared JS library evaluated at source init
    var ruleSearch: SearchRule = SearchRule()
    var ruleExplore: ExploreRule = ExploreRule()  // Legado: discover page rule
    var ruleBookInfo: BookInfoRule = BookInfoRule()
    var ruleToc: TOCRule = TOCRule()
    var ruleContent: ContentRule = ContentRule()
    var ruleReview: ReviewRule = ReviewRule()      // Legado: review rule

    /// Whether this book source must be fetched through a real WebView.
    ///
    /// `bookSourceType` is a CONTENT type (0=text, 1=audio, 2=image, 3=file), NOT a transport
    /// hint — audio sources are ordinary HTTP/JSON APIs and must never be forced through a
    /// WebView (doing so broke audiobook search/detail). Genuine WebView needs are driven
    /// per-request (`requestSpec.useWebView`), by chapter JS (`hasWebJs`), or by the
    /// empty-result WebView retry in TOC/chapter fetch — none of which depend on this flag.
    var needsWebView: Bool { false }

    enum CodingKeys: String, CodingKey {
        case id
        case bookSourceName, bookSourceUrl, bookSourceGroup, bookSourceComment
        case bookSourceType, bookUrlPattern, customOrder
        case enabled, enabledExplore, enabledCookieJar, enabledReview
        case searchUrl, exploreUrl, concurrentRate
        case header, loginUrl, loginUi, loginCheckJs
        case respondTime, lastUpdateTime, weight
        case variableComment, exploreScreen, coverDecodeJs, jsLib
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent, ruleReview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        bookSourceName   = c.safeString(forKey: .bookSourceName)
        bookSourceUrl    = c.safeString(forKey: .bookSourceUrl)
        bookSourceGroup  = c.safeString(forKey: .bookSourceGroup)
        bookSourceComment = c.safeString(forKey: .bookSourceComment)
        bookSourceType   = c.safeInt(forKey: .bookSourceType)
        bookUrlPattern   = c.safeString(forKey: .bookUrlPattern)
        customOrder      = c.safeInt(forKey: .customOrder)
        searchUrl        = c.safeString(forKey: .searchUrl)
        exploreUrl       = c.safeString(forKey: .exploreUrl)
        concurrentRate   = c.safeString(forKey: .concurrentRate)
        header           = c.safeString(forKey: .header)
        loginUrl         = c.safeString(forKey: .loginUrl)
        loginUi          = c.safeString(forKey: .loginUi)
        loginCheckJs     = c.safeString(forKey: .loginCheckJs)
        respondTime      = c.safeInt64(forKey: .respondTime)
        if respondTime == 0 { respondTime = 180000 }  // Legado default value
        lastUpdateTime   = c.safeInt64(forKey: .lastUpdateTime)
        weight           = c.safeInt(forKey: .weight)
        variableComment  = c.safeString(forKey: .variableComment)
        exploreScreen   = c.safeString(forKey: .exploreScreen)
        coverDecodeJs   = c.safeString(forKey: .coverDecodeJs)
        jsLib           = c.safeString(forKey: .jsLib)
        // Legado's enabled field may be Bool, Int 1/0, or String "true"/"false"
        enabled          = c.safeBool(forKey: .enabled, defaultValue: true)
        enabledExplore   = c.safeBool(forKey: .enabledExplore, defaultValue: true)
        enabledCookieJar = c.safeBool(forKey: .enabledCookieJar, defaultValue: false)
        enabledReview    = c.safeBool(forKey: .enabledReview, defaultValue: false)
        // Rule structures: Legado may use objects or JSON strings (double-encoded during backup)
        ruleSearch   = c.decodeRule(SearchRule.self,   forKey: .ruleSearch)   ?? SearchRule()
        ruleExplore  = c.decodeRule(ExploreRule.self,  forKey: .ruleExplore)  ?? ExploreRule()
        ruleBookInfo = c.decodeRule(BookInfoRule.self, forKey: .ruleBookInfo) ?? BookInfoRule()
        ruleToc      = c.decodeRule(TOCRule.self,      forKey: .ruleToc)      ?? TOCRule()
        ruleContent  = c.decodeRule(ContentRule.self,  forKey: .ruleContent)  ?? ContentRule()
        ruleReview   = c.decodeRule(ReviewRule.self,   forKey: .ruleReview)   ?? ReviewRule()
    }

    init() {}

    init(bookSourceUrl: String, bookSourceName: String) {
        self.init()
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
    }
}

// MARK: - Search Results / Book Info

struct OnlineBook: Identifiable {
    var id = UUID()
    var name: String
    var author: String
    var intro: String
    var coverUrl: String
    var bookUrl: String
    var tocUrl: String  // TOC page URL (may be identical to bookUrl)
    var wordCount: String
    var lastChapter: String
    var kind: String  // Category / tag
    var sourceId: UUID
    var sourceName: String
    var runtimeVariables: [String: String]? = nil
}

enum OnlineBookContentKind: Equatable {
    case text
    case audio
    case manga
}

enum OnlineBookContentInference {
    static func infer(
        sourceType: Int?,
        runtimeVariables: [String: String]? = nil,
        urls: [String] = [],
        metadataText: [String] = []
    ) -> OnlineBookContentKind {
        if let sourceKind = kind(fromSourceType: sourceType), sourceKind != .text {
            return sourceKind
        }
        if let runtimeKind = kind(fromRuntimeVariables: runtimeVariables) {
            return runtimeKind
        }
        for url in urls {
            if let urlKind = kind(fromURL: url) {
                return urlKind
            }
        }
        for text in metadataText {
            if let metadataKind = kind(fromMetadataText: text) {
                return metadataKind
            }
        }
        return .text
    }

    private static func kind(fromSourceType sourceType: Int?) -> OnlineBookContentKind? {
        switch sourceType {
        case 1: return .audio
        case 2: return .manga
        default: return .text
        }
    }

    private static func kind(fromRuntimeVariables vars: [String: String]?) -> OnlineBookContentKind? {
        guard let vars, !vars.isEmpty else { return nil }

        for key in ["book.type", "type", "media", "tab", "find_tab", "contentType"] {
            if let kind = kind(fromStructuredValue: vars[key]) {
                return kind
            }
        }

        for (key, value) in vars where key.lowercased().contains("type") || key.lowercased().contains("tab") {
            if let kind = kind(fromStructuredValue: value) {
                return kind
            }
        }

        return nil
    }

    private static func kind(fromURL rawURL: String) -> OnlineBookContentKind? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for payload in dataURLPayloads(from: trimmed) {
            if let kind = kind(fromJSONObject: payload) {
                return kind
            }
        }

        let requestURL = trimmed.split(separator: ",", maxSplits: 1).first.map(String.init) ?? trimmed
        guard let components = URLComponents(string: requestURL) else { return nil }
        for item in components.queryItems ?? [] {
            if ["tab", "type", "media", "mode", "category"].contains(item.name.lowercased()),
               let kind = kind(fromStructuredValue: item.value) {
                return kind
            }
        }
        return nil
    }

    private static func dataURLPayloads(from text: String) -> [[String: Any]] {
        let marker = "data:;base64,"
        var payloads: [[String: Any]] = []
        var searchStart = text.startIndex

        while let markerRange = text.range(
            of: marker,
            options: [.caseInsensitive],
            range: searchStart..<text.endIndex
        ) {
            let base64Start = markerRange.upperBound
            let base64End = text[base64Start...].firstIndex(of: ",") ?? text.endIndex
            let rawBase64 = String(text[base64Start..<base64End])
            let decodedBase64 = rawBase64.removingPercentEncoding ?? rawBase64
            if let data = Data(base64Encoded: decodedBase64),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payloads.append(json)
            }
            searchStart = base64End
        }

        return payloads
    }

    private static func kind(fromJSONObject object: Any) -> OnlineBookContentKind? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if isContentKindKey(key), let kind = kind(fromStructuredValue: value) {
                    return kind
                }
                if let kind = kind(fromJSONObject: value) {
                    return kind
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let kind = kind(fromJSONObject: value) {
                    return kind
                }
            }
        }
        return nil
    }

    private static func isContentKindKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return normalized == "tab"
            || normalized == "type"
            || normalized == "media"
            || normalized == "mode"
            || normalized == "category"
            || normalized == "findtab"
            || normalized == "booktype"
            || normalized == "contenttype"
    }

    private static func kind(fromStructuredValue value: Any?) -> OnlineBookContentKind? {
        guard let value else { return nil }
        if let intValue = value as? Int {
            return kind(fromTypeNumber: intValue)
        }
        if let doubleValue = value as? Double {
            return kind(fromTypeNumber: Int(doubleValue))
        }

        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let intValue = Int(text) {
            return kind(fromTypeNumber: intValue)
        }

        let normalized = text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if normalized == "听书" || normalized == "聽書" || normalized == "有声"
            || normalized == "有聲" || normalized == "audio" || normalized == "audiobook" {
            return .audio
        }
        if normalized == "漫画" || normalized == "漫畫" || normalized == "comic"
            || normalized == "manga" || normalized == "image" {
            return .manga
        }
        return nil
    }

    private static func kind(fromTypeNumber value: Int) -> OnlineBookContentKind? {
        switch value {
        case 1, 32:
            return .audio
        case 2, 64:
            return .manga
        default:
            return nil
        }
    }

    private static func kind(fromMetadataText text: String) -> OnlineBookContentKind? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let audioMarkers = ["当前模式：听书", "当前模式:听书", "目前模式：聽書", "模式：听书", "模式:听书"]
        if audioMarkers.contains(where: { normalized.contains($0) }) {
            return .audio
        }

        let mangaMarkers = ["当前模式：漫画", "当前模式:漫画", "目前模式：漫畫", "模式：漫画", "模式:漫画"]
        if mangaMarkers.contains(where: { normalized.contains($0) }) {
            return .manga
        }

        return kind(fromStructuredValue: normalized)
    }

    /// Mode markers (听书 / 漫画 / 小说…) read from the *source's* persisted runtime
    /// variables. Aggregate sources (光遇 family) keep the active 类型/搜索模式 there
    /// — individual search/discover results often carry no per-book marker at all,
    /// so the source's current mode is the only signal left for routing. Feed these
    /// into `infer`'s `metadataText` (weakest priority: any per-book marker wins).
    static func sourceRuntimeModeMarkers(for source: BookSource?) -> [String] {
        guard let source,
              let json = BookSourceRuntimeStateStore.shared
                  .sourceVariableJSON(for: source.bookSourceUrl),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var markers: [String] = []
        for key in ["发现页类型", "搜索模式"] {
            if let value = dict[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markers.append(value)
            }
        }
        if let more = dict["更多设置"] as? [String: Any],
           let value = more["搜索模式"] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markers.append(value)
        }
        return markers
    }
}

extension OnlineBook {
    func inferredContentKind(source: BookSource?) -> OnlineBookContentKind {
        OnlineBookContentInference.infer(
            sourceType: source?.bookSourceType,
            runtimeVariables: runtimeVariables,
            urls: [bookUrl, tocUrl],
            metadataText: [kind, intro, lastChapter, sourceName]
                + OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        )
    }
}

// MARK: - Online Chapter Reference

struct OnlineChapterRef: Identifiable, Codable {
    var id: UUID = UUID()
    var index: Int
    var title: String
    var url: String
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var cachedFilename: String? = nil  // nil means not yet fetched
    var runtimeVariables: [String: String]? = nil
    var audioStartSeconds: Double? = nil
    var audioDurationSeconds: Double? = nil
}

extension OnlineChapterRef {
    var sanitizedContentURL: String {
        RuleEngine.sanitizeExtractedURL(url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasLoadableContentURL: Bool {
        !sanitizedContentURL.isEmpty
    }

    var shouldRenderAsVolumeSeparator: Bool {
        isVolume || hasStrongVolumeSeparatorTitle || (!hasLoadableContentURL && hasVolumeSeparatorTitle)
    }

    var hasVolumeSeparatorTitle: Bool {
        let title = ReaderHTMLUtilities.displayText(fromHTMLFragment: self.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !title.isEmpty else { return false }
        if Self.strongVolumeSeparatorTitles.contains(title)
            || ["正文", "番外卷", "番外"].contains(title) {
            return true
        }
        if title.range(of: #"^第[0-9一二三四五六七八九十百千万]+卷"#, options: .regularExpression) != nil,
           title.range(of: #"[章节章回][0-9一二三四五六七八九十百千万]*"#, options: .regularExpression) == nil {
            return true
        }
        return false
    }

    private var hasStrongVolumeSeparatorTitle: Bool {
        let title = ReaderHTMLUtilities.displayText(fromHTMLFragment: self.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return Self.strongVolumeSeparatorTitles.contains(title)
    }

    private static var strongVolumeSeparatorTitles: Set<String> {
        ["作品相关", "作品相關", "正文卷"]
    }
}

extension BookSource {
    var legadoReviewContext: ReaderHTMLUtilities.LegadoReviewContext {
        ReaderHTMLUtilities.LegadoReviewContext(
            sourceName: bookSourceName,
            sourceURL: bookSourceUrl,
            sourceVariableJSON: BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: bookSourceUrl)
        )
    }

    var usesLegadoRuntimeSession: Bool {
        !jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func shouldUseLegadoRuntimeFetch(for ruleUrl: String? = nil) -> Bool {
        let url = ruleUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.hasPrefix("data:")
            || url.contains(",{")
            || url.hasPrefix("<js>")
            || url.hasPrefix("@js:")
            || (usesLegadoRuntimeSession && urlContainsRuntimeTemplate(url))
    }

    private func urlContainsRuntimeTemplate(_ url: String) -> Bool {
        guard url.contains("{{") else { return false }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else {
            return false
        }

        let nsRange = NSRange(url.startIndex..., in: url)
        return regex.matches(in: url, range: nsRange).contains { match in
            guard let range = Range(match.range(at: 1), in: url) else { return false }
            let expression = String(url[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            return !Self.fastSearchTemplateExpressions.contains(expression)
        }
    }

    private static let fastSearchTemplateExpressions: Set<String> = [
        "key",
        "page",
        "key,gb2312",
        "key,gbk"
    ]
}
