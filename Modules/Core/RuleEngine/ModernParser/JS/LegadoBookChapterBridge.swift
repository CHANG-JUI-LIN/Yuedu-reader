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
    var readConfig: LegadoReadConfigBridge { get }

    func setUseReplaceRule(_ enabled: Bool)
    func getVariable(_ key: String) -> String
    func setVariable(_ key: String, _ value: String)
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

    func setUseReplaceRule(_ enabled: Bool) {
        readConfig.useReplaceRule = enabled
    }

    func getVariable(_ key: String) -> String {
        state.withLock { $0.variables[key] } ?? ""
    }

    func setVariable(_ key: String, _ value: String) {
        state.withLock { $0.variables[key] = value }
    }

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
        return state
    }
}

@objc protocol LegadoChapterBridgeExport: JSExport {
    var index: Int { get set }
    var title: String { get set }
    var order: Int { get set }
    var url: String { get set }

    /// Legado chapter.isVip() — returns whether this chapter requires payment.
    /// lyc sources call `chapter.isVip()` and fall back to `result.v` on error.
    @objc(isVip) func isVip() -> Bool
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

    init(index: Int = 0, title: String = "", order: Int = 0, url: String = "", isVip: Bool = false) {
        state = Locked(State(index: index, title: title, order: order, url: url, isVip: isVip))
        super.init()
    }

    /// The `chapter` for the context a JS timeout reset creates (`LegadoBookBridge.replacementForNewContext()`).
    func replacementForNewContext() -> LegadoChapterBridge {
        let chapter = state.withLock { $0 }
        return LegadoChapterBridge(
            index: chapter.index, title: chapter.title, order: chapter.order,
            url: chapter.url, isVip: chapter.isVip
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
}
