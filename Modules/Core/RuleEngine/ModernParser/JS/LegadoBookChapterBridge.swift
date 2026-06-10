import Foundation
import JavaScriptCore

@objc protocol LegadoReadConfigBridgeExport: JSExport {
    var useReplaceRule: Bool { get set }
}

@objc final class LegadoReadConfigBridge: NSObject, LegadoReadConfigBridgeExport {
    @objc var useReplaceRule: Bool = true
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
    var abstract: String { get set }
    var readConfig: LegadoReadConfigBridge { get }

    func setUseReplaceRule(_ enabled: Bool)
    func getVariable(_ key: String) -> String
    func setVariable(_ key: String, _ value: String)
}

@objc final class LegadoBookBridge: NSObject, LegadoBookBridgeExport {
    @objc var durChapterIndex: Int
    @objc var durChapterTitle: String
    @objc var order: Int
    @objc var type: Int
    @objc var imageStyle: String
    @objc var name: String
    @objc var author: String
    @objc var coverUrl: String
    @objc var abstract: String
    @objc let readConfig = LegadoReadConfigBridge()

    private var variables: [String: String]

    init(
        durChapterIndex: Int = 0,
        durChapterTitle: String = "",
        order: Int = 0,
        type: Int = 0,
        imageStyle: String = "",
        name: String = "",
        author: String = "",
        coverUrl: String = "",
        abstract: String = "",
        variables: [String: String] = [:]
    ) {
        self.durChapterIndex = durChapterIndex
        self.durChapterTitle = durChapterTitle
        self.order = order
        self.type = type
        self.imageStyle = imageStyle
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.abstract = abstract
        self.variables = variables
        super.init()
    }

    func setUseReplaceRule(_ enabled: Bool) {
        readConfig.useReplaceRule = enabled
    }

    func getVariable(_ key: String) -> String {
        variables[key] ?? ""
    }

    func setVariable(_ key: String, _ value: String) {
        variables[key] = value
    }

    func runtimeVariables() -> [String: String] {
        variables
    }

    func runtimeStateVariables() -> [String: String] {
        var state: [String: String] = [
            "book.durChapterIndex": "\(durChapterIndex)",
            "book.order": "\(order)",
            "book.type": "\(type)"
        ]
        if !durChapterTitle.isEmpty {
            state["book.durChapterTitle"] = durChapterTitle
        }
        if !imageStyle.isEmpty {
            state["book.imageStyle"] = imageStyle
        }
        if !name.isEmpty {
            state["book.name"] = name
        }
        if !author.isEmpty {
            state["book.author"] = author
        }
        if !coverUrl.isEmpty {
            state["book.coverUrl"] = coverUrl
        }
        if !abstract.isEmpty {
            state["book.abstract"] = abstract
        }
        return state
    }
}

@objc protocol LegadoChapterBridgeExport: JSExport {
    var index: Int { get set }
    var title: String { get set }
    var order: Int { get set }
    var url: String { get set }
}

@objc final class LegadoChapterBridge: NSObject, LegadoChapterBridgeExport {
    @objc var index: Int
    @objc var title: String
    @objc var order: Int
    @objc var url: String

    init(index: Int = 0, title: String = "", order: Int = 0, url: String = "") {
        self.index = index
        self.title = title
        self.order = order
        self.url = url
        super.init()
    }
}
