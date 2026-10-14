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
