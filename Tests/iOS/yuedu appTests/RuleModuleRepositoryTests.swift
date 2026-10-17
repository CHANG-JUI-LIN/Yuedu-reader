import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem M6: a repository is an index of modules at one address. A reader subscribes
/// to it, sees each module's state against what is installed, and installs or updates one
/// through the import sheet's preview and the validator (maintainer, 2026-10-17: updates are
/// checked when the page opens and applied only on 「更新」).
@MainActor
@Suite("Module repositories", .serialized)
struct RuleModuleRepositoryTests {
    private static let base = URL(string: "https://modules.example/repo/index.json")!

    private func module(id: String, version: String = "1.0", hosts: [String] = ["example.com"]) -> Data {
        Data("""
        {"id":"\(id)","title":"\(id)","version":"\(version)","requiredVersion":"2.0","hosts":[\(hosts.map { "\"\($0)\"" }.joined(separator: ","))],"modules":[],
         "search":{"request":{"url":"https://example.com/s?q={{keyword}}"},"list":{"items":"li","title":"h3@text"}}}
        """.utf8)
    }

    private func index(_ entries: String, name: String = "範例倉庫") -> Data {
        Data(#"{"name":"\#(name)","modules":[\#(entries)]}"#.utf8)
    }

    private func entry(_ id: String, version: String = "1.0", url: String? = nil) -> String {
        #"{"id":"\#(id)","title":"\#(id) 標題","description":"說明","author":"作者甲","version":"\#(version)","url":"\#(url ?? "\(id).json")"}"#
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleRepositories-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Index

    @Test("an index names itself and its modules; a relative address is the index's neighbour")
    func parse() throws {
        let parsed = try RuleModuleRepositoryIndex.parse(index(entry("a.one") + "," + entry("b.two", url: "https://cdn.example/b.json")),
                                                        from: Self.base)
        #expect(parsed.name == "範例倉庫")
        #expect(parsed.modules.map(\.id) == ["a.one", "b.two"])
        #expect(parsed.modules[0].url.absoluteString == "https://modules.example/repo/a.one.json")
        #expect(parsed.modules[1].url.absoluteString == "https://cdn.example/b.json")
        #expect(parsed.modules[0].title == "a.one 標題")
        #expect(parsed.modules[0].description == "說明")
        #expect(parsed.modules[0].author == "作者甲")
        #expect(parsed.modules[0].version == "1.0")
    }

    @Test("an index that is not one is refused, naming the entry at fault")
    func refusals() {
        func refusal(_ data: Data) -> RuleModuleRepositoryError? {
            do {
                _ = try RuleModuleRepositoryIndex.parse(data, from: Self.base)
                return nil
            } catch {
                return error as? RuleModuleRepositoryError
            }
        }
        #expect(refusal(Data("[1]".utf8)) == .notAnIndex)
        #expect(refusal(Data(#"{"name":" ","modules":[]}"#.utf8)) == .missingName)
        #expect(refusal(index(entry("../up"))) == .invalidEntry(position: 1, field: "id"))
        #expect(refusal(index(entry("a.one", version: "one"))) == .invalidEntry(position: 1, field: "version"))
        #expect(refusal(index(entry("a.one") + "," + entry("b.two", url: "ftp://x.example/b.json")))
                == .invalidEntry(position: 2, field: "url"))
        #expect(refusal(index(entry("a.one") + "," + entry("a.one"))) == .duplicateID("a.one"))
        let many = (0...RuleModuleRepositoryIndex.maximumModules).map { entry("m\($0)") }.joined(separator: ",")
        #expect(refusal(index(many)) == .tooManyModules)
    }

    // MARK: - State

    @Test("each module's state against the installed ones")
    func status() throws {
        let installed = [
            InstalledRuleModule(module: try RuleModuleValidator.validate(module(id: "same")), subscriptionURL: nil,
                                installedAt: .now, updatedAt: .now),
            InstalledRuleModule(module: try RuleModuleValidator.validate(module(id: "older")), subscriptionURL: nil,
                                installedAt: .now, updatedAt: .now),
            InstalledRuleModule(module: try RuleModuleValidator.validate(module(id: "newer", version: "3.0")), subscriptionURL: nil,
                                installedAt: .now, updatedAt: .now),
        ]
        let parsed = try RuleModuleRepositoryIndex.parse(
            index([entry("fresh"), entry("same"), entry("older", version: "1.2"), entry("newer", version: "2.0"), entry("bangumi")]
                .joined(separator: ",")), from: Self.base)
        let states = parsed.modules.map { RuleModuleRepositoryStatus($0, installed: installed) }
        #expect(states == [.notInstalled, .installed, .updateAvailable(installed: "1.0"), .installed, .official])
    }

    // MARK: - Subscriptions

    @Test("subscriptions are kept in order, once each, across launches")
    func subscriptions() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".repositories.json")
        let store = RuleModuleRepositoryStore(file: file)
        try store.add(RuleModuleRepositorySubscription(url: Self.base, name: "範例倉庫"))
        try store.add(RuleModuleRepositorySubscription(url: URL(string: "https://other.example/index.json")!, name: "另一個"))
        try store.add(RuleModuleRepositorySubscription(url: Self.base, name: "改名了"))
        #expect(RuleModuleRepositoryStore(file: file).list().map(\.name) == ["改名了", "另一個"], "the same address is renamed in place")
        try store.remove(url: Self.base)
        #expect(RuleModuleRepositoryStore(file: file).list().map(\.name) == ["另一個"])
    }

    // MARK: - Page model

    private struct Fixture {
        let repositories: RuleModuleRepositoryModel
        let library: RuleModuleLibrary
        let importer: RuleModuleImportModel
    }

    private func fixture(files: @escaping @Sendable () -> [String: Data], folder: URL) -> Fixture {
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder.appendingPathComponent("store")), appVersion: "3.0",
                                        officialFiles: { [] }, availability: nil)
        let download: (String) async throws -> (data: Data, url: URL) = { address in
            guard let data = files()[address], let url = URL(string: address) else { throw URLError(.fileDoesNotExist) }
            return (data, url)
        }
        let repositories = RuleModuleRepositoryModel(store: RuleModuleRepositoryStore(file: folder.appendingPathComponent(".repositories.json")),
                                                     library: library, download: download)
        return Fixture(repositories: repositories, library: library,
                       importer: RuleModuleImportModel(library: library, repositories: repositories, download: download))
    }

    private func subscribe(_ fixture: Fixture, _ address: String) async {
        fixture.importer.reset()
        fixture.importer.address = address
        await fixture.importer.fetch()
        await fixture.importer.commit()
    }

    @Test("an address that holds an index is offered as a repository; one that cannot be read is not kept")
    func subscribe() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [Self.base.absoluteString: index(entry("a.one")),
                     "https://broken.example/index.json": Data(#"{"name":"壞的","modules":[{"id":"x"}]}"#.utf8)]
        let fixture = fixture(files: { files }, folder: folder)

        fixture.importer.address = "https://broken.example/index.json"
        await fixture.importer.fetch()
        #expect(fixture.importer.phase == .failed(RuleModuleRepositoryError.invalidEntry(position: 1, field: "title").message))
        #expect(fixture.repositories.repositories.isEmpty)

        fixture.importer.reset()
        fixture.importer.address = Self.base.absoluteString
        await fixture.importer.fetch()
        guard case .repository(let preview) = fixture.importer.phase else {
            Issue.record("not offered as a repository: \(fixture.importer.phase)")
            return
        }
        #expect(preview.index.name == "範例倉庫")
        #expect(fixture.repositories.repositories.isEmpty, "nothing is kept before 訂閱")
        await fixture.importer.commit()
        #expect(fixture.importer.phase == .subscribed(Self.base))
        #expect(fixture.repositories.repositories.map(\.subscription.name) == ["範例倉庫"])
        #expect(fixture.repositories.repositories.first?.index?.modules.map(\.id) == ["a.one"])
        #expect(RuleModuleRepositoryStore(file: folder.appendingPathComponent(".repositories.json")).list().map(\.url) == [Self.base])
    }

    @Test("an index from a file or pasted text is refused: it has no address to read again")
    func indexWithoutAddress() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = fixture(files: { [:] }, folder: folder)
        let file = folder.appendingPathComponent("index.json")
        try index(entry("a.one")).write(to: file)

        fixture.importer.read(file: .success(file))
        #expect(fixture.importer.phase == .failed(localized("模組倉庫要用網址加入")))
        await fixture.importer.read(clipboard: String(decoding: index(entry("a.one")), as: UTF8.self))
        #expect(fixture.importer.phase == .failed(localized("模組倉庫要用網址加入")))
        #expect(fixture.repositories.repositories.isEmpty)
    }

    @Test("opening the page reads every index again; one that fails says so and keeps its place")
    func load() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleModuleRepositoryStore(file: folder.appendingPathComponent(".repositories.json"))
        try store.add(RuleModuleRepositorySubscription(url: Self.base, name: "舊名字"))
        try store.add(RuleModuleRepositorySubscription(url: URL(string: "https://gone.example/index.json")!, name: "不見了"))
        let files = [Self.base.absoluteString: index(entry("a.one"))]
        let model = fixture(files: { files }, folder: folder).repositories

        await model.load()

        #expect(model.repositories.map(\.subscription.name) == ["範例倉庫", "不見了"], "the index's own name replaces the kept one")
        #expect(model.repositories[0].index?.modules.count == 1)
        guard case .failed = model.repositories[1].state else {
            Issue.record("a failed index is not a failure: \(model.repositories[1].state)")
            return
        }
    }

    @Test("安裝 and 更新 go through the import sheet's preview, from the module's own address")
    func installAndUpdate() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let moduleURL = "https://modules.example/repo/a.one.json"
        let files = Files([Self.base.absoluteString: index(entry("a.one")),
                           moduleURL: module(id: "a.one")])
        let fixture = fixture(files: { files.all }, folder: folder)
        let (model, library, importer) = (fixture.repositories, fixture.library, fixture.importer)
        await subscribe(fixture, Self.base.absoluteString)
        let listed = try #require(model.repositories.first?.index?.modules.first)

        await importer.offer(listed)
        guard case .preview(let preview) = importer.phase else {
            Issue.record("no preview: \(importer.phase)")
            return
        }
        #expect(preview.subscriptionURL?.absoluteString == moduleURL, "檢查更新 on the module's page fetches the same file")
        #expect(preview.replacing == nil)
        await importer.commit()
        #expect(library.module(id: "a.one") != nil)
        #expect(model.status(of: listed) == .installed)

        files.all[moduleURL] = module(id: "a.one", version: "1.1", hosts: ["example.com", "new.example"])
        let newer = try RuleModuleRepositoryIndex.parse(index(entry("a.one", version: "1.1")), from: Self.base).modules[0]
        #expect(model.status(of: newer) == .updateAvailable(installed: "1.0"))
        await importer.offer(newer)
        guard case .preview(let update) = importer.phase else {
            Issue.record("no update preview: \(importer.phase)")
            return
        }
        #expect(update.replacing?.module.id == "a.one")
        #expect(update.addedHosts == ["new.example"], "a site the update adds is shown before anything is written")
        await importer.commit()
        #expect(library.module(id: "a.one")?.module.version == "1.1")
        #expect(library.module(id: "a.one")?.subscriptionURL?.absoluteString == moduleURL)
    }

    @Test("更新 from a repository makes its address the one 檢查更新 reads")
    func updateMovesSubscription() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let moduleURL = "https://modules.example/repo/a.one.json"
        let files = [Self.base.absoluteString: index(entry("a.one", version: "1.1")), moduleURL: module(id: "a.one", version: "1.1")]
        let fixture = fixture(files: { files }, folder: folder)
        try await fixture.library.install(module(id: "a.one"), from: nil)
        await subscribe(fixture, Self.base.absoluteString)
        let listed = try #require(fixture.repositories.repositories.first?.index?.modules.first)

        await fixture.importer.offer(listed)
        await fixture.importer.commit()
        #expect(fixture.library.module(id: "a.one")?.module.version == "1.1")
        #expect(fixture.library.module(id: "a.one")?.subscriptionURL?.absoluteString == moduleURL,
                "a module added from a file, updated from a repository, is checked there from then on")
    }

    @Test("選擇: the chosen modules install and update at once; an update that adds a site waits for its preview")
    func batch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = "https://modules.example/repo/"
        let files = [Self.base.absoluteString: index([entry("fresh"), entry("older", version: "1.1"), entry("wider", version: "1.1"),
                                                      entry("liar"), entry("gone")].joined(separator: ",")),
                     base + "fresh.json": module(id: "fresh"),
                     base + "older.json": module(id: "older", version: "1.1"),
                     base + "wider.json": module(id: "wider", version: "1.1", hosts: ["example.com", "new.example"]),
                     base + "liar.json": module(id: "someone.else")]
        let fixture = fixture(files: { files }, folder: folder)
        try await fixture.library.install(module(id: "older"), from: nil)
        try await fixture.library.install(module(id: "wider"), from: nil)
        await subscribe(fixture, Self.base.absoluteString)
        let entries = try #require(fixture.repositories.repositories.first?.index?.modules)

        let outcome = await fixture.repositories.install(entries)

        #expect(outcome.installed == ["fresh"])
        #expect(outcome.updated == ["older"])
        #expect(outcome.needsReview.map(\.id) == ["wider"], "its new site is shown before it replaces anything")
        #expect(outcome.failed.map(\.id) == ["liar", "gone"])
        #expect(fixture.library.installed(id: "fresh")?.subscriptionURL?.absoluteString == base + "fresh.json")
        #expect(fixture.library.installed(id: "older")?.module.version == "1.1")
        #expect(fixture.library.installed(id: "older")?.subscriptionURL?.absoluteString == base + "older.json")
        #expect(fixture.library.installed(id: "wider")?.module.version == "1.0")
        #expect(fixture.library.installed(id: "someone.else") == nil)
    }

    @Test("停用 takes a module out of every path that uses modules, and keeps it on the 模組 page")
    func disable() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "ModuleSwitches-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        func library() -> RuleModuleLibrary {
            RuleModuleLibrary(store: RuleModuleStore(directory: folder.appendingPathComponent("store")), appVersion: "3.0",
                              officialFiles: { [] }, availability: nil, preferences: preferences)
        }
        let first = library()
        try await first.install(module(id: "a.one"), from: nil)
        try await first.install(module(id: "b.two"), from: nil)

        first.setEnabled(false, id: "a.one")
        #expect(first.modules.map(\.module.id) == ["b.two"])
        #expect(first.module(id: "a.one") == nil)
        #expect(first.installed(id: "a.one") != nil)
        #expect(first.imported.map(\.module.id) == ["a.one", "b.two"])
        #expect(!first.isShownInLibrary("a.one"), "a module turned off has no card in 資源庫")
        #expect(SourceProviderRegistry.moduleProviders(in: first).map(\.module.id) == ["b.two"])

        first.setShownInLibrary(false, id: "b.two")
        #expect(first.modules.map(\.module.id) == ["b.two"], "hidden from 資源庫 is still in use")
        #expect(!first.isShownInLibrary("b.two"))

        let again = library()
        await again.load()
        #expect(again.modules.map(\.module.id) == ["b.two"], "kept across launches")
        #expect(!again.isShownInLibrary("b.two"))
        again.setEnabled(true, id: "a.one")
        #expect(again.modules.map(\.module.id) == ["a.one", "b.two"])

        again.setEnabled(false, id: "b.two")
        try await again.remove(id: "b.two")
        try await again.install(module(id: "b.two"), from: nil)
        #expect(again.isEnabled("b.two") && again.isShownInLibrary("b.two"), "installed again, it starts on")
    }

    @Test("a file that is not the module the index lists is refused")
    func mismatch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["https://modules.example/repo/a.one.json": module(id: "someone.else")]
        let importer = fixture(files: { files }, folder: folder).importer
        let listed = try RuleModuleRepositoryIndex.parse(index(entry("a.one")), from: Self.base).modules[0]
        await importer.offer(listed)
        #expect(importer.phase == .failed(RuleModuleRepositoryError.differentModule(listed: "a.one", file: "someone.else").message))
    }
}

/// Files a test changes between two downloads.
private final class Files: @unchecked Sendable {
    var all: [String: Data]
    init(_ all: [String: Data]) { self.all = all }
}
