import Combine
import Foundation
import SwiftUI

// MARK: - 安全解析擴充（容錯 null / 缺失 key / 類型不匹配）

extension KeyedDecodingContainer {
    /// 遇到 null 或 key 缺失都回傳 ""，不拋錯
    func safeString(forKey key: Key) -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        // Legado 某些欄位可能被序列化為數字而非字串
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return ""
    }

    /// Int 容錯：接受 Int、String("0")、Double、Bool
    func safeInt(forKey key: Key) -> Int {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return 0
    }

    /// Int64 容錯：接受 Int64、Int、String、Double
    func safeInt64(forKey key: Key) -> Int64 {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Int64(i) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int64(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return 0
    }

    /// Bool 容錯：接受 Bool、Int(0/1)、String("true"/"false"/"0"/"1")
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

    /// Legado 規則可能是物件或 JSON 字串（備份/匯出時雙重編碼）
    func decodeRule<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        if let obj = try? decodeIfPresent(T.self, forKey: key) { return obj }
        if let str = try? decodeIfPresent(String.self, forKey: key),
           let data = str.data(using: .utf8),
           let obj = try? JSONDecoder().decode(T.self, from: data) { return obj }
        return nil
    }
}

// MARK: - 規則結構（Legado 相容，高容錯）

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
    var downloadUrls: String = ""  // Legado: 下載地址規則

    enum CodingKeys: String, CodingKey {
        case initScript = "init"
        case name, author, coverUrl, intro, kind, wordCount, lastChapter, updateTime, tocUrl, canReName
        case downloadUrls
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
    }
}

struct TOCRule: Codable {
    var preUpdateJs: String = ""
    var chapterList: String = ""
    var chapterName: String = ""
    var chapterUrl: String = ""
    var formatJs: String = ""   // Legado：章節格式化 JS
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
    var imageDecode: String = ""   // Legado: 圖片解碼規則
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

// MARK: - 發現頁規則（Legado ExploreRule）

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

// MARK: - 書源

struct BookSource: Identifiable, Codable {
    var id: UUID = UUID()
    var bookSourceName: String = ""
    var bookSourceUrl: String = ""
    var bookSourceGroup: String = ""
    var bookSourceComment: String = ""
    var bookSourceType: Int = 0       // 0 = 純文本, 1 = 音頻, 2 = 圖片, 3 = 文件
    var bookUrlPattern: String = ""   // Legado: URL 匹配模式
    var customOrder: Int = 0          // Legado: 自定義排序
    var enabled: Bool = true
    var enabledExplore: Bool = true   // Legado: 發現頁開關
    var enabledCookieJar: Bool = false // Legado: 自動 Cookie 管理
    var enabledReview: Bool = false   // Legado: 較新版本字段
    var searchUrl: String = ""
    var exploreUrl: String = ""       // 發現/分類頁 URL（Legado 常見字段）
    var concurrentRate: String = ""   // 並發限速
    var header: String = ""           // JSON 字串，如 {"User-Agent":"..."}
    var loginUrl: String = ""
    var loginUi: String = ""          // Legado: 登入介面配置 JSON
    var loginCheckJs: String = ""     // Legado：搜尋回應後執行，若回傳需登入則不解析結果
    var respondTime: Int64 = 180000   // Legado: 回應時間（毫秒）
    var lastUpdateTime: Int64 = 0     // Legado: 最後更新時間戳
    var weight: Int = 0
    var ruleSearch: SearchRule = SearchRule()
    var ruleExplore: ExploreRule = ExploreRule()  // Legado: 發現頁規則
    var ruleBookInfo: BookInfoRule = BookInfoRule()
    var ruleToc: TOCRule = TOCRule()
    var ruleContent: ContentRule = ContentRule()

    /// 此書源是否需要 WebView JS 渲染
    var needsWebView: Bool { bookSourceType == 1 }

    enum CodingKeys: String, CodingKey {
        case id
        case bookSourceName, bookSourceUrl, bookSourceGroup, bookSourceComment
        case bookSourceType, bookUrlPattern, customOrder
        case enabled, enabledExplore, enabledCookieJar, enabledReview
        case searchUrl, exploreUrl, concurrentRate
        case header, loginUrl, loginUi, loginCheckJs
        case respondTime, lastUpdateTime, weight
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
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
        if respondTime == 0 { respondTime = 180000 }  // Legado 默認值
        lastUpdateTime   = c.safeInt64(forKey: .lastUpdateTime)
        weight           = c.safeInt(forKey: .weight)
        // Legado 的 enabled 可能是 Bool、Int 1/0 或 String "true"/"false"
        enabled          = c.safeBool(forKey: .enabled, defaultValue: true)
        enabledExplore   = c.safeBool(forKey: .enabledExplore, defaultValue: true)
        enabledCookieJar = c.safeBool(forKey: .enabledCookieJar, defaultValue: false)
        enabledReview    = c.safeBool(forKey: .enabledReview, defaultValue: false)
        // Rule 結構：Legado 可能是物件或 JSON 字串（備份時雙重編碼）
        ruleSearch   = c.decodeRule(SearchRule.self,   forKey: .ruleSearch)   ?? SearchRule()
        ruleExplore  = c.decodeRule(ExploreRule.self,  forKey: .ruleExplore)  ?? ExploreRule()
        ruleBookInfo = c.decodeRule(BookInfoRule.self, forKey: .ruleBookInfo) ?? BookInfoRule()
        ruleToc      = c.decodeRule(TOCRule.self,      forKey: .ruleToc)      ?? TOCRule()
        ruleContent  = c.decodeRule(ContentRule.self,  forKey: .ruleContent)  ?? ContentRule()
    }

    init() {}

    init(bookSourceUrl: String, bookSourceName: String) {
        self.init()
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
    }
}

// MARK: - 搜尋結果 / 書籍資訊

struct OnlineBook: Identifiable {
    var id = UUID()
    var name: String
    var author: String
    var intro: String
    var coverUrl: String
    var bookUrl: String
    var tocUrl: String  // 目錄頁 URL（可能與 bookUrl 相同）
    var wordCount: String
    var lastChapter: String
    var kind: String  // 分類 / 標籤
    var sourceId: UUID
    var sourceName: String
    var runtimeVariables: [String: String]? = nil
}

// MARK: - 線上章節引用

struct OnlineChapterRef: Identifiable, Codable {
    var id: UUID = UUID()
    var index: Int
    var title: String
    var url: String
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var cachedFilename: String? = nil  // nil 表示尚未抓取
    var runtimeVariables: [String: String]? = nil
}
