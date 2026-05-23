import Foundation

struct BookProgressSnapshot: Codable, Equatable {
    enum Mode: String, Codable {
        case coreText
        case paged
        case scroll
    }

    let bookId: UUID
    let mode: Mode
    let chapterIndex: Int
    let pageIndex: Int?
    let charOffset: Int?
    let percentage: Double
    let timestamp: Date
}

@MainActor
final class ReaderProgressManager {
    static let shared = ReaderProgressManager()

    private let defaults = UserDefaults.standard
    private let snapshotPrefix = "yd_reader_progress_snapshot_"
    private let legacyPagedPrefix = "readerPos_"

    private init() {}

    private func log(_ message: String) {
        print("[ProgressTrace][ReaderProgressManager] \(message)")
    }

    func saveCoreText(bookId: UUID, chapterIndex: Int, charOffset: Int, percentage: Double) {
        log("saveCoreText deprecated bookId=\(bookId.uuidString)")
    }

    func savePaged(bookId: UUID, chapterIndex: Int, pageInChapter: Int, percentage: Double) {
        log("savePaged deprecated bookId=\(bookId.uuidString)")
    }

    func saveScroll(bookId: UUID, chapterIndex: Int, charOffset: Int = 0, percentage: Double) {
        log("saveScroll deprecated bookId=\(bookId.uuidString)")
    }

    func loadSnapshot(bookId: UUID) -> BookProgressSnapshot? {
        let key = snapshotKey(bookId: bookId)
        guard let data = defaults.data(forKey: key) else {
            log("loadSnapshot miss bookId=\(bookId.uuidString)")
            return nil
        }
        do {
            let snapshot = try JSONDecoder().decode(BookProgressSnapshot.self, from: data)
            log("loadSnapshot hit bookId=\(bookId.uuidString) mode=\(snapshot.mode.rawValue) chapter=\(snapshot.chapterIndex) charOffset=\(snapshot.charOffset.map(String.init) ?? "nil") page=\(snapshot.pageIndex.map(String.init) ?? "nil") pct=\(String(format: "%.6f", snapshot.percentage))")
            return snapshot
        } catch {
            log("loadSnapshot decodeFailed bookId=\(bookId.uuidString) error=\(error)")
            return nil
        }
    }

    private func saveSnapshot(_ snapshot: BookProgressSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            log("saveSnapshot encodeFailed bookId=\(snapshot.bookId.uuidString)")
            return
        }
        defaults.set(data, forKey: snapshotKey(bookId: snapshot.bookId))
    }

    private func saveLegacyPagedPosition(
        bookId: UUID,
        chapterIndex: Int,
        pageInChapter: Int,
        percentage: Double
    ) {
        let legacy = LegacyPagedPosition(
            chapterIndex: chapterIndex,
            charOffsetInChapter: pageInChapter,
            percentage: normalized(percentage)
        )
        guard let data = try? JSONEncoder().encode(legacy) else {
            log("saveLegacyPagedPosition encodeFailed bookId=\(bookId.uuidString)")
            return
        }
        defaults.set(data, forKey: legacyKey(bookId: bookId))
    }

    private func snapshotKey(bookId: UUID) -> String {
        snapshotPrefix + bookId.uuidString
    }

    private func legacyKey(bookId: UUID) -> String {
        legacyPagedPrefix + bookId.uuidString
    }

    private func normalized(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

private struct LegacyPagedPosition: Codable {
    let chapterIndex: Int
    let charOffsetInChapter: Int
    let percentage: Double
}
