import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1d: `Works/decisions.json`, the one authoritative file of the works layer.
@Suite("Work decisions store", .serialized)
struct WorkDecisionsStoreTests {
    private let a = SourceItemKey.copy(UUID())
    private let b = SourceItemKey.copy(UUID())
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("decisions survive a relaunch, and queries answer from them")
    func roundTrip() throws {
        let (url, cleanup) = try makeFile()
        defer { cleanup() }
        let store = WorkDecisionsStore(fileURL: url)
        store.record(.lock(anchor: a, field: .title, value: nil, decidedAt: date))
        store.record(.override(anchor: a, field: .intro, value: .text("簡介"), decidedAt: date))
        store.record(.differentWorks(a, b, decidedAt: date))
        store.waitForPendingWritesForTesting()

        let reopened = WorkDecisionsStore(fileURL: url)
        #expect(reopened.decisions == store.decisions)
        #expect(reopened.isLocked(.title, anchor: a))
        #expect(!reopened.isLocked(.authors, anchor: a))
        #expect(!reopened.isLocked(.title, anchor: b))
        #expect(reopened.override(.intro, anchor: a) == .text("簡介"))
        #expect(reopened.decisions(involving: b) == [.differentWorks(a, b, decidedAt: date)])
    }

    @Test("a later decision replaces the one in its slot: a merge after a split, a second lock")
    func slots() throws {
        let (url, cleanup) = try makeFile()
        defer { cleanup() }
        let store = WorkDecisionsStore(fileURL: url)
        store.record(.differentWorks(a, b, decidedAt: date))
        store.record(.sameWork(b, a, decidedAt: date))
        store.record(.lock(anchor: a, field: .intro, value: .text("一"), decidedAt: date))
        store.record(.lock(anchor: a, field: .intro, value: .text("二"), decidedAt: date))
        store.record(.override(anchor: a, field: .intro, value: .text("三"), decidedAt: date))

        #expect(store.decisions == [
            .sameWork(b, a, decidedAt: date),
            .lock(anchor: a, field: .intro, value: .text("二"), decidedAt: date),
            .override(anchor: a, field: .intro, value: .text("三"), decidedAt: date),
        ])
        store.unlock(.intro, anchor: a)
        #expect(!store.isLocked(.intro, anchor: a))
        #expect(store.decisions.count == 2)
    }

    @Test("a file that does not decode is kept aside, and the store starts empty")
    func corruptKeptAside() throws {
        let (url, cleanup) = try makeFile()
        defer { cleanup() }
        try Data("{ not decisions".utf8).write(to: url)

        let store = WorkDecisionsStore(fileURL: url)
        #expect(store.decisions.isEmpty)
        #expect(!store.isReadOnly)
        store.record(.lock(anchor: a, field: .title, value: nil, decidedAt: date))
        store.waitForPendingWritesForTesting()

        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("decisions.corrupt-") }
        #expect(try backups.map { try Data(contentsOf: $0) } == [Data("{ not decisions".utf8)])
        #expect(WorkDecisionsStore(fileURL: url).isLocked(.title, anchor: a))
    }

    @Test("a file that cannot be read is never written over")
    func unreadable() throws {
        let (url, cleanup) = try makeFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            cleanup()
        }
        try Data("original".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = WorkDecisionsStore(fileURL: url)
        #expect(store.isReadOnly)
        store.record(.lock(anchor: a, field: .title, value: nil, decidedAt: date))
        store.waitForPendingWritesForTesting()
        #expect(store.isLocked(.title, anchor: a), "it holds until the app quits")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == Data("original".utf8))
    }

    @Test("a newer build's file is read as far as it goes and never written over")
    func newerSchema() throws {
        let (url, cleanup) = try makeFile()
        defer { cleanup() }
        let known = WorkDecision.lock(anchor: a, field: .title, value: nil, decidedAt: date)
        let encodedKnown = String(decoding: try JSONEncoder().encode(known), as: UTF8.self)
        let newer = #"{"schemaVersion":2,"decisions":[\#(encodedKnown),{"futureKind":{"x":1}}]}"#
        try Data(newer.utf8).write(to: url)

        let store = WorkDecisionsStore(fileURL: url)
        #expect(store.decisions == [known])
        #expect(store.isReadOnly)
        store.record(.differentWorks(a, b, decidedAt: date))
        store.waitForPendingWritesForTesting()
        #expect(try Data(contentsOf: url) == Data(newer.utf8))
    }

    private func makeFile() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDecisions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder.appendingPathComponent("decisions.json"), { try? FileManager.default.removeItem(at: folder) })
    }
}
