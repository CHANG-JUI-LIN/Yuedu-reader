import Combine
import Foundation

/// The last AI 推薦 run's works, as the home section shows them (maintainer, 2026-10-15:
/// generated only when the reader asks; opening the home reads this with no request).
struct AIRecommendationList: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let work: AIRecommendation.Work
        /// Open Library's record of the work, when its title and author matched (B).
        var openLibrary: SourceRecord?
        var cover: CoverReference?
        var blurb: String?

        /// Unique within a list: `AIRecommendation.parse` drops repeats by title and author.
        var id: String { "\(work.title)\u{1F}\(work.author)" }

        init(work: AIRecommendation.Work, openLibrary: SourceRecord? = nil, cover: CoverReference? = nil, blurb: String? = nil) {
            self.work = work
            self.openLibrary = openLibrary
            self.cover = cover
            self.blurb = blurb
        }
    }

    var entries: [Entry]
    let generatedAt: Date
    /// The AI service's name as the reader named it in AI 設定, and the model that answered.
    let service: String
    let model: String
}

/// `Application Support/AIRecommendations/latest.json`: one list, kept on this device only
/// (like 為你推薦's genre profile, it is not synced).
@MainActor
final class AIRecommendationStore: ObservableObject {
    nonisolated static let directory = StorageLocations.support.appendingPathComponent("AIRecommendations", isDirectory: true)
    static let shared = AIRecommendationStore(directory: directory)

    @Published private(set) var list: AIRecommendationList?
    /// Bumped on every write, for the home section's inputs key.
    @Published private(set) var revision = 0

    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("latest.json")
        list = Self.read(fileURL)
    }

    /// Replaces the stored list.
    func save(_ list: AIRecommendationList) {
        self.list = list
        revision += 1
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(list).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.cache("⟐ AI recommendations could not be saved", error: error, context: ["works": list.entries.count])
        }
    }

    /// Open Library's match for one work of the current list. A list replaced since the
    /// lookup started has no such entry, and nothing changes.
    func setMatch(record: SourceRecord, cover: CoverReference?, blurb: String?, for entryID: String, generatedAt: Date) {
        guard var list, list.generatedAt == generatedAt,
              let index = list.entries.firstIndex(where: { $0.id == entryID }) else { return }
        list.entries[index].openLibrary = record
        list.entries[index].cover = cover
        list.entries[index].blurb = blurb
        save(list)
    }

    private static func read(_ url: URL) -> AIRecommendationList? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLogger.cache("⟐ AI recommendations unreadable", error: error, context: [:])
            return nil
        }
        do {
            return try JSONDecoder().decode(AIRecommendationList.self, from: data)
        } catch {
            AppLogger.cache("⟐ AI recommendations undecodable", error: error, context: [:])
            return nil
        }
    }
}
