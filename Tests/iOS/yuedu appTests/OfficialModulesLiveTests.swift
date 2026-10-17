import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem M8: each bundled official module against its real site — its search, the
/// first page of every list, openBD's and Open Library's lookups and なろう's reading. Off by default; the saved
/// replies in `OfficialModuleFilesTests` cover the rules. Run with
/// `TEST_RUNNER_YUEDU_MODULES_LIVE=1` in the environment of `xcodebuild`.
@MainActor
@Suite("Official modules, live", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_MODULES_LIVE"] == "1", "Set YUEDU_MODULES_LIVE=1 to ask the real sites"))
struct OfficialModulesLiveTests {
    private static let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Assets", isDirectory: true)

    private func provider(_ id: String) throws -> (ModuleProvider, RuleModuleClient, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialLive-\(UUID().uuidString)")
        let loaded = OfficialRuleModules.load(OfficialRuleModules.files(in: Self.assets), appVersion: RuleModuleVersion.app)
        let module = try #require(loaded.first { $0.module.id == id }).module
        let client = RuleModuleClient(store: RuleModuleStore(directory: folder))
        return (ModuleProvider(module: module, client: client), client, folder)
    }

    private func titles(_ page: CollectionPage) -> [String] {
        page.entries.compactMap { entry in
            guard case .item(_, let summary, _) = entry else { return nil }
            return summary.title
        }
    }

    /// Every list's first page and the search, each with at least one work.
    private func check(_ id: String, keyword: String) async throws {
        let (provider, _, folder) = try provider(id)
        defer { try? FileManager.default.removeItem(at: folder) }
        for entry in provider.module.modules {
            let page = try await provider.page(ofList: entry.id ?? "", parameters: [:], after: nil)
            let found = titles(page)
            print("⟐ live \(id)/\(entry.id ?? ""): \(found.count) — \(found.prefix(3))")
            #expect(!found.isEmpty, "\(id)/\(entry.id ?? "") listed nothing")
        }
        if provider.module.search != nil {
            let found = titles(try #require(try await provider.search(keyword)))
            print("⟐ live \(id) search \(keyword): \(found.count) — \(found.prefix(3))")
            #expect(!found.isEmpty, "\(id) found nothing for \(keyword)")
        }
    }

    @Test("Bangumi") func bangumi() async throws { try await check("bangumi", keyword: "葬送のフリーレン") }

    @Test("AniList") func aniList() async throws { try await check("anilist", keyword: "Frieren") }

    @Test("openBD looks up a Japanese ISBN")
    func openBD() async throws {
        let (provider, _, folder) = try provider("openbd")
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try #require(try await provider.lookupItems(isbn: "9784750320236"))
        print("⟐ live openbd: \(items.map(\.name))")
        #expect(items.first?.name.isEmpty == false)
    }

    @Test("Open Library searches, and fills a copy by its ISBN with a cover and a description")
    func openLibrary() async throws {
        try await check("openlibrary", keyword: "Fantastic Mr Fox")
        let (provider, _, folder) = try provider("openlibrary")
        defer { try? FileManager.default.removeItem(at: folder) }
        let isbn = try #require(ExternalIdentifier.normalized(.isbn13, "9780140328721"))
        let query = MetadataFillQuery(copyID: UUID(), title: "Fantastic Mr Fox", authors: ["Roald Dahl"], identifiers: [isbn],
                                      copySource: .localLibrary, missing: [.cover, .intro, .tags])
        let result = try await ModuleFillProvider(provider: provider).lookUp(query)
        print("⟐ live openlibrary: \(result.values.keys.map(\.rawValue).sorted())")
        #expect(result.values[.intro] != nil, "the work's description, from its page")
        #expect(result.values[.cover] != nil, "the edition's cover")
    }

    @Test("なろう lists, searches and reads a chapter")
    func narou() async throws {
        try await check("narou", keyword: "転生")
        let (provider, client, folder) = try provider("narou")
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try #require(try await provider.search("無職転生"))
        guard case .item(_, _, .moduleBook(let book)) = try #require(page.entries.first) else {
            Issue.record("not a book the module reads")
            return
        }
        let chapters = try await client.tableOfContents(bookURL: book.reference.bookURL, title: "", in: provider.module)
        let first = try #require(chapters.first { !$0.isVolume })
        print("⟐ live narou: \(chapters.count) chapters, first \(first.title)")
        let built = try await client.chapterPackage(bookId: UUID(), chapterIndex: 0, chapter: first, in: provider.module)
        #expect(built.normalizedHTML.count > 200, "the chapter has its text")
    }
}
