import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem plan, M2: the official modules are bundled module files, read through the
/// import validator, listed before the imported ones, and their ids are reserved.
@MainActor
@Suite("Official modules", .serialized)
struct OfficialRuleModulesTests {
    private static let repoFiles = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Assets", isDirectory: true)

    private func json(id: String, title: String? = nil, requiredVersion: String = "2.0") -> Data {
        Data("""
        {"id":"\(id)","title":"\(title ?? id)","version":"1.0","requiredVersion":"\(requiredVersion)","hosts":["example.com"],"modules":[],
         "search":{"request":{"url":"https://example.com/s?q={{keyword}}"},"list":{"items":"li","title":"h3@text"}}}
        """.utf8)
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialModules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("official"), withIntermediateDirectories: true)
        return folder
    }

    private func write(_ data: Data, _ name: String, in folder: URL) throws {
        try data.write(to: folder.appendingPathComponent("official").appendingPathComponent(name))
    }

    @Test("every bundled file passes the import validator in the running app, and the app carries each one")
    func bundledFilesValidate() throws {
        let sources = OfficialRuleModules.files(in: Self.repoFiles)
        for file in sources {
            #expect(throws: Never.self, "\(file.lastPathComponent)") {
                try RuleModuleValidator.validate(Data(contentsOf: file), appVersion: RuleModuleVersion.app)
            }
        }
        let bundled = Set(OfficialRuleModules.bundledFiles.map(\.lastPathComponent))
        #expect(bundled == Set(sources.map(\.lastPathComponent)), "the bundle has exactly the repository's files")
        #expect(OfficialRuleModules.load(OfficialRuleModules.bundledFiles, appVersion: RuleModuleVersion.app).count == sources.count)
    }

    @Test("a file is read only under its own reserved id; one that fails is left out; ids keep their order")
    func load() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(json(id: "anilist"), "official-module-anilist.json", in: folder)
        try write(json(id: "bangumi"), "official-module-bangumi.json", in: folder)
        try write(json(id: "openbd"), "official-module-narou.json", in: folder)
        try write(json(id: "someone.else"), "official-module-someone.else.json", in: folder)
        try write(Data("not json".utf8), "official-module-rakuten-books.json", in: folder)

        let loaded = OfficialRuleModules.load(OfficialRuleModules.files(in: folder.appendingPathComponent("official")),
                                              appVersion: "3.0")
        #expect(loaded.map(\.module.id) == ["bangumi", "anilist"])
        #expect(loaded.allSatisfy { $0.isOfficial })
        #expect(loaded.allSatisfy { $0.subscriptionURL == nil })
    }

    @Test("the library lists the official modules first; 匯入的模組 holds only the imported; CHN has no なろう")
    func library() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(json(id: "narou"), "official-module-narou.json", in: folder)
        try write(json(id: "bangumi"), "official-module-bangumi.json", in: folder)
        let store = RuleModuleStore(directory: folder.appendingPathComponent("store"))
        try store.install(json(id: "example.mine"), from: nil)
        let official = folder.appendingPathComponent("official")

        let library = RuleModuleLibrary(store: store, appVersion: "3.0", officialFiles: { OfficialRuleModules.files(in: official) },
                                        availability: nil)
        await library.load()
        #expect(library.modules.map(\.module.id) == ["bangumi", "narou", "example.mine"])
        #expect(library.official.map(\.module.id) == ["bangumi", "narou"])
        #expect(library.imported.map(\.module.id) == ["example.mine"])
        #expect(library.module(id: "bangumi")?.isOfficial == true, "a section's form and a row find it by id")

        let suite = "OfficialModules-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("CHN", forKey: PublicLibraryAvailability.countryKey)
        let china = RuleModuleLibrary(store: store, appVersion: "3.0", officialFiles: { OfficialRuleModules.files(in: official) },
                                      availability: PublicLibraryAvailability(defaults: defaults))
        await china.load()
        #expect(china.modules.map(\.module.id) == ["bangumi", "example.mine"])
    }

    @Test("an import cannot take an official id; an official module's cache is not a module folder")
    func reservedIDs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleModuleStore(directory: folder.appendingPathComponent("store"))
        #expect(throws: RuleModuleStoreError.reservedID("bangumi")) {
            try store.install(json(id: "bangumi"), from: nil)
        }

        let cache = store.cacheDirectory(id: "bangumi")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cache.appendingPathComponent("page.json"))
        let listing = store.list()
        #expect(listing.modules.isEmpty)
        #expect(listing.failures.isEmpty, "the cache under .official is skipped, never reported as a module that cannot be read")
        #expect(store.cacheDirectory(id: "example.mine").path.hasSuffix("store/example.mine/cache"))
    }

    @Test("the import sheet refuses an official id before anything is written")
    func importSheet() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder.appendingPathComponent("store")),
                                        appVersion: "3.0", officialFiles: { [] }, availability: nil)
        let model = RuleModuleImportModel(library: library, download: { _ in throw URLError(.notConnectedToInternet) })
        await model.read(clipboard: String(decoding: json(id: "openbd"), as: UTF8.self))
        guard case .failed(let message) = model.phase else {
            Issue.record("not refused: \(model.phase)")
            return
        }
        #expect(message == RuleModuleStoreError.reservedID("openbd").message)
    }
}
