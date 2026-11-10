import Foundation
import JavaScriptCore

@objc protocol LegadoReadConfigBridgeExport: JSExport {
    var useReplaceRule: Bool { get set }
}

/// Lock-guarded like `LegadoBookBridge`: a timeout reset copies it while the abandoned script
/// may still be writing it.
@objc final class LegadoReadConfigBridge: NSObject, LegadoReadConfigBridgeExport {
    private let enabled: Locked<Bool>

    init(useReplaceRule: Bool = true) {
        enabled = Locked(useReplaceRule)
        super.init()
    }

    @objc var useReplaceRule: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }
}

@objc protocol LegadoBookBridgeExport: JSExport {
    var durChapterIndex: Int { get set }
    var durChapterTitle: String { get set }
    var order: Int { get set }
    var type: Int { get set }
    var imageStyle: String { get set }
    var name: String { get set }
    var author: String { get set }
    var coverUrl: String { get set }
    var bookUrl: String { get set }
    var tocUrl: String { get set }
    var abstract: String { get set }
    var intro: String { get set }
    var kind: String { get set }
    var wordCount: String { get set }
    var latestChapterTitle: String { get set }
    var origin: String { get set }
    var originName: String { get set }
    var totalChapterNum: Int { get set }
    var readConfig: LegadoReadConfigBridge { get }

    func setUseReplaceRule(_ enabled: Bool)
    /// Legado `Book.setReverseToc` / `getReverseToc`: the book's TOC is the parsed list reversed
    /// (`BookChapterList.analyzeChapterList`, every fork agrees). 就去看网 and the other 通用书源
    /// in YCK 1329–1331 set it from their detail rules.
    func setReverseToc(_ reverseToc: Bool)
    func getReverseToc() -> Bool
    func getVariable(_ key: String) -> String
    func setVariable(_ key: String, _ value: String)
    /// Legado `BaseBook.putVariable(key, value)` — the `RuleDataInterface` name for
    /// `setVariable`; a null value removes the key. 掌阅书城 calls it.
    func putVariable(_ key: String, _ value: JSValue)
    func putCustomVariable(_ value: JSValue)
    func getCustomVariable() -> String
}

/// Legado's mutable `book` object. Its state is behind a lock: a JS timeout reset abandons the
/// old context with its script still running and hands the new context a copy
/// (`replacementForNewContext()`), so the abandoned script may be writing this one while the
/// copy is read — and an unguarded `String` written from two threads crashes like
/// `LegadoSourceBridge.put` did (Crashlytics 61eb93e6…).
@objc final class LegadoBookBridge: NSObject, LegadoBookBridgeExport {
    private struct State: Sendable {
        var durChapterIndex: Int
        var durChapterTitle: String
        var order: Int
        var type: Int
        var imageStyle: String
        var name: String
        var author: String
        var coverUrl: String
        var bookUrl: String
        var tocUrl: String
        var abstract: String
        var intro = ""
        var kind = ""
        var wordCount = ""
        var latestChapterTitle = ""
        var origin = ""
        var originName = ""
        var totalChapterNum = 0
        var reverseToc = false
        var variables: [String: String]
    }

    private let state: Locked<State>
    @objc let readConfig: LegadoReadConfigBridge

    init(
        durChapterIndex: Int = 0,
        durChapterTitle: String = "",
        order: Int = 0,
        type: Int = 0,
        imageStyle: String = "",
        name: String = "",
        author: String = "",
        coverUrl: String = "",
        bookUrl: String = "",
        tocUrl: String = "",
        abstract: String = "",
        intro: String = "",
        kind: String = "",
        wordCount: String = "",
        latestChapterTitle: String = "",
        origin: String = "",
        originName: String = "",
        totalChapterNum: Int = 0,
        reverseToc: Bool = false,
        variables: [String: String] = [:]
    ) {
        state = Locked(State(
            durChapterIndex: durChapterIndex,
            durChapterTitle: durChapterTitle,
            order: order,
            type: type,
            imageStyle: imageStyle,
            name: name,
            author: author,
            coverUrl: coverUrl,
            bookUrl: bookUrl,
            tocUrl: tocUrl,
            abstract: abstract,
            intro: intro,
            kind: kind,
            wordCount: wordCount,
            latestChapterTitle: latestChapterTitle,
            origin: origin,
            originName: originName,
            totalChapterNum: totalChapterNum,
            reverseToc: reverseToc,
            variables: variables
        ))
        readConfig = LegadoReadConfigBridge()
        super.init()
    }

    private init(state snapshot: State, useReplaceRule: Bool) {
        state = Locked(snapshot)
        readConfig = LegadoReadConfigBridge(useReplaceRule: useReplaceRule)
        super.init()
    }

    /// The `book` for the context a JS timeout reset creates: what this one holds now, as its
    /// own object. The abandoned script keeps this one, so its later writes stay out of the
    /// new context.
    func replacementForNewContext() -> LegadoBookBridge {
        LegadoBookBridge(state: state.withLock { $0 }, useReplaceRule: readConfig.useReplaceRule)
    }

    @objc var durChapterIndex: Int {
        get { state.withLock { $0.durChapterIndex } }
        set { state.withLock { $0.durChapterIndex = newValue } }
    }
    @objc var durChapterTitle: String {
        get { state.withLock { $0.durChapterTitle } }
        set { state.withLock { $0.durChapterTitle = newValue } }
    }
    @objc var order: Int {
        get { state.withLock { $0.order } }
        set { state.withLock { $0.order = newValue } }
    }
    @objc var type: Int {
        get { state.withLock { $0.type } }
        set { state.withLock { $0.type = newValue } }
    }
    @objc var imageStyle: String {
        get { state.withLock { $0.imageStyle } }
        set { state.withLock { $0.imageStyle = newValue } }
    }
    @objc var name: String {
        get { state.withLock { $0.name } }
        set { state.withLock { $0.name = newValue } }
    }
    @objc var author: String {
        get { state.withLock { $0.author } }
        set { state.withLock { $0.author = newValue } }
    }
    @objc var coverUrl: String {
        get { state.withLock { $0.coverUrl } }
        set { state.withLock { $0.coverUrl = newValue } }
    }
    @objc var bookUrl: String {
        get { state.withLock { $0.bookUrl } }
        set { state.withLock { $0.bookUrl = newValue } }
    }
    @objc var tocUrl: String {
        get { state.withLock { $0.tocUrl } }
        set { state.withLock { $0.tocUrl = newValue } }
    }
    @objc var abstract: String {
        get { state.withLock { $0.abstract } }
        set { state.withLock { $0.abstract = newValue } }
    }
    @objc var intro: String {
        get { state.withLock { $0.intro } }
        set { state.withLock { $0.intro = newValue } }
    }
    @objc var kind: String {
        get { state.withLock { $0.kind } }
        set { state.withLock { $0.kind = newValue } }
    }
    @objc var wordCount: String {
        get { state.withLock { $0.wordCount } }
        set { state.withLock { $0.wordCount = newValue } }
    }
    @objc var latestChapterTitle: String {
        get { state.withLock { $0.latestChapterTitle } }
        set { state.withLock { $0.latestChapterTitle = newValue } }
    }
    @objc var origin: String {
        get { state.withLock { $0.origin } }
        set { state.withLock { $0.origin = newValue } }
    }
    @objc var originName: String {
        get { state.withLock { $0.originName } }
        set { state.withLock { $0.originName = newValue } }
    }
    @objc var totalChapterNum: Int {
        get { state.withLock { $0.totalChapterNum } }
        set { state.withLock { $0.totalChapterNum = newValue } }
    }

    func setUseReplaceRule(_ enabled: Bool) {
        readConfig.useReplaceRule = enabled
    }

    func setReverseToc(_ reverseToc: Bool) {
        state.withLock { $0.reverseToc = reverseToc }
    }

    func getReverseToc() -> Bool {
        state.withLock { $0.reverseToc }
    }

    func getVariable(_ key: String) -> String {
        state.withLock { $0.variables[key] } ?? ""
    }

    func setVariable(_ key: String, _ value: String) {
        state.withLock { $0.variables[key] = value }
    }

    func putVariable(_ key: String, _ value: JSValue) {
        if value.isNull || value.isUndefined {
            state.withLock { _ = $0.variables.removeValue(forKey: key) }
        } else {
            setVariable(key, value.toString() ?? "")
        }
    }

    func putCustomVariable(_ value: JSValue) { putVariable("custom", value) }

    func getCustomVariable() -> String { getVariable("custom") }

    func runtimeVariables() -> [String: String] {
        state.withLock { $0.variables }
    }

    func runtimeStateVariables() -> [String: String] {
        let book = state.withLock { $0 }
        var state: [String: String] = [
            "book.durChapterIndex": "\(book.durChapterIndex)",
            "book.order": "\(book.order)",
            "book.type": "\(book.type)"
        ]
        if !book.durChapterTitle.isEmpty {
            state["book.durChapterTitle"] = book.durChapterTitle
        }
        if !book.imageStyle.isEmpty {
            state["book.imageStyle"] = book.imageStyle
        }
        if !book.name.isEmpty {
            state["book.name"] = book.name
        }
        if !book.author.isEmpty {
            state["book.author"] = book.author
        }
        if !book.coverUrl.isEmpty {
            state["book.coverUrl"] = book.coverUrl
        }
        if !book.bookUrl.isEmpty {
            state["book.bookUrl"] = book.bookUrl
        }
        if !book.tocUrl.isEmpty {
            state["book.tocUrl"] = book.tocUrl
        }
        if !book.abstract.isEmpty {
            state["book.abstract"] = book.abstract
        }
        let fields: [(String, String)] = [
            ("book.intro", book.intro), ("book.kind", book.kind),
            ("book.wordCount", book.wordCount), ("book.latestChapterTitle", book.latestChapterTitle),
            ("book.origin", book.origin), ("book.originName", book.originName)
        ]
        for (key, value) in fields where !value.isEmpty {
            state[key] = value
        }
        if book.totalChapterNum > 0 {
            state["book.totalChapterNum"] = "\(book.totalChapterNum)"
        }
        if book.reverseToc {
            state[Self.reverseTocRuntimeKey] = "true"
        }
        return state
    }

    /// The runtime variable carrying `setReverseToc(true)` from the stage that set it to the TOC.
    static let reverseTocRuntimeKey = "book.reverseToc"
}

@objc protocol LegadoChapterBridgeExport: JSExport {
    var index: Int { get set }
    var title: String { get set }
    var order: Int { get set }
    var url: String { get set }

    /// Legado chapter.isVip() — returns whether this chapter requires payment.
    /// lyc sources call `chapter.isVip()` and fall back to `result.v` on error.
    @objc(isVip) func isVip() -> Bool

    /// Legado `BookChapter.putVariable(key, value)` / `getVariable(key)`: the chapter's own
    /// variables, the same ones `java.put` writes while the chapter is in scope and `java.get`
    /// reads back when its content loads. 言情小说 (YCK1330) keeps each chapter's next-page
    /// selector this way from its TOC rule.
    func putVariable(_ key: String, _ value: JSValue)
    func getVariable(_ key: String) -> String
}

/// Legado's mutable `chapter` object, lock-guarded and copied on a timeout reset for the same
/// reason as `LegadoBookBridge`.
@objc final class LegadoChapterBridge: NSObject, LegadoChapterBridgeExport {
    private struct State: Sendable {
        var index: Int
        var title: String
        var order: Int
        var url: String
        var isVip: Bool
    }

    private let state: Locked<State>
    /// The chapter scope `java.put` writes at this moment (TOC row, content page, next-page
    /// rule); nil when no chapter is in scope, where Legado's `chapter` is null.
    private let chapterScope: (() -> RuleData?)?
    /// What earlier stages stored on the chapter (`OnlineChapterRef.runtimeVariables`): the
    /// TOC-time puts a content rule reads back.
    private let storedVariables: [String: String]

    init(
        index: Int = 0, title: String = "", order: Int = 0, url: String = "", isVip: Bool = false,
        chapterScope: (() -> RuleData?)? = nil, storedVariables: [String: String] = [:]
    ) {
        state = Locked(State(index: index, title: title, order: order, url: url, isVip: isVip))
        self.chapterScope = chapterScope
        self.storedVariables = storedVariables
        super.init()
    }

    /// The `chapter` for the context a JS timeout reset creates (`LegadoBookBridge.replacementForNewContext()`).
    func replacementForNewContext() -> LegadoChapterBridge {
        let chapter = state.withLock { $0 }
        return LegadoChapterBridge(
            index: chapter.index, title: chapter.title, order: chapter.order,
            url: chapter.url, isVip: chapter.isVip,
            chapterScope: chapterScope, storedVariables: storedVariables
        )
    }

    @objc var index: Int {
        get { state.withLock { $0.index } }
        set { state.withLock { $0.index = newValue } }
    }
    @objc var title: String {
        get { state.withLock { $0.title } }
        set { state.withLock { $0.title = newValue } }
    }
    @objc var order: Int {
        get { state.withLock { $0.order } }
        set { state.withLock { $0.order = newValue } }
    }
    @objc var url: String {
        get { state.withLock { $0.url } }
        set { state.withLock { $0.url = newValue } }
    }
    @objc var isVipValue: Bool {
        get { state.withLock { $0.isVip } }
        set { state.withLock { $0.isVip = newValue } }
    }

    @objc(isVip) func isVip() -> Bool {
        isVipValue
    }

    func putVariable(_ key: String, _ value: JSValue) {
        guard let variables = chapterScope?() else {
            AppLogger.parse("chapter.putVariable with no chapter in scope", context: ["key": key])
            return
        }
        variables.putVariable(key: key, value: value.isNull || value.isUndefined ? nil : value.toString())
    }

    func getVariable(_ key: String) -> String {
        if let value = chapterScope?()?.getVariable(key: key), !value.isEmpty { return value }
        return storedVariables[key] ?? ""
    }
}
