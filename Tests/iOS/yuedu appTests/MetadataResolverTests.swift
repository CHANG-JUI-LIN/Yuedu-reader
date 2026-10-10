import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1d: each field's effective value and its provenance (design §8.1).
@Suite("Metadata resolver")
struct MetadataResolverTests {
    private let copyID = UUID()
    private var anchor: SourceItemKey { .copy(copyID) }
    private let calibre = SourceInstanceKey(type: .calibre, id: "c")
    private let openLibrary = SourceInstanceKey(type: .bibliographic, id: "openLibrary")
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var t1: Date { t0.addingTimeInterval(60) }

    @Test("an override wins over everything")
    func overrideWins() {
        let resolved = resolve(.intro, values: [value(.intro, "來自檔案", .localLibrary)], decisions: [
            .override(anchor: anchor, field: .intro, value: .text("我寫的"), decidedAt: t0),
            .lock(anchor: anchor, field: .intro, value: .text("鎖定的"), decidedAt: t0),
        ])
        #expect(resolved == .init(value: .text("我寫的"), provenance: .override(decidedAt: t0)))
    }

    @Test("a lock freezes the value it was set with while newer values arrive")
    func lockFreezes() {
        let lock = WorkDecision.lock(anchor: anchor, field: .intro, value: .text("鎖定時的簡介"), decidedAt: t0)
        let newer = value(.intro, "後來的簡介", .localLibrary, at: t1)
        #expect(resolve(.intro, values: [newer], decisions: [lock]) == .init(value: .text("鎖定時的簡介"), provenance: .lock(decidedAt: t0)))
    }

    @Test("a locked title is the copy's own value, so a manual edit still shows")
    func lockedTitleIsTheCopy() {
        let lock = WorkDecision.lock(anchor: anchor, field: .title, value: nil, decidedAt: t0)
        #expect(resolve(.title, copy: .text("我改的書名"), decisions: [lock]) == .init(value: .text("我改的書名"), provenance: .lock(decidedAt: t0)))
    }

    @Test("a chosen candidate wins over field priority, and falls through when its value is gone")
    func chosenCandidate() {
        let item = SourceItemKey(instance: calibre, item: "u")
        let choose = WorkDecision.chooseCandidate(anchor: anchor, field: .intro, from: item, decidedAt: t0)
        let values = [value(.intro, "檔案", .localLibrary), value(.intro, "Calibre", calibre, item: item)]
        #expect(resolve(.intro, values: values, decisions: [choose]) == .init(value: .text("Calibre"), provenance: .chosen(item)))
        #expect(resolve(.intro, values: [values[0]], decisions: [choose])?.value == .text("檔案"))
    }

    @Test("title and authors never fill in from another place")
    func titleNeverFills() {
        let values = [value(.title, "別處的書名", calibre)]
        #expect(resolve(.title, copy: .text("副本書名"), values: values) == .init(value: .text("副本書名"), provenance: .copy))
        #expect(resolve(.title, copy: nil, values: values) == nil)
    }

    @Test("field priority: the copy's file, then its source, then others; bibliographic only at A-level")
    func fieldPriority() {
        let file = value(.intro, "檔案", .localLibrary, at: t0)
        let source = value(.intro, "來源", calibre, at: t1)
        let other = value(.intro, "其他", SourceInstanceKey(type: .opds, id: "o"), at: t1)
        let bibliographic = value(.intro, "書目", openLibrary, at: t1)
        #expect(resolve(.intro, values: [bibliographic, other, source, file])?.value == .text("檔案"))
        #expect(resolve(.intro, values: [bibliographic, other, source])?.value == .text("來源"))
        #expect(resolve(.intro, values: [bibliographic, other])?.value == .text("其他"))
        #expect(resolve(.intro, values: [bibliographic]) == nil, "not A-level")
        #expect(resolve(.intro, values: [bibliographic], aLevel: true)?.provenance == .provider(openLibrary, sourceItem: nil, fetchedAt: t1))
    }

    @Test("within one place, the newest value wins")
    func newestWins() {
        let older = value(.tags, "舊", .localLibrary, at: t0)
        let newer = value(.tags, "新", .localLibrary, at: t1)
        #expect(resolve(.tags, values: [older, newer])?.value == .text("新"))
    }

    @Test("a cover: the copy's own before any database")
    func cover() {
        let bibliographic = value(.cover, "https://covers.example/1.jpg", openLibrary)
        #expect(resolve(.cover, copy: .text("local.jpg"), values: [bibliographic], aLevel: true)?.provenance == .copy)
        #expect(resolve(.cover, copy: nil, values: [bibliographic], aLevel: true)?.value == .text("https://covers.example/1.jpg"))
    }

    @Test("decisions about another copy do not apply")
    func otherAnchor() {
        let other = SourceItemKey.copy(UUID())
        let resolved = resolve(.intro, values: [value(.intro, "檔案", .localLibrary)],
                               decisions: [.override(anchor: other, field: .intro, value: .text("別本"), decidedAt: t0)])
        #expect(resolved?.value == .text("檔案"))
    }

    // MARK: - Helpers

    private func resolve(
        _ field: MetadataField, copy: MetadataPayload? = nil, values: [MetadataValue] = [],
        decisions: [WorkDecision] = [], aLevel: Bool = false
    ) -> MetadataResolver.Resolved? {
        MetadataResolver.resolve(field, anchor: anchor, copySource: calibre, copyValue: copy, values: values,
                                 decisions: decisions, bibliographicIsALevel: aLevel)
    }

    private func value(_ field: MetadataField, _ text: String, _ provider: SourceInstanceKey,
                       item: SourceItemKey? = nil, at date: Date? = nil) -> MetadataValue {
        MetadataValue(field: field, value: .text(text), provider: provider, sourceItem: item, fetchedAt: date ?? t0)
    }
}
