import Foundation

/// Unified library 1b: one sidecar file per copy, `<directory>/<copy id>.json`, holding what
/// the import read beyond title and author. Derived data: it can be deleted and read again
/// from the copy's file where one exists.
///
/// Every touch of the folder runs on one serial queue, and writes replace a file
/// atomically. A file that exists but does not decode is copied aside
/// (`<id>.corrupt-<mtime>.json`) before anything is written over it; one that cannot be read,
/// or cannot be copied, is never written over (the 0d rule, design §10.1).
final class ImportedMetadataStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.yuedu.importedMetadata")

    init(directory: URL) {
        self.directory = directory
    }

    /// The sidecar beside a shelf file: `<shelf folder>/Works/metadata`.
    convenience init(besideShelfFile shelfFile: URL) {
        self.init(directory: shelfFile.deletingLastPathComponent()
            .appendingPathComponent("Works", isDirectory: true)
            .appendingPathComponent("metadata", isDirectory: true))
    }

    /// Merges into the copy's sidecar: identifiers are unioned, and a value replaces an earlier
    /// one of the same field from the same place. An Aozora book first records its OPF, then
    /// its catalog work; both survive.
    func write(_ metadata: ImportedMetadata) {
        guard !metadata.isEmpty else { return }
        queue.async { [self] in
            writeNow(metadata)
        }
    }

    /// Rewrites a sidecar's values in place, unmerged: `write` merges, so it cannot remove one.
    /// Nothing happens when there is no sidecar or `transform` changes nothing.
    func rewriteValues(copyID: UUID, _ transform: @escaping @Sendable ([MetadataValue]) -> [MetadataValue]) {
        queue.async { [self] in
            let url = fileURL(for: copyID)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                var metadata = try JSONDecoder.imported.decode(ImportedMetadata.self, from: Data(contentsOf: url))
                let values = transform(metadata.values)
                guard values != metadata.values else { return }
                metadata.values = values
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(metadata).write(to: url, options: .atomic)
            } catch {
                AppLogger.cache("⟐ imported metadata could not be rewritten", error: error, context: ["copy": copyID.uuidString])
            }
        }
    }

    func read(copyID: UUID) -> ImportedMetadata? {
        queue.sync {
            let url = fileURL(for: copyID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder.imported.decode(ImportedMetadata.self, from: data)
            } catch {
                AppLogger.cache("⟐ imported metadata could not be read", error: error, context: ["copy": copyID.uuidString])
                return nil
            }
        }
    }

    /// Every sidecar's modification date and size, from one listing of the folder. The work
    /// index keeps each copy's stamp beside its entry: a sidecar lands after its copy is saved
    /// and changes no shelf revision, so this is how a refresh notices it.
    func stamps() -> [UUID: SidecarStamp] {
        queue.sync {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return [:]
            } catch {
                AppLogger.cache("⟐ imported metadata folder could not be listed", error: error)
                return [:]
            }
            var stamps: [UUID: SidecarStamp] = [:]
            for url in urls where url.pathExtension == "json" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    stamps[id] = SidecarStamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? -1)
                } catch {
                    AppLogger.cache("⟐ imported metadata could not be inspected", error: error, context: ["copy": id.uuidString])
                }
            }
            return stamps
        }
    }

    func remove(copyID: UUID) {
        queue.async { [self] in
            removeFile(fileURL(for: copyID))
        }
    }

    /// Removes the sidecars of copies not in `copyIDs`. Call only after a complete load of
    /// the shelf and reading records: only then can a missing copy be told from an unread one.
    func remove(notIn copyIDs: Set<UUID>) {
        queue.async { [self] in
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return
            } catch {
                AppLogger.cache("⟐ imported metadata folder could not be listed", error: error)
                return
            }
            for url in urls where url.pathExtension == "json" {
                let name = url.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: name), !copyIDs.contains(id) else { continue }
                removeFile(url)
            }
        }
    }

    #if DEBUG
    /// Drains queued writes, for tests.
    func waitForPendingWritesForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: - On the queue

    private func writeNow(_ metadata: ImportedMetadata) {
        let url = fileURL(for: metadata.copyID)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AppLogger.cache("⟐ imported metadata folder could not be created", error: error)
            return
        }
        var merged = metadata
        if manager.fileExists(atPath: url.path) {
            let existing: Data
            do {
                existing = try Data(contentsOf: url)
            } catch {
                AppLogger.cache("⟐ imported metadata not written: the file on disk could not be read", error: error,
                                context: ["copy": metadata.copyID.uuidString])
                return
            }
            do {
                merged = Self.merging(metadata, into: try JSONDecoder.imported.decode(ImportedMetadata.self, from: existing))
            } catch {
                AppLogger.cache("⟐ imported metadata could not be decoded", error: error, context: ["copy": metadata.copyID.uuidString])
                guard keepAside(existing, of: url) else { return }
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(merged).write(to: url, options: .atomic)
        } catch {
            AppLogger.cache("⟐ imported metadata could not be written", error: error, context: ["copy": metadata.copyID.uuidString])
        }
    }

    static func merging(_ new: ImportedMetadata, into old: ImportedMetadata) -> ImportedMetadata {
        var result = new
        var seen = Set(new.identifiers)
        result.identifiers = new.identifiers + old.identifiers.filter { seen.insert($0).inserted }
        let replaced = Set(new.values.map { "\($0.field.rawValue)|\($0.provider.type.rawValue)|\($0.provider.id)" })
        result.values = new.values + old.values.filter {
            !replaced.contains("\($0.field.rawValue)|\($0.provider.type.rawValue)|\($0.provider.id)")
        }
        return result
    }

    /// Named after the file's modification time, so a second attempt reuses the copy it made.
    private func keepAside(_ data: Data, of url: URL) -> Bool {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let stamp = Int((modified ?? Date()).timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try data.write(to: backup, options: .withoutOverwriting)
            AppLogger.cache("⟐ unreadable imported metadata kept aside as \(backup.lastPathComponent)")
            return true
        } catch {
            if let kept = try? Data(contentsOf: backup), kept == data { return true }
            AppLogger.cache("⟐ imported metadata not written: an unreadable file could not be kept aside", error: error)
            return false
        }
    }

    private func removeFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            AppLogger.cache("⟐ imported metadata could not be removed", error: error)
        }
    }

    private func fileURL(for copyID: UUID) -> URL {
        directory.appendingPathComponent("\(copyID.uuidString).json")
    }
}

private extension JSONDecoder {
    static var imported: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// When a sidecar was last written, as the file system reports it.
struct SidecarStamp: Hashable, Codable, Sendable {
    var modified: Date
    var size: Int
}
