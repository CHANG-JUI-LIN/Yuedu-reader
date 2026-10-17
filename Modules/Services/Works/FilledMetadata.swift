import Foundation
import Observation

/// Unified library Phase 3a-2: the covers the filler gave copies with none of their own, by
/// copy, for the shelf's cover plan, which must not open files to decide (`BookshelfCoverPlan`).
/// Built from the sidecars (`BookStore.refreshFilledCovers()`), and changed when the filler
/// saves a cover or the reader removes one. Views read it through the environment, so only
/// the cover slots redraw when it changes.
@Observable
@MainActor
final class FilledCoverIndex {
    /// Absolute paths, under `FilledMetadata.coverDirectory`.
    private(set) var paths: [UUID: String] = [:]
    /// Counts `set` calls, and the count at each copy's last one: a rebuild that read the
    /// sidecars before a `set` must not undo it.
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var setAt: [UUID: Int] = [:]

    /// The filled cover to draw for `book`, if it has none of its own.
    func path(for book: ReadingBook) -> String? {
        book.hasOwnCoverArtwork ? nil : paths[book.id]
    }

    func set(_ path: String?, for copyID: UUID) {
        revision += 1
        setAt[copyID] = revision
        guard paths[copyID] != path else { return }
        paths[copyID] = path
    }

    /// The index rebuilt from the sidecars as they were read from `revision` on: a copy `set`
    /// since (the filler saved a cover while they were read) keeps what it was set to.
    func replaceAll(_ paths: [UUID: String], readAt revision: Int) {
        var paths = paths
        for (id, at) in setAt where at > revision {
            paths[id] = self.paths[id]
        }
        setAt = setAt.filter { $0.value > revision }
        guard self.paths != paths else { return }
        self.paths = paths
    }
}

/// Open Library (Phase 3c): its provider key.
enum OpenLibrary {
    nonisolated static let providerID = "openlibrary"
    nonisolated static let key = SourceInstanceKey(type: .bibliographic, id: providerID)
}

enum FilledMetadata {
    /// Where a filled cover's file is saved: the same discardable folder as the WebDAV index's
    /// covers (design §10.1). The sidecar holds the file name only, since the app's container
    /// path changes across updates.
    nonisolated static var coverDirectory: URL { WebDAVIndexCoordinator.defaultCoverDirectory }

    /// A provider's name as 書籍資訊 shows it beside a filled value.
    @MainActor
    static func providerName(_ key: SourceInstanceKey, sources: BookSourceStore = .shared) -> String {
        switch key.type {
        case .bibliographic where key.id == OpenLibrary.providerID: "Open Library"
        case .bibliographic where key == AIRecommendationProvider.recordInstance: localized("AI 推薦")
        case .bookSource: sources.sources.first { $0.bookSourceUrl == key.id }?.bookSourceName ?? key.id
        case .module: RuleModuleLibrary.shared.installed(id: key.id)?.module.title ?? key.id
        default: key.id
        }
    }

    /// The file name a sidecar's cover value names, if it is one: a bare name, not a URL.
    nonisolated static func coverFileName(_ payload: MetadataPayload?) -> String? {
        guard case .text(let name) = payload else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return trimmed
    }
}

extension ReadingBook {
    /// The copy's own artwork, as the shelf draws it first: a saved cover, or a remote
    /// library's catalog cover (`BookshelfCoverPlan.shelf`). Only a copy without either is
    /// given a filled cover.
    var hasOwnCoverArtwork: Bool {
        if let saved = coverImagePath, !saved.isEmpty { return true }
        return remoteSource != nil && coverUrl?.isEmpty == false
    }
}

extension BookStore {
    /// Reads the filled covers of the shelf's copies without artwork of their own. The
    /// sidecars are read off the main thread.
    @MainActor
    func refreshFilledCovers() async {
        let coverless = books.filter { !$0.hasOwnCoverArtwork }
        let inputs = coverless.map { book -> (UUID, [WorkDecision]) in
            (book.id, workDecisions.decisions(involving: .copy(book.id)))
        }
        let sidecars = importedMetadata
        let readAt = filledCovers.revision
        let paths = await Task.detached(priority: .utility) {
            var paths: [UUID: String] = [:]
            let directory = FilledMetadata.coverDirectory
            for (id, decisions) in inputs {
                guard let values = sidecars.read(copyID: id)?.values, values.contains(where: { $0.field == .cover }) else { continue }
                let resolved = MetadataResolver.resolve(.cover, anchor: .copy(id), copySource: .localLibrary, copyValue: nil,
                                                        values: values, decisions: decisions)
                guard let name = FilledMetadata.coverFileName(resolved?.value) else { continue }
                let path = directory.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path) {
                    paths[id] = path
                } else {
                    // `Caches` was emptied (設定 → 快取管理, or the system): the next fill
                    // pass does not ask again, so the copy goes back to its 預設封面.
                    AppLogger.cache("⟐ a filled cover's file is gone", context: ["copy": id.uuidString])
                }
            }
            return paths
        }.value
        filledCovers.replaceAll(paths, readAt: readAt)
    }

    /// 移除 in 書籍資訊: the reader does not want the value the filler gave this field. Recorded
    /// as an empty override (design §8.1), which the resolver shows as nothing and the filler
    /// never fills again.
    @MainActor
    func removeFilledValue(_ field: MetadataField, of bookID: UUID, at date: Date = Date()) {
        workDecisions.record(.override(anchor: .copy(bookID), field: field, value: .text(""), decidedAt: date))
        if field == .cover { filledCovers.set(nil, for: bookID) }
    }

    /// The value the filler gave `field` of `book` that is in effect now, and who gave it.
    /// Nil when the field shows the copy's own value, the reader's, or nothing. Reads a file.
    @MainActor
    func filledValue(_ field: MetadataField, of book: ReadingBook) -> (value: MetadataPayload, provider: SourceInstanceKey)? {
        if field == .cover && book.hasOwnCoverArtwork { return nil }
        if field == .intro, let own = book.customIntro, !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let values = importedMetadata.read(copyID: book.id)?.values else { return nil }
        let record = SourceRecord.derived(from: book, context: WorkIndexService.liveContext(for: [book]))
        let resolved = MetadataResolver.resolve(field, anchor: .copy(book.id), copySource: record.key.instance, copyValue: nil,
                                                values: values, decisions: workDecisions.decisions(involving: .copy(book.id)))
        guard let resolved, !resolved.value.isEmpty, case .provider(let provider, _, _) = resolved.provenance,
              metadataFillLedger.entry(copyID: book.id, provider: MetadataFillRunner.ledgerKey(forPlace: provider))?.outcome == .found
        else { return nil }
        return (resolved.value, provider)
    }
}
