import Foundation

/// Modules for `#Preview`s: written to a scratch folder, read by a library of their own.
@MainActor
enum RuleModulePreviewData {
    static func json(id: String, title: String) -> String {
        """
        {"id":"\(id)","title":"\(title)","description":"某書店的新書與排行。","author":"someone","site":"https://example.com",
         "version":"1.0.0","hosts":["example.com","img.example.com"],
         "modules":[{"id":"new","title":"新書","description":"每週新書","request":{"url":"https://example.com/new"},
                     "list":{"items":"li","title":"h3@text"}}],
         "search":{"request":{"url":"https://example.com/s?q={{keyword}}"},"list":{"items":"li","title":"h3@text"}}}
        """
    }

    /// A module whose first list has one parameter of each kind the section form offers.
    static let listsJSON = """
        {"id":"preview.module","title":"某書店","description":"某書店的新書與排行。","version":"1.0.0","hosts":["example.com"],
         "modules":[{"id":"new","title":"新書","params":[
                       {"name":"q","title":"關鍵字","type":"input"},
                       {"name":"n","title":"數量","type":"count","value":20},
                       {"name":"sort","title":"排序","type":"enumeration",
                        "enumOptions":[{"title":"熱門","value":"hot"},{"title":"最新","value":"new"}]},
                       {"name":"page","type":"page"}],
                     "request":{"url":"https://example.com/new?q={{q}}&n={{n}}&sort={{sort}}&p={{page}}"},
                     "list":{"items":"li","title":"h3@text"}},
                    {"id":"top","title":"排行","request":{"url":"https://example.com/top"},"list":{"items":"li","title":"h3@text"}}]}
        """

    static func module() -> RuleModule {
        do {
            return try JSONDecoder().decode(RuleModule.self, from: Data(listsJSON.utf8))
        } catch {
            AppLogger.error("Preview module not decoded", error: error, level: .warning)
            return RuleModule(id: "preview.module", title: "某書店", description: nil, author: nil, site: nil, version: "1.0.0",
                              requiredVersion: nil, hosts: [], rateLimit: nil, modules: [], search: nil)
        }
    }

    /// A library holding `module()`.
    static func listsLibrary() -> RuleModuleLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModulePreview-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        do {
            try store.install(Data(listsJSON.utf8), from: nil)
        } catch {
            AppLogger.error("Preview module not installed", error: error, level: .warning)
        }
        let library = RuleModuleLibrary(store: store)
        Task { await library.load() }
        return library
    }

    static func library(_ titles: [String]) -> RuleModuleLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModulePreview-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        for (index, title) in titles.enumerated() {
            let id = index == 0 ? "example.newbooks" : "example.\(index)"
            do {
                try store.install(Data(json(id: id, title: title).utf8), from: URL(string: "https://example.com/\(id).json"))
            } catch {
                AppLogger.error("Preview module not installed", error: error, level: .warning)
            }
        }
        let library = RuleModuleLibrary(store: store)
        Task { await library.load() }
        return library
    }
}
