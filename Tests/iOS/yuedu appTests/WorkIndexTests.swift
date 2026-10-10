import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1c: the union-find over source records (design §7.2, §7.3), with the
/// design's fixtures.
@Suite("Work index")
struct WorkIndexTests {
    private let isbnX = ExternalIdentifier.normalized(.isbn13, "9787536692930")!
    private let isbnY = ExternalIdentifier.normalized(.isbn13, "9787536693968")!
    private let calibreU = ExternalIdentifier.normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
    private let calibre = SourceInstanceKey(type: .calibre, id: "my-calibre")
    private let opds = SourceInstanceKey(type: .opds, id: "my-opds")

    // MARK: - A-level

    @Test("《三體》: EPUB, Calibre EPUB and PDF, and OPDS zh-Hant are one work in two editions")
    func threeBody() throws {
        let epub = copy("三體", "劉慈欣", identifiers: [isbnX], language: "zh-Hans")
        let calibreKey = SourceItemKey(instance: calibre, item: "urn:uuid:6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        let calibreEPUB = copy("三体", "刘慈欣", source: calibreKey, identifiers: [calibreU, isbnX], language: "zh-Hans")
        let calibrePDF = copy("三体", "刘慈欣", source: calibreKey, identifiers: [calibreU, isbnX], language: "zh-Hans")
        let hant = copy("三體", "劉慈欣", source: SourceItemKey(instance: opds, item: "urn:entry:1"), identifiers: [isbnX], language: "zh-Hant")

        let index = WorkIndex.build(entries: [epub, calibreEPUB, calibrePDF, hant], policy: aOnly)

        let work = try #require(index.works.first)
        #expect(index.works.count == 1)
        #expect(work.editions.map(\.id) == ["text/zh-Hans", "text/zh-Hant"])
        #expect(Set(work.editions[0].members) == Set([epub, calibreEPUB, calibrePDF].map(\.nodeKey)))
        #expect(work.editions[1].members == [hant.nodeKey])
        #expect(work.links.contains { $0.evidence == .identifier(isbnX) })
        #expect(work.links.contains { $0.evidence == .sameSourceItem }, "the two formats are one Calibre entry")
        #expect(!work.isMergedByTitleAndAuthor)
    }

    @Test("《三體》 and 《三體II》 with different ISBNs are two works")
    func sequel() {
        let index = WorkIndex.build(entries: [
            copy("三體", "劉慈欣", identifiers: [isbnX]),
            copy("三體II", "劉慈欣", identifiers: [isbnY]),
        ])
        #expect(index.works.count == 2)
    }

    @Test("the same title by incompatible authors, with no shared identifier, is two works")
    func sameTitleOtherAuthor() {
        let index = WorkIndex.build(entries: [copy("紅樓夢", "曹雪芹"), copy("紅樓夢", "王小波")])
        #expect(index.works.count == 2)
    }

    @Test("a comic adaptation is its own work, even sharing title, author and ISBN")
    func comicAdaptation() {
        let index = WorkIndex.build(entries: [
            copy("三體", "劉慈欣", identifiers: [isbnX]),
            copy("三體", "劉慈欣", kind: .comic, identifiers: [isbnX]),
        ])
        #expect(index.works.count == 2)
    }

    @Test("a translation is its own work, even sharing an ISBN")
    func translation() {
        let index = WorkIndex.build(entries: [
            copy("三體", "劉慈欣", identifiers: [isbnX], language: "zh-Hans"),
            copy("The Three-Body Problem", "Liu Cixin", identifiers: [isbnX], language: "en"),
        ])
        #expect(index.works.count == 2)
    }

    @Test("Calibre EPUB and PDF of one uuid are one edition")
    func calibreFormats() throws {
        let epub = copy("三体", "刘慈欣", source: SourceItemKey(instance: calibre, item: "a"), identifiers: [calibreU])
        let pdf = copy("三体", "刘慈欣", source: SourceItemKey(instance: calibre, item: "b"), identifiers: [calibreU])
        let work = try #require(WorkIndex.build(entries: [epub, pdf], policy: aOnly).works.first)
        #expect(work.editions.count == 1)
        #expect(work.links.map(\.evidence) == [.identifier(calibreU)])
    }

    @Test("two copies of one source item are one work")
    func sameSourceItem() {
        let entry = SourceItemKey(instance: opds, item: "urn:entry:1")
        let index = WorkIndex.build(entries: [copy("A", "x", source: entry), copy("B", "y", source: entry)], policy: aOnly)
        #expect(index.works.count == 1)
        #expect(index.works[0].links.map(\.evidence) == [.sameSourceItem])
    }

    @Test("a shared EPUB package id never merges")
    func packageIDDoesNotMerge() {
        let packageID = ExternalIdentifier.normalized(.epubUniqueIdentifier, "bookid")!
        let index = WorkIndex.build(entries: [copy("A", "x", identifiers: [packageID]), copy("B", "y", identifiers: [packageID])])
        #expect(index.works.count == 2)
    }

    @Test("languages are checked on the whole work: zh ~ unknown ~ en does not chain")
    func noLanguageChain() {
        let zh = copy("A", "x", identifiers: [isbnX], language: "zh")
        let unknown = copy("B", "y", identifiers: [isbnX, isbnY])
        let en = copy("C", "z", identifiers: [isbnY], language: "en")
        let index = WorkIndex.build(entries: [zh, unknown, en])
        #expect(index.works.count == 2)
        #expect(index.work(containing: zh.nodeKey) == index.work(containing: unknown.nodeKey))
        #expect(index.work(containing: en.nodeKey) != index.work(containing: zh.nodeKey))
    }

    // MARK: - Decisions

    @Test("a split pair stays split, whatever else matches")
    func splitWins() {
        let a = copy("三體", "劉慈欣", identifiers: [isbnX])
        let b = copy("三體", "劉慈欣", identifiers: [isbnX])
        let index = WorkIndex.build(entries: [a, b], decisions: [.differentWorks(a.nodeKey, b.nodeKey, decidedAt: .distantPast)])
        #expect(index.works.count == 2)
    }

    @Test("a split blocks through a third record too")
    func splitBlocksThroughThird() {
        let a = copy("A", "x", identifiers: [isbnX])
        let b = copy("B", "y", identifiers: [isbnX, isbnY])
        let c = copy("C", "z", identifiers: [isbnY])
        let index = WorkIndex.build(entries: [a, b, c], decisions: [.differentWorks(a.nodeKey, c.nodeKey, decidedAt: .distantPast)])
        #expect(index.work(containing: a.nodeKey) != index.work(containing: c.nodeKey))
        #expect(index.works.count == 2)
    }

    @Test("a merge joins what nothing else would, but never what the reader split")
    func mergeDecision() {
        let a = copy("A", "x")
        let b = copy("B", "y", kind: .audio)
        let merged = WorkIndex.build(entries: [a, b], decisions: [.sameWork(a.nodeKey, b.nodeKey, decidedAt: .distantPast)])
        #expect(merged.works.count == 1, "a merge overrides the content-kind rule")
        #expect(merged.works[0].links.map(\.evidence) == [.decision])
        #expect(merged.works[0].editions.map(\.id) == ["audio/und", "text/und"])

        let both = WorkIndex.build(entries: [a, b], decisions: [
            .sameWork(a.nodeKey, b.nodeKey, decidedAt: .distantPast),
            .differentWorks(b.nodeKey, a.nodeKey, decidedAt: .distantPast),
        ])
        #expect(both.works.count == 2)
    }

    @Test("a decision matches a record by its copy key or by its source key")
    func decisionKeys() {
        let source = SourceItemKey(instance: opds, item: "urn:entry:1")
        let a = copy("三體", "劉慈欣", identifiers: [isbnX])
        let b = copy("三體", "劉慈欣", source: source, identifiers: [isbnX])
        #expect(WorkIndex.build(entries: [a, b], decisions: [.differentWorks(a.nodeKey, source, decidedAt: .distantPast)]).works.count == 2)
        #expect(WorkIndex.build(entries: [a, b], decisions: [.differentWorks(a.nodeKey, b.nodeKey, decidedAt: .distantPast)]).works.count == 2)
    }

    // MARK: - B-level

    @Test("《三體》 without ISBNs merges by title and author, labeled and splittable")
    func titleAuthor() throws {
        let hans = copy("三体", "刘慈欣", language: "zh-Hans")
        let hant = copy("《三體》", "劉慈欣 著", language: "zh-Hant")
        let index = WorkIndex.build(entries: [hans, hant])
        let work = try #require(index.works.first)
        #expect(index.works.count == 1)
        #expect(work.isMergedByTitleAndAuthor)
        #expect(work.editions.map(\.id) == ["text/zh-Hans", "text/zh-Hant"], "compatible, but separate editions")

        #expect(WorkIndex.build(entries: [hans, hant], decisions: [.differentWorks(hans.nodeKey, hant.nodeKey, decidedAt: .distantPast)]).works.count == 2)
        #expect(WorkIndex.build(entries: [hans, hant], policy: aOnly).works.count == 2)
    }

    @Test("with one author missing, a title alone does not merge (C-level)")
    func titleOnly() {
        #expect(WorkIndex.build(entries: [copy("三体", "刘慈欣"), copy("三体", "")]).works.count == 2)
    }

    @Test("B-level never joins different kinds or languages")
    func titleAuthorRejections() {
        #expect(WorkIndex.build(entries: [copy("三体", "刘慈欣"), copy("三体", "刘慈欣", kind: .audio)]).works.count == 2)
        #expect(WorkIndex.build(entries: [copy("三体", "刘慈欣", language: "zh"), copy("三体", "刘慈欣", language: "ja")]).works.count == 2)
    }

    // MARK: - Editions

    @Test("a script-less tag and a copy with no language join the only edition there is")
    func editionGuesses() throws {
        let us = copy("Dune", "Frank Herbert", language: "en-US")
        let plain = copy("Dune", "Frank Herbert", language: "en")
        let unknown = copy("Dune", "Frank Herbert")
        let work = try #require(WorkIndex.build(entries: [us, plain, unknown]).works.first)
        #expect(work.editions.map(\.id) == ["text/en-Latn"])
        #expect(work.editions[0].members.count == 3)
    }

    @Test("with two scripts, untagged copies get their own editions")
    func editionsStayApart() throws {
        let entries = [
            copy("三体", "刘慈欣", language: "zh-Hans"), copy("三体", "刘慈欣", language: "zh-Hant"),
            copy("三体", "刘慈欣", language: "zh"), copy("三体", "刘慈欣"),
        ]
        let work = try #require(WorkIndex.build(entries: entries).works.first)
        #expect(work.editions.map(\.id) == ["text/und", "text/zh", "text/zh-Hans", "text/zh-Hant"])
    }

    // MARK: - Determinism and search

    @Test("the same entries in any order give the same index")
    func deterministic() throws {
        let entries = [
            copy("三體", "劉慈欣", identifiers: [isbnX], language: "zh-Hans"),
            copy("三体", "刘慈欣", source: SourceItemKey(instance: calibre, item: "u"), identifiers: [calibreU, isbnX]),
            copy("三体", "刘慈欣", source: SourceItemKey(instance: calibre, item: "u"), identifiers: [calibreU]),
            copy("三體", "劉慈欣", language: "zh-Hant"),
            copy("三體II", "劉慈欣", identifiers: [isbnY]),
            copy("紅樓夢", "曹雪芹"), copy("红楼梦", "曹雪芹"), copy("紅樓夢", "王小波"),
        ]
        var generator = SplitMix64(seed: 2026_10_10)
        let decisions: [WorkDecision] = [.differentWorks(entries[5].nodeKey, entries[6].nodeKey, decidedAt: .distantPast)]
        let reference = WorkIndex.build(entries: entries, decisions: decisions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for order in [entries.reversed(), entries.shuffled(using: &generator), entries.shuffled(using: &generator)] {
            let other = WorkIndex.build(entries: Array(order), decisions: decisions.reversed())
            #expect(other == reference)
            #expect(try encoder.encode(other.works) == encoder.encode(reference.works))
        }
        #expect(reference.works.count == 5, "三體 ×4, 三體II, and three 紅樓夢 kept apart by a split and an author")
    }

    @Test("local search finds works by title or author, equal titles first")
    func search() {
        let index = WorkIndex.build(entries: [copy("三體", "劉慈欣"), copy("三體II", "劉慈欣"), copy("紅樓夢", "曹雪芹")])
        #expect(index.search("三体").count == 2)
        #expect(index.search("三体").first?.searchKeys.contains("三体") == true)
        #expect(index.search("曹雪芹").count == 1)
        #expect(index.search("《》").isEmpty)
    }

    // MARK: - Helpers

    private let aOnly = WorkIndexPolicy(titleAuthorMerging: false)

    private func copy(
        _ title: String, _ author: String, kind: ContentKind = .text, source: SourceItemKey? = nil,
        identifiers: [ExternalIdentifier] = [], language: String? = nil
    ) -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(
            key: source ?? .copy(id), title: title, authors: author.isEmpty ? [] : [author], language: nil,
            contentKind: kind, identifiers: [], copyID: id, acquisitions: [.openCopy(id)]
        )
        return WorkIndexEntry(record: record, extraIdentifiers: identifiers, language: LanguageTag(language))
    }
}

/// A seeded generator, so shuffled orders repeat.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
