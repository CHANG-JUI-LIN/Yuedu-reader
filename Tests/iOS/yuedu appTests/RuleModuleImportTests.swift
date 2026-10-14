import Foundation
import Testing
@testable import yuedu_app

/// Phase 6e: the installed modules' one owner, and 新增模組 / 檢查更新 before any view.
@MainActor
@Suite("Module library and import", .serialized)
struct RuleModuleImportTests {
    private func moduleJSON(id: String = "test.module", version: String = "1.0", hosts: [String] = ["example.com"]) -> Data {
        let object: [String: Any] = [
            "id": id, "title": "測試模組", "author": "someone", "version": version, "hosts": hosts,
            "modules": [[
                "id": "new", "title": "新書", "description": "每週新書",
                "request": ["url": "https://example.com/new"],
                "list": ["items": "li", "title": "h3@text"],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeLibrary() -> (RuleModuleLibrary, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModuleImport-\(UUID().uuidString)")
        return (RuleModuleLibrary(store: RuleModuleStore(directory: folder), appVersion: "2.0.8"), folder)
    }

    /// Serves `files` by address; anything else is a 404.
    private func downloader(_ files: [String: Data]) -> (String) async throws -> (data: Data, url: URL) {
        { address in
            guard let data = files[address] else {
                throw SourceFailure(kind: .rejected, status: 404, underlying: FetchError.httpError(404))
            }
            return (data, URL(string: address)!)
        }
    }

    @Test("the library publishes what the store holds, after each write")
    func library() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await library.load()
        #expect(library.isLoaded && library.modules.isEmpty)

        try await library.install(moduleJSON(), from: URL(string: "https://example.com/m.json"))
        #expect(library.modules.map(\.module.id) == ["test.module"])
        #expect(library.module(id: "test.module")?.subscriptionURL == URL(string: "https://example.com/m.json"))

        try await library.update(id: "test.module", with: moduleJSON(version: "1.1"))
        #expect(library.module(id: "test.module")?.module.version == "1.1")

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("broken/module.json"))
        await library.load()
        #expect(library.failures.map(\.folder) == ["broken"])

        try await library.remove(id: "broken")
        try await library.remove(id: "test.module")
        #expect(library.modules.isEmpty && library.failures.isEmpty)
    }

    @Test("from an address: shown first, written only on commit")
    func addFromAddress() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RuleModuleImportModel(library: library, download: downloader(["https://share.example/m.json": moduleJSON()]))
        model.address = " https://share.example/m.json "
        await model.fetch()
        guard case .preview(let preview) = model.phase else { Issue.record("no preview: \(model.phase)"); return }
        #expect(preview.module.title == "測試模組")
        #expect(preview.subscriptionURL == URL(string: "https://share.example/m.json"))
        #expect(preview.replacing == nil && preview.addedHosts.isEmpty)
        await library.load()
        #expect(library.modules.isEmpty, "nothing is written before the reader confirms")

        await model.commit()
        guard case .done(let installed) = model.phase else { Issue.record("not done: \(model.phase)"); return }
        #expect(installed.module.id == "test.module")
        #expect(library.modules.count == 1)
    }

    @Test("a refused file says why, and an installed one is not added twice")
    func refusals() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        var js = try JSONSerialization.jsonObject(with: moduleJSON()) as! [String: Any]
        var entries = js["modules"] as! [[String: Any]]
        entries[0]["list"] = ["items": "li", "title": "h3@text@js:result"]
        js["modules"] = entries
        let model = RuleModuleImportModel(library: library, download: downloader([
            "https://share.example/js.json": try JSONSerialization.data(withJSONObject: js),
        ]))
        model.address = "https://share.example/js.json"
        await model.fetch()
        #expect(model.phase == .failed(RuleModuleRejection.javaScript(field: "modules[0].list.title").message))

        model.address = "https://share.example/missing.json"
        await model.fetch()
        guard case .failed = model.phase else { Issue.record("a 404 was not a failure"); return }

        try await library.install(moduleJSON(), from: nil)
        await model.read(clipboard: String(data: moduleJSON(), encoding: .utf8))
        #expect(model.phase == .failed(RuleModuleStoreError.alreadyInstalled("test.module").message))

        await model.read(clipboard: "  ")
        #expect(model.phase == .failed(localized("剪貼簿為空")))
    }

    @Test("the clipboard: an address is fetched, text is read as the file")
    func clipboard() async {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RuleModuleImportModel(library: library, download: downloader(["https://share.example/m.json": moduleJSON()]))
        await model.read(clipboard: "https://share.example/m.json")
        guard case .preview(let fetched) = model.phase else { Issue.record("address not fetched"); return }
        #expect(fetched.subscriptionURL != nil)

        model.reset()
        await model.read(clipboard: String(data: moduleJSON(id: "pasted"), encoding: .utf8))
        guard case .preview(let pasted) = model.phase else { Issue.record("text not read"); return }
        #expect(pasted.module.id == "pasted")
        #expect(pasted.subscriptionURL == nil, "pasted text has nowhere to check for updates")
    }

    @Test("檢查更新: the same version is up to date; a newer one says which sites it adds before replacing")
    func update() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = "https://share.example/m.json"
        let installed = try await library.install(moduleJSON(), from: URL(string: address))

        let same = RuleModuleImportModel(library: library, download: downloader([address: moduleJSON()]))
        await same.checkForUpdate(installed)
        #expect(same.phase == .upToDate(localized("已是最新版本")))

        let other = RuleModuleImportModel(library: library, download: downloader([address: moduleJSON(id: "other", version: "2")]))
        await other.checkForUpdate(installed)
        #expect(other.phase == .failed(RuleModuleStoreError.differentModule(expected: "test.module", offered: "other").message))

        let newer = RuleModuleImportModel(library: library, download: downloader([
            address: moduleJSON(version: "1.1", hosts: ["example.com", "cdn.example.net"]),
        ]))
        await newer.checkForUpdate(installed)
        guard case .preview(let preview) = newer.phase else { Issue.record("no preview: \(newer.phase)"); return }
        #expect(preview.addedHosts == ["cdn.example.net"])
        #expect(library.module(id: "test.module")?.module.version == "1.0", "nothing replaced before the reader confirms")
        await newer.commit()
        #expect(library.module(id: "test.module")?.module.version == "1.1")
        #expect(library.module(id: "test.module")?.subscriptionURL == URL(string: address))
    }

    @Test("a module's books are named by the module")
    func providerName() async throws {
        let key = SourceInstanceKey(type: .module, id: "never.installed")
        #expect(FilledMetadata.providerName(key) == "never.installed")
    }

    @Test("download: through WebFetcher, and a redirect to a private address is never sent")
    func download() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let fetcher = WebFetcher(session: URLSession(configuration: configuration))
        ModuleStub.install([
            "share.example/m.json": .json(String(data: moduleJSON(), encoding: .utf8)!),
            "share.example/moved.json": .redirect("http://192.168.1.1/m.json"),
            "share.example/gone.json": .status(410),
        ])
        let file = try await RuleModuleClient.download("https://share.example/m.json", fetcher: fetcher)
        #expect(try RuleModuleValidator.validate(file.data, appVersion: "2.0.8").id == "test.module")

        await #expect(throws: SourceFailure.self) { try await RuleModuleClient.download("https://share.example/moved.json", fetcher: fetcher) }
        #expect(!ModuleStub.urls.contains { $0.contains("192.168.1.1") }, "the redirect is never followed")
        do {
            _ = try await RuleModuleClient.download("https://share.example/gone.json", fetcher: fetcher)
            Issue.record("a 410 was read as a file")
        } catch let failure as SourceFailure {
            #expect(failure.kind == .rejected && failure.status == 410)
        }
        await #expect(throws: SourceFailure.self) { try await RuleModuleClient.download("file:///etc/hosts", fetcher: fetcher) }
    }
}
