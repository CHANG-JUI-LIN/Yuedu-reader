import CryptoKit
import Foundation
import ReadiumShared

/// How much 2e reads per book and how often it saves. Set from measurement; see the Phase 2
/// plan's "What landed", 2e.
struct WebDAVFillLimits: Hashable, Sendable {
    /// A cover larger than this is not read.
    var coverByteLimit: UInt64
    /// Books read between two saves of the whole index file. A stop always saves, so this only
    /// bounds what an app kill loses.
    var saveEvery: Int

    static let standard = WebDAVFillLimits(coverByteLimit: 1_000_000, saveEvery: 500)
}

/// Unified library 2e: reads the OPF and cover of a connection's indexed EPUBs, the most
/// incomplete first (design §8.3), over range requests on the indexer's own client.
struct WebDAVMetadataFiller: Sendable {
    let connectionID: String
    let limits: WebDAVFillLimits
    /// One book's package: `PublicationSession.remotePackageMetadata` on the indexer's client.
    let read: @Sendable (URL) async throws -> PublicationSession.RemotePackageMetadata
    let coverDirectory: URL
    let save: @Sendable (WebDAVIndexState) -> Void
    let now: @Sendable () -> Date

    /// Fills `state.records` until every EPUB is read, a failure that is not the book's own
    /// stops it (authentication, network, timeout), it is cancelled, or `stopAfterBatch` asks
    /// it to stop. Every stop saves.
    func run(from state: WebDAVIndexState, stopAfterBatch: @Sendable () -> Bool) async -> WebDAVIndexState {
        var state = state
        let order = state.records.indices
            .filter { state.records[$0].needsFill }
            .sorted { (state.records[$0].completeness, state.records[$0].record.key.sortKey)
                < (state.records[$1].completeness, state.records[$1].record.key.sortKey) }
        var sinceSave = 0
        var readCount = 0
        var failed = 0
        let started = SourcePerfTrace.now
        defer {
            SourcePerfTrace.record("works.webdav.fill", "read=\(readCount) failed=\(failed) left=\(state.records.filter(\.needsFill).count)",
                                   since: started, thresholdMs: 0)
        }
        for index in order {
            if Task.isCancelled || stopAfterBatch() { break }
            let file = state.records[index]
            let url = Self.url(of: file, under: state.root)
            do {
                let package = try await read(url)
                state.records[index] = filled(file, with: package)
                readCount += 1
            } catch {
                let failure: SourceFailure
                do { failure = try SourceFailure.classify(error) } catch { break }  // cancelled
                switch failure.kind {
                case .authentication, .network, .timeout:
                    AppLogger.network("WebDAV metadata read stopped", error: SourceFailure.loggable(failure),
                                      context: ["connection": connectionID, "kind": failure.kind.rawValue])
                    save(state)
                    return state
                default:
                    // The book's own problem (not an EPUB after all, a broken package): recorded,
                    // and not retried until the file changes.
                    state.records[index].filled = .failed(failure.kind)
                    failed += 1
                }
            }
            sinceSave += 1
            if sinceSave >= limits.saveEvery {
                save(state)
                sinceSave = 0
            }
        }
        save(state)
        return state
    }

    /// The record's item is the path below the root, decoded (1a); each component is encoded
    /// again on the way back.
    static func url(of file: IndexedFile, under root: URL) -> URL {
        file.record.key.item.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func filled(_ file: IndexedFile, with package: PublicationSession.RemotePackageMetadata) -> IndexedFile {
        var file = file
        let metadata = package.metadata
        let fields = ImportedMetadataCapture.epubFields(
            sourceItem: file.record.key, identifiers: package.identifiers, languages: metadata.languages,
            description: metadata.description, subjects: metadata.subjects.map(\.name),
            publishers: metadata.publishers.map(\.name), published: metadata.published,
            series: ImportedMetadataCapture.EPUBSeries(metadata), now: now()
        )
        file.identifiers = fields.identifiers
        var values = fields.values
        let authors = metadata.authors.map(\.name).filter { !$0.isEmpty }
        if !authors.isEmpty {
            values.append(MetadataValue(field: .authors, value: .texts(authors), provider: file.record.key.instance,
                                        sourceItem: file.record.key, fetchedAt: now()))
        }
        file.values = values
        if let cover = package.cover {
            file.cover = storeCover(cover, mediaType: package.coverMediaType, for: file.record.key)
        }
        file.filled = .read
        return file
    }

    /// `Caches/Works/covers/<hash of the key>.<ext>`: discardable (design §10.1).
    private func storeCover(_ data: Data, mediaType: String?, for key: SourceItemKey) -> String? {
        let digest = SHA256.hash(data: Data(key.sortKey.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext: String
        switch mediaType?.lowercased() {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        let name = "\(digest).\(ext)"
        do {
            try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            try data.write(to: coverDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            AppLogger.cache("⟐ WebDAV cover could not be saved", error: error, context: ["connection": connectionID])
            return nil
        }
    }
}
