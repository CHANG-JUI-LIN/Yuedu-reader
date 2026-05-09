import Combine
import Foundation
import SwiftUI

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
    var ruleSearch: SearchRule = SearchRule()
    var ruleExplore: ExploreRule = ExploreRule()  // Legado: discover page rule
    var ruleBookInfo: BookInfoRule = BookInfoRule()
    var ruleToc: TOCRule = TOCRule()
    var ruleContent: ContentRule = ContentRule()
    var ruleReview: ReviewRule = ReviewRule()      // Legado: review rule

    /// Whether this book source requires WebView JS rendering
    var needsWebView: Bool { bookSourceType == 1 }

    enum CodingKeys: String, CodingKey {
        case id
        case bookSourceName, bookSourceUrl, bookSourceGroup, bookSourceComment
        case bookSourceType, bookUrlPattern, customOrder
        case enabled, enabledExplore, enabledCookieJar, enabledReview
        case searchUrl, exploreUrl, concurrentRate
        case header, loginUrl, loginUi, loginCheckJs
        case respondTime, lastUpdateTime, weight
        case variableComment, exploreScreen, coverDecodeJs
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
        exploreScreen    = c.safeString(forKey: .exploreScreen)
        coverDecodeJs    = c.safeString(forKey: .coverDecodeJs)
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
}
