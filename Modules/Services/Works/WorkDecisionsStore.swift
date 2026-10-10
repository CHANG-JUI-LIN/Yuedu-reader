import Foundation

/// Unified library 1d: the reader's decisions, `Works/decisions.json` (design D2, §10.1).
///
/// Unlike the index and the sidecars this file is authoritative: nothing can rebuild it.
/// - It is read once, when the store is made; queries answer from memory.
/// - Writes replace the file atomically on one serial queue.
/// - A file of this version that does not decode is copied aside
///   (`decisions.corrupt-<mtime>.json`) before anything is written over it. The store then
///   starts empty, so the locks it held are lost until the copy is restored.
/// - A file that cannot be read, or cannot be copied aside, is never written over.
/// - A file from a newer build is read decision by decision, skipping the kinds this build
///   does not know, and never written over: writing it back would drop them.
///
/// Decisions about a deleted copy stay, inactive; only 重設作品資料 clears them (design §10.2).
final class WorkDecisionsStore: @unchecked Sendable {
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let lock = NSLock()
    private var stored: [WorkDecision] = []
    private var writesBlocked = false
    private let queue = DispatchQueue(label: "com.yuedu.works.decisions")

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// `<shelf folder>/Works/decisions.json`.
    convenience init(besideShelfFile shelfFile: URL) {
        self.init(fileURL: shelfFile.deletingLastPathComponent()
            .appendingPathComponent("Works", isDirectory: true)
            .appendingPathComponent("decisions.json"))
    }

    var decisions: [WorkDecision] {
        lock.withLock { stored }
    }

    /// Whether the store refused to write, because its file could not be read or comes from
    /// a newer build. Decisions recorded meanwhile hold until the app quits.
    var isReadOnly: Bool {
        lock.withLock { writesBlocked }
    }

    // MARK: - Queries

    func isLocked(_ field: MetadataField, anchor: SourceItemKey) -> Bool {
        lockDecision(field, anchor: anchor) != nil
    }

    func lockDecision(_ field: MetadataField, anchor: SourceItemKey) -> WorkDecision? {
        decisions.first {
            if case .lock(let a, let f, _, _) = $0 { return a == anchor && f == field }
            return false
        }
    }

    func override(_ field: MetadataField, anchor: SourceItemKey) -> MetadataPayload? {
        for decision in decisions {
            if case .override(let a, let f, let value, _) = decision, a == anchor, f == field { return value }
        }
        return nil
    }

    /// Every decision that names `key`, as either side of a pair, an anchor or a chosen source.
    func decisions(involving key: SourceItemKey) -> [WorkDecision] {
        decisions.filter { $0.keys.contains(key) }
    }

    // MARK: - Recording

    /// Records a decision. It replaces the decision in the same slot: for a pair, the same two
    /// keys in either order, so a merge after a split replaces the split; for a field, the
    /// same anchor, field and kind of decision.
    func record(_ decision: WorkDecision) {
        let snapshot: [WorkDecision] = lock.withLock {
            stored.removeAll { $0.slot == decision.slot }
            stored.append(decision)
            return stored
        }
        save(snapshot)
    }

    /// Removes the decisions `shouldRemove` matches, for example a lock being lifted.
    func remove(where shouldRemove: (WorkDecision) -> Bool) {
        let snapshot: [WorkDecision]? = lock.withLock {
            let before = stored.count
            stored.removeAll(where: shouldRemove)
            return stored.count == before ? nil : stored
        }
        if let snapshot { save(snapshot) }
    }

    #if DEBUG
    /// Drains queued writes, for tests.
    func waitForPendingWritesForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: - File

    private struct File: Codable {
        var schemaVersion: Int
        var decisions: [WorkDecision]
    }

    /// A newer build's file: whatever decodes.
    private struct LenientFile: Decodable {
        var decisions: [WorkDecision]
        var skipped = 0

        private enum CodingKeys: String, CodingKey { case decisions }
        private struct Skipped: Decodable {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .decisions)
            var decoded: [WorkDecision] = []
            while !list.isAtEnd {
                // A failed decode leaves the container on the same element, so it can be
                // stepped over; the count is logged by `load`.
                if let decision = try? list.decode(WorkDecision.self) {
                    decoded.append(decision)
                } else {
                    _ = try list.decode(Skipped.self)
                    skipped += 1
                }
            }
            decisions = decoded
        }
    }

    private struct Version: Decodable { var schemaVersion: Int }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLogger.error("Work decisions could not be read; they will not be written over", error: error)
            writesBlocked = true
            return
        }
        do {
            let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
            if version > Self.currentSchemaVersion {
                let lenient = try JSONDecoder().decode(LenientFile.self, from: data)
                stored = lenient.decisions
                writesBlocked = true
                AppLogger.error("Work decisions come from a newer build; reading them without writing", context: [
                    "schemaVersion": "\(version)", "decisions": "\(stored.count)", "skipped": "\(lenient.skipped)",
                ])
                return
            }
            stored = try JSONDecoder().decode(File.self, from: data).decisions
        } catch {
            AppLogger.error("Work decisions could not be decoded", error: error)
            writesBlocked = !keepAside(data)
        }
    }

    /// Copies an undecodable file next to itself, named after its modification time so a
    /// second launch finds the copy it already made. Returns whether the bytes are safe.
    private func keepAside(_ data: Data) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date()
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("decisions.corrupt-\(Int(modified.timeIntervalSince1970)).json")
        if FileManager.default.fileExists(atPath: copy.path) { return true }
        do {
            try data.write(to: copy, options: .withoutOverwriting)
            return true
        } catch {
            AppLogger.error("Undecodable work decisions could not be kept aside; they will not be written over", error: error)
            return false
        }
    }

    private func save(_ decisions: [WorkDecision]) {
        guard !isReadOnly else {
            AppLogger.error("Work decisions not saved: the file is read-only this launch",
                            context: ["decisions": "\(decisions.count)"])
            return
        }
        let url = fileURL
        let file = File(schemaVersion: Self.currentSchemaVersion, decisions: decisions)
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.error("Work decisions could not be saved", error: error, context: ["decisions": "\(decisions.count)"])
            }
        }
    }
}

extension WorkDecision {
    /// What a later decision replaces.
    fileprivate enum Slot: Hashable {
        case pair(Set<SourceItemKey>)
        case field(kind: Int, anchor: SourceItemKey, field: MetadataField)
    }

    fileprivate var slot: Slot {
        switch self {
        case .sameWork(let a, let b, _), .differentWorks(let a, let b, _): .pair([a, b])
        case .override(let anchor, let field, _, _): .field(kind: 0, anchor: anchor, field: field)
        case .lock(let anchor, let field, _, _): .field(kind: 1, anchor: anchor, field: field)
        case .chooseCandidate(let anchor, let field, _, _): .field(kind: 2, anchor: anchor, field: field)
        }
    }

    var keys: [SourceItemKey] {
        switch self {
        case .sameWork(let a, let b, _), .differentWorks(let a, let b, _): [a, b]
        case .override(let anchor, _, _, _), .lock(let anchor, _, _, _): [anchor]
        case .chooseCandidate(let anchor, _, let from, _): [anchor, from]
        }
    }
}
