import Foundation
import Testing
@testable import yuedu_app

// Discovery Phase 7a-2: the genres the reader opens, recorded on the device (maintainer's
// decision 3), for 為你推薦's genre match.

@Suite("Reading genre profile")
struct ReadingGenreProfileTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a tag's weight halves every 30 days")
    func decay() {
        var profile = ReadingGenreProfile()
        let recorded1 = profile.record(tags: ["玄幻"], book: UUID(), at: start)
        #expect(recorded1)
        let recorded2 = profile.record(tags: ["科幻"], book: UUID(), at: start.addingTimeInterval(30 * day))
        #expect(recorded2)
        let weights = profile.weights(at: start.addingTimeInterval(30 * day))
        #expect(weights["科幻"] == 1)
        #expect(abs((weights["玄幻"] ?? 0) - 0.5) < 0.0001)
    }

    @Test("weights are scaled so the strongest is 1")
    func scaled() {
        var profile = ReadingGenreProfile()
        profile.record(tags: ["玄幻", "都市"], book: UUID(), at: start)
        profile.record(tags: ["玄幻"], book: UUID(), at: start)
        let weights = profile.weights(at: start)
        #expect(weights == ["玄幻": 1, "都市": 0.5])
        #expect(ReadingGenreProfile().weights(at: start).isEmpty)
    }

    @Test("tags are folded, split from a source's kind, and the meaningless dropped")
    func normalization() {
        #expect(ReadingGenreProfile.normalizedTags([" 玄幻 ", "玄幻", "ＳＦ", "2024", "１２", "仙", ""]) == ["玄幻", "sf"])
        // Traditional and Simplified are one tag.
        #expect(ReadingGenreProfile.normalizedTags(["歷史"]) == ReadingGenreProfile.normalizedTags(["历史"]))
        #expect(ReadingGenreProfile.tags(fromSourceKind: "玄幻,連載、2024-01-01|東方玄幻") == ["玄幻", "连载", "东方玄幻"])
    }

    @Test("at most 200 tags are kept, the weakest dropped")
    func cap() {
        var profile = ReadingGenreProfile()
        profile.record(tags: ["保留甲"], book: UUID(), at: start)
        profile.record(tags: ["保留甲"], book: UUID(), at: start)
        for index in 0..<ReadingGenreProfile.tagLimit {
            profile.record(tags: ["標籤\(index)"], book: UUID(), at: start.addingTimeInterval(1))
        }
        let weights = profile.weights(at: start.addingTimeInterval(1))
        #expect(weights.count == ReadingGenreProfile.tagLimit)
        #expect(weights["保留甲"] == 1)
        #expect(ReadingGenreProfile.tagLimit == 200)
    }

    @Test("the same book opened again within a day does not count twice")
    func onceADay() {
        var profile = ReadingGenreProfile()
        let book = UUID()
        let recorded3 = profile.record(tags: ["玄幻"], book: book, at: start)
        #expect(recorded3)
        let recorded4 = profile.record(tags: ["玄幻"], book: book, at: start.addingTimeInterval(day - 60))
        #expect(!recorded4)
        let recorded5 = profile.record(tags: ["玄幻"], book: book, at: start.addingTimeInterval(day + 60))
        #expect(recorded5)
        let recorded6 = profile.record(tags: [], book: UUID(), at: start)
        #expect(!recorded6, "a book without tags records nothing")
    }

    @Test("a copy's own tags come first; an online copy's kind otherwise")
    func tagsOfACopy() {
        let item = SourceItemKey(instance: SourceInstanceKey(type: .calibre, id: "c"), item: "1")
        let sidecar = ImportedMetadata(copyID: UUID(), sourceItem: item, identifiers: [], values: [
            MetadataValue(field: .tags, value: .texts(["Science Fiction", "Space"]),
                          provider: SourceInstanceKey(type: .calibre, id: "c"), sourceItem: nil, fetchedAt: start),
        ])
        #expect(ReadingGenreProfile.tags(sidecar: sidecar, sourceKind: "玄幻") == ["sciencefiction", "space"])
        #expect(ReadingGenreProfile.tags(sidecar: nil, sourceKind: "玄幻 完本") == ["玄幻", "完本"])
        #expect(ReadingGenreProfile.tags(sidecar: nil, sourceKind: nil).isEmpty)
    }
}

@Suite("Reading genre recorder")
struct ReadingGenreRecorderTests {
    @Test("what is recorded is saved, and read back by the next recorder")
    func persists() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingGenres-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("genres.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = ReadingGenreRecorder(fileURL: file, now: { now })
        await recorder.record(tags: ["玄幻"], book: UUID())
        let again = ReadingGenreRecorder(fileURL: file, now: { now })
        #expect(await again.profile().weights(at: now) == ["玄幻": 1])
    }

    @Test("an unreadable file starts an empty profile, and says so in the log")
    func unreadable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingGenres-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("genres.json")
        try Data("not json".utf8).write(to: file)
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        let recorder = ReadingGenreRecorder(fileURL: file)
        #expect(await recorder.profile().weights(at: Date()).isEmpty)
        let lines = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains(directory.lastPathComponent) }
        #expect(lines.count == 1)
    }
}
