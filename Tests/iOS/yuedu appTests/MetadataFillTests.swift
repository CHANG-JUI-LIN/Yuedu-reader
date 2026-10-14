import Foundation
import Testing
@testable import yuedu_app

/// Unified library Phase 3a-1: filling a copy's empty fields automatically.
@MainActor
@Suite("Metadata fill runner", .serialized)
struct MetadataFillRunnerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let openLibrary = SourceInstanceKey(type: .bibliographic, id: "openlibrary")
    private let source = SourceInstanceKey(type: .bookSource, id: "https://source.example")
    private let isbn = ExternalIdentifier.normalized(.isbn13, "9787536692930")!

    @Test("only empty fields are written; title and authors never are")
    func onlyEmptyFields() async throws {
        let copy = candidate(values: [value(.intro, "檔案的簡介", .localLibrary)])
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [
            .title: .text("別的書名"), .authors: .texts(["別人"]), .intro: .text("資料庫的簡介"), .tags: .texts(["科幻"]),
        ]))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([copy])

        let written = try #require(writes.all.first)
        #expect(Set(written.values.map(\.field)) == [.tags])
        #expect(provider.queries.first?.missing.contains(.intro) == false)
        #expect(provider.queries.first?.missing.contains(.title) == false)
    }

    @Test("an A-level match may fill a missing cover and add identifiers")
    func aLevelCoverAndIdentifiers() async throws {
        let work = ExternalIdentifier.normalized(.openLibraryWork, "OL1W")!
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(
            values: [.cover: .text("abc.jpg")], identifiers: [work]))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([candidate(hasOwnCover: false)])

        let written = try #require(writes.all.first)
        #expect(written.values.map(\.field) == [.cover])
        #expect(written.identifiers == [work])
    }

    @Test("a copy with its own cover is never given one")
    func ownCoverKept() async throws {
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.cover: .text("abc.jpg")]))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([candidate(hasOwnCover: true)])

        #expect(provider.queries.first?.missing.contains(.cover) == false)
        #expect(writes.all.isEmpty)
    }

    @Test("a B-level match writes no identifier and no cover")
    func bLevelGuards() async throws {
        let provider = StubProvider(key: source, grade: .b, answer: .init(
            values: [.cover: .text("abc.jpg"), .intro: .text("來源簡介")],
            identifiers: [ExternalIdentifier.normalized(.openLibraryWork, "OL1W")!]))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([candidate(hasOwnCover: false)])

        let written = try #require(writes.all.first)
        #expect(written.values.map(\.field) == [.intro])
        #expect(written.identifiers.isEmpty)
        #expect(provider.queries.first?.missing.contains(.cover) == false)
    }

    @Test("a field the reader overrode (even to nothing) or locked is not asked for")
    func decisionsAreRespected() async throws {
        let id = UUID()
        let copy = candidate(id: id, decisions: [
            .override(anchor: .copy(id), field: .intro, value: .text(""), decidedAt: t0),
            .lock(anchor: .copy(id), field: .tags, value: nil, decidedAt: t0),
        ])
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.intro: .text("簡介"), .tags: .texts(["科幻"])]))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([copy])

        let missing = try #require(provider.queries.first?.missing)
        #expect(!missing.contains(.intro) && !missing.contains(.tags))
        #expect(writes.all.isEmpty)
    }

    @Test("what one provider filled is not asked of the next")
    func providersInOrder() async throws {
        let first = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.intro: .text("資料庫簡介")]))
        let second = StubProvider(key: source, grade: .b, answer: .init(values: [.intro: .text("來源簡介"), .tags: .texts(["玄幻"])]))
        let (runner, writes, _) = try makeRunner([first, second])

        await runner.fill([candidate()])

        #expect(second.queries.first?.missing.contains(.intro) == false)
        #expect(writes.all.flatMap(\.values).map(\.value) == [.text("資料庫簡介"), .texts(["玄幻"])])
    }

    @Test("a copy with nothing missing asks nobody")
    func nothingMissing() async throws {
        let full = candidate(hasOwnCover: true, values: [
            value(.intro, "簡介", .localLibrary), value(.tags, "科幻", .localLibrary), value(.series, "三體", .localLibrary),
            value(.language, "zh", .localLibrary), value(.publisher, "重慶", .localLibrary),
        ])
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.intro: .text("x")]))
        let (runner, _, _) = try makeRunner([provider])

        await runner.fill([full])

        #expect(provider.queries.isEmpty)
    }

    @Test("a provider that cannot look a copy up is not asked and leaves no ledger entry")
    func cannotLookUp() async throws {
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.intro: .text("x")]), needsISBN: true)
        let (runner, _, ledger) = try makeRunner([provider])
        let copy = candidate(identifiers: [])

        await runner.fill([copy])

        #expect(provider.queries.isEmpty)
        #expect(ledger.entry(copyID: copy.copyID, provider: openLibrary) == nil)
    }

    @Test("found and empty answers are not asked again; a failure is asked again after seven days")
    func ledgerSkips() async throws {
        let found = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.tags: .texts(["科幻"])]))
        let empty = StubProvider(key: source, grade: .b, answer: .init(values: [:]))
        let clock = Clock(t0)
        let (runner, _, ledger) = try makeRunner([found, empty], now: { clock.now })
        let copy = candidate()

        await runner.fill([copy])
        await runner.fill([copy])
        #expect(found.queries.count == 1 && empty.queries.count == 1)
        #expect(ledger.entry(copyID: copy.copyID, provider: openLibrary)?.outcome == .found)
        #expect(ledger.entry(copyID: copy.copyID, provider: source)?.outcome == .empty)

        let failing = StubProvider(key: openLibrary, grade: .a, answer: nil)
        let (failingRunner, _, failingLedger) = try makeRunner([failing], now: { clock.now })
        await failingRunner.fill([copy])
        #expect(failingLedger.entry(copyID: copy.copyID, provider: openLibrary)?.outcome == .failed)
        clock.now = t0.addingTimeInterval(6 * 86_400)
        await failingRunner.fill([copy])
        #expect(failing.queries.count == 1)
        clock.now = t0.addingTimeInterval(7 * 86_400 + 1)
        await failingRunner.fill([copy])
        #expect(failing.queries.count == 2)
    }

    @Test("a copy whose title, author or identifiers changed is asked again")
    func changedInputsAskAgain() async throws {
        let provider = StubProvider(key: source, grade: .b, answer: .init(values: [:]))
        let (runner, _, _) = try makeRunner([provider])
        var copy = candidate()

        await runner.fill([copy])
        copy.title = "三體II"
        await runner.fill([copy])

        #expect(provider.queries.count == 2)
    }

    @Test("the least complete copy is asked first, and the run stops at its limit")
    func orderAndLimit() async throws {
        let provider = StubProvider(key: source, grade: .b, answer: .init(values: [:]))
        let (runner, _, _) = try makeRunner([provider])
        let complete = candidate(title: "有封面有簡介", hasOwnCover: true, values: [value(.intro, "簡介", .localLibrary)])
        let bare = candidate(title: "什麼都沒有", authors: [])
        let middle = candidate(title: "只有封面", hasOwnCover: true)

        await runner.fill([complete, middle, bare], limit: 2)

        #expect(provider.queries.map(\.title) == ["什麼都沒有", "只有封面"])
    }

    @Test("a filled value keeps the sidecar's own record of the copy's source")
    func keepsSidecarSourceItem() async throws {
        let item = SourceItemKey(instance: SourceInstanceKey(type: .calibre, id: "c"), item: "u")
        let provider = StubProvider(key: openLibrary, grade: .a, answer: .init(values: [.intro: .text("簡介")],
                                                                             sourceItem: SourceItemKey(instance: openLibrary, item: "/works/OL1W")))
        let (runner, writes, _) = try makeRunner([provider])

        await runner.fill([candidate(sidecarSourceItem: item)])

        let written = try #require(writes.all.first)
        #expect(written.sourceItem == item)
        #expect(written.values.first?.provider == openLibrary)
        #expect(written.values.first?.sourceItem?.item == "/works/OL1W")
        #expect(written.values.first?.fetchedAt == t0)
    }

    // MARK: - Helpers

    private func makeRunner(_ providers: [any MetadataFillProvider], now: @escaping @MainActor () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) })
        throws -> (MetadataFillRunner, Writes, MetadataFillLedger) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fill-\(UUID().uuidString)")
        let ledger = MetadataFillLedger(worksDirectory: directory)
        let writes = Writes()
        let runner = MetadataFillRunner(providers: providers, ledger: ledger, write: { writes.all.append($0) }, now: now)
        return (runner, writes, ledger)
    }

    private func candidate(
        id: UUID = UUID(), title: String = "三體", authors: [String] = ["劉慈欣"], identifiers: [ExternalIdentifier]? = nil,
        hasOwnCover: Bool = false, values: [MetadataValue] = [], decisions: [WorkDecision] = [],
        sidecarSourceItem: SourceItemKey? = nil
    ) -> MetadataFillCandidate {
        MetadataFillCandidate(
            copyID: id, title: title, authors: authors, identifiers: identifiers ?? [isbn],
            copySource: .localLibrary, sidecarSourceItem: sidecarSourceItem ?? .copy(id),
            hasOwnCover: hasOwnCover, values: values, decisions: decisions)
    }

    private func value(_ field: MetadataField, _ text: String, _ provider: SourceInstanceKey) -> MetadataValue {
        MetadataValue(field: field, value: .text(text), provider: provider, sourceItem: nil, fetchedAt: t0)
    }
}

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class Writes {
    var all: [ImportedMetadata] = []
}

@MainActor
private final class StubProvider: MetadataFillProvider {
    let key: SourceInstanceKey
    let grade: MetadataMatchGrade
    /// Nil throws.
    let answer: MetadataFillResult?
    let needsISBN: Bool
    var queries: [MetadataFillQuery] = []

    init(key: SourceInstanceKey, grade: MetadataMatchGrade, answer: MetadataFillResult?, needsISBN: Bool = false) {
        self.key = key
        self.grade = grade
        self.answer = answer
        self.needsISBN = needsISBN
    }

    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        !needsISBN || query.identifiers.contains { $0.scheme == .isbn13 }
    }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        queries.append(query)
        guard let answer else { throw URLError(.badServerResponse) }
        return answer
    }
}

@MainActor
@Suite("Metadata fill ledger", .serialized)
struct MetadataFillLedgerTests {
    private let provider = SourceInstanceKey(type: .bibliographic, id: "openlibrary")

    @Test("entries survive a reload from disk")
    func persists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)

        MetadataFillLedger(worksDirectory: directory).record(copyID: id, provider: provider, outcome: .empty, inputs: "k", at: at)

        let reloaded = MetadataFillLedger(worksDirectory: directory).entry(copyID: id, provider: provider)
        #expect(reloaded == .init(outcome: .empty, at: at, inputs: "k"))
    }

    @Test("an unreadable ledger is kept aside, not written over, and the run starts empty")
    func unreadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("metadata-fill.json"))

        let ledger = MetadataFillLedger(worksDirectory: directory)
        ledger.record(copyID: UUID(), provider: provider, outcome: .found, inputs: "k", at: Date())

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("metadata-fill.corrupt-") })
    }

    @Test("completeness: each field present adds its weight")
    func completeness() {
        #expect(MetadataCompleteness.score(present: []) == 0)
        #expect(MetadataCompleteness.score(present: [.cover]) > MetadataCompleteness.score(present: [.tags]))
        #expect(MetadataCompleteness.score(present: [.cover, .intro, .authors, .tags, .language, .series]) == MetadataCompleteness.maximum)
    }
}
