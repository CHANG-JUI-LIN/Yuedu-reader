import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@Suite("TestFlight crash regressions", .serialized)
@MainActor
struct TestFlightCrashRegressionTests {
    @Test("EPUB source acquisition uses spines rather than navigation anchors")
    func sourceChaptersFollowSpines() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        entries["OPS/nav.xhtml"] = Data(EPUBTestFixtures.xhtml(title: "Contents", body: """
        <nav epub:type="toc"><ol>
        <li><a href="chapter1.xhtml#first">First</a></li>
        <li><a href="chapter1.xhtml#second">Second</a></li>
        <li><a href="chapter1.xhtml#third">Third</a></li>
        </ol></nav>
        """).utf8)
        let url = try await EPUBTestFixtures.makeArchive(entries: entries)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = try await PublicationSession.open(sourceURL: url)
        #expect(session.tocEntries.count == 3)
        #expect(session.chapters.count == 1)
        #expect(session.readingChapters.count == 1)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
        var texts: [Int: String] = [:]
        for chapter in session.readingChapters {
            let result = await builder.localChapterText(at: chapter.index)
            #expect(result.status == .available)
            texts[chapter.index] = result.text
        }
        let source = AIBookContentAdapter(bookID: UUID(), chapters: session.readingChapters) { texts[$0] }
        #expect(source.chunkSections.count == 1)
        #expect(source.manifest.chapters[0].order == 0)
        for invalid in [-1, 1, Int.max] {
            await #expect(throws: PublicationSessionError.self) { try await session.chapterHTML(at: invalid) }
            await #expect(throws: PublicationSessionError.self) { try await session.chapterDataSize(at: invalid) }
        }
    }

    @Test("scalar request bodies serialize without Objective-C exceptions", arguments: ["true", "false", "123", "null", "[1,2]", "{\"a\":1}"])
    func scalarRequestBodies(_ json: String) throws {
        let request = AnalyzeUrl(ruleUrl: "https://example.com/api,{\"method\":\"POST\",\"body\":\(json)}")
        let body = try #require(request.body)
        let actual = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) as AnyObject
        let expected = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as AnyObject
        #expect(actual.isEqual(expected))
    }

    @Test("image rules decode signed bytes without recursively bridging JS arrays")
    func imageBytes() {
        let engine = JSCoreEngine()
        #expect(engine.evaluateBytes("[0, 127, -128, 255, 256, -1]", data: Data()) == Data([0, 127, 128, 255, 0, 255]))
        #expect(engine.evaluateBytes("'AAH/'", data: Data()) == Data([0, 1, 255]))
        #expect(engine.evaluateBytes("result", data: Data([2, 4, 8])) == Data([2, 4, 8]))
    }

    @Test("malformed image arrays do not allocate or bridge a nested graph", arguments: [
        "new Array(4294967295)", "[1,,3]", "[NaN]", "[Infinity]", "[{}]", "var a=[]; a.push(a); a"
    ])
    func malformedImageBytes(_ script: String) {
        #expect(JSCoreEngine().evaluateBytes(script, data: Data()) == nil)
    }

    @Test("replacement templates retain Foundation capture and escape semantics", arguments: [
        "$0", "$1/$2", "\\$1", "\\\\$1", "$12", "$9", "tail\\", "$01", "中文😀$2"
    ])
    func replacementTemplates(_ template: String) throws {
        let regex = try NSRegularExpression(pattern: "(a)(b)?")
        let content = "a ab abc 😀"
        let expected = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: template)
        let rule = ReplaceRule(name: "capture", pattern: "(a)(b)?", replacement: template)
        #expect(ReplaceRuleEngine.replacing(rule, in: content, limit: 1024) == expected)
        #expect(ReplaceRuleEngine.apply(rule, to: content) == expected)
    }

    @Test("expanding regex output is rejected before allocation")
    func replacementBudget() throws {
        func rule(_ pattern: String, _ template: String) -> ReplaceRule {
            ReplaceRule(name: "budget", pattern: pattern, replacement: template)
        }
        #expect(ReplaceRuleEngine.replacing(rule("(?=.)", String(repeating: "x", count: 100)), in: "abcdefghij", limit: 100) == nil)
        #expect(ReplaceRuleEngine.replacing(rule("(.*)", "$1$1$1"), in: String(repeating: "x", count: 50), limit: 100) == nil)
        #expect(ReplaceRuleEngine.replacing(rule("(?=.)", "x"), in: "ab", limit: 4) == "xaxb")
    }

    @Test("repeated list values retain separate diffable row identities")
    func repeatedListItems() {
        let row: (Int) -> Text = { Text("Row \($0)") }
        let controller = HostedCollectionListController<Int, Text>(row: row, showsSeparator: { _ in true })
        for (version, items) in [[1, 1, 2, 1], [2, 1, 1], [1], []].enumerated() {
            controller.update(items: items, contentVersion: version, animated: false, row: row,
                              showsSeparator: { _ in true }, usesSystemMargins: { _ in false }, drawsCellSurface: { _ in false })
            #expect(controller.collectionView.numberOfItems(inSection: 0) == items.count)
        }
    }

    @Test("organizer controls survive apply, reset and regeneration")
    func organizerReviewBindings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let book = ReadingBook(title: "Book", contentFilename: "book.epub")
        store.replaceBooksFromSync([book])
        let candidate = AIBookshelfOrganizer.Book(id: book.id, title: book.title, author: book.author)
        let model = AIBookshelfOrganizerModel()
        model.proposal = AIBookshelfProposal(books: [candidate], assignments: [book.id: "Fantasy"], existingGroups: [])
        let group = try #require(model.proposal?.groups.first)
        let move = try #require(group.moves.first)
        let name = model.nameBinding(for: group)
        let included = model.inclusionBinding(for: move, in: group)
        name.wrappedValue = "Fiction"
        included.wrappedValue = false
        #expect(model.proposal?.includedCount == 0)
        included.wrappedValue = true
        model.apply(to: store)
        #expect(store.books.first?.group == "Fiction")
        #expect(model.proposal == nil)
        #expect(name.wrappedValue == group.name)
        #expect(included.wrappedValue == move.isIncluded)
        name.wrappedValue = "Late edit"
        included.wrappedValue = false
        #expect(model.proposal == nil)
        model.proposal = AIBookshelfProposal(books: [candidate], assignments: [book.id: "New"], existingGroups: [])
        name.wrappedValue = "Stale edit"
        included.wrappedValue = false
        #expect(model.proposal?.groups.first?.name == "New")
        #expect(model.proposal?.includedCount == 1)
        model.reset()
        #expect(included.wrappedValue)
    }

    @Test("concurrent network diagnostics retain a complete exchange")
    func concurrentNetworkDiagnostics() async {
        let store = ModernParserBridge.NetworkExchangeStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<256 {
                group.addTask {
                    let token = String(index)
                    store.latest = .init(url: token, status: token, length: index, bodyHead: token)
                    if let snapshot = store.latest {
                        #expect(snapshot.url == snapshot.status)
                        #expect(snapshot.bodyHead == String(snapshot.length))
                    }
                    if index.isMultiple(of: 3) { store.latest = nil }
                }
            }
        }
    }

    @Test("appearance import publishes UI state on the main actor")
    func appearanceImportIsolation() async throws {
        let settings = GlobalSettings.shared
        let saved = settings.appearanceBuiltInThemeColors
        defer { settings.appearanceBuiltInThemeColors = saved }
        var colors = AppearanceThemePreset.classic.customCopy(name: "Import")
        colors.accentHex = 0x123456
        let bundle = AppearanceCustomizationBundle(snapshot: AppearanceCustomizationSnapshot(
            builtInThemeColors: [AppearanceThemePreset.classicID: colors]
        ))
        let data = try JSONEncoder().encode(bundle)
        // The change is reported on the thread that makes it.
        let recorder = ObservationRecorder { settings.appearanceBuiltInThemeColors }
        defer { recorder.cancel() }
        try await importAppearanceFromBackground(data)
        #expect(recorder.changeCount >= 1)
        #expect(!recorder.changedOffMain)
        #expect(settings.appearanceBuiltInThemeColors[AppearanceThemePreset.classicID]?.accentHex == 0x123456)
    }

    @Test("curl only offers a paper back when the next front exists", arguments: [false, true])
    func curlBookBoundaries(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [String(repeating: "Reading page.\n", count: 80)]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        try #require(engine.totalPages > 1)
        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: isRTL, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.isDoubleSided = true
        func forward(_ page: UIViewController) -> UIViewController? {
            isRTL ? coordinator.pageViewController(pvc, viewControllerBefore: page)
                  : coordinator.pageViewController(pvc, viewControllerAfter: page)
        }
        let first = engine.pageViewController(at: 0)
        let back = try #require(forward(first) as? PageBackViewController)
        let next = try #require(forward(back))
        #expect((next as? any PageIndexProviding)?.globalPageIndex == 1)
        let last = engine.pageViewController(at: engine.totalPages - 1)
        #expect(forward(last) == nil)
    }

    @Test("shipping app declares the photo-library add purpose")
    func photoLibraryPurpose() throws {
        let purpose = try #require(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        #expect(!purpose.isEmpty)
    }
}

@concurrent
private func importAppearanceFromBackground(_ data: Data) async throws {
    try await GlobalSettings.shared.importAppearanceCustomizationPackage(from: data)
}
