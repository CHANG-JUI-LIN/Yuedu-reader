import Foundation
import ReadiumShared
import ReadiumZIPFoundation

/// Uses Readium's archive extension point with bounded remote read-ahead.
/// Readium 3.8's default ZIP opener reads ahead 6 MB on every distant seek;
/// small EPUB entries can consequently transfer more than the complete book.
/// Keep this adapter until the upstream opener exposes its buffering policy.
struct RemoteEPUBArchiveOpener: ArchiveOpener {
    func open(resource: any Resource, format: Format) async -> Result<ContainerAsset, ArchiveOpenError> {
        guard format.conformsTo(.zip) else { return .failure(.formatNotSupported(format)) }
        do {
            let container = try await RemoteEPUBContainer(resource: resource)
            return .success(ContainerAsset(container: container, format: format))
        } catch {
            return .failure(.reading(.wrap(error) ?? .decoding(error)))
        }
    }

    func sniffOpen(resource: any Resource) async -> Result<ContainerAsset, ArchiveSniffOpenError> {
        await open(resource: resource, format: Format(specifications: .zip, mediaType: .zip, fileExtension: "zip"))
            .mapError { error in
                switch error {
                case .formatNotSupported: return .formatNotRecognized
                case .reading(let error): return .reading(error)
                }
            }
    }
}

private struct RemoteEPUBContainer: Container {
    let sourceURL: (any AbsoluteURL)?
    let entries: Set<AnyURL>
    private let archive: ReadiumZIPFoundation.Archive
    private let entriesByPath: [RelativeURL: Entry]

    init(resource: any Resource) async throws {
        let source = try await RemoteZIPDataSource(resource: resource)
        let archive = try await ReadiumZIPFoundation.Archive(
            url: resource.sourceURL?.url, dataSource: source,
            defaultReadChunkSize: RemoteZIPDataSource.readAheadSize)
        var paths: [RelativeURL: Entry] = [:]
        for entry in try await archive.entries() where entry.type == .file {
            guard let path = RelativeURL(path: entry.path)?.normalized, !path.path.isEmpty else { continue }
            paths[path] = entry
        }
        self.sourceURL = resource.sourceURL
        self.archive = archive
        self.entriesByPath = paths
        self.entries = Set(paths.keys.map(\.anyURL))
    }

    subscript(url: any URLConvertible) -> (any Resource)? {
        guard let path = url.anyURL.relativeURL?.normalized, let entry = entriesByPath[path] else { return nil }
        return RemoteZIPEntryResource(archive: archive, entry: entry)
    }
}

private struct RemoteZIPEntryResource: Resource {
    let archive: ReadiumZIPFoundation.Archive
    let entry: Entry
    let sourceURL: (any AbsoluteURL)? = nil

    func estimatedLength() async -> ReadResult<UInt64?> { .success(entry.uncompressedSize) }

    func properties() async -> ReadResult<ResourceProperties> {
        .success(ResourceProperties {
            $0.filename = RelativeURL(path: entry.path)?.lastPathSegment
            $0.archive = ArchiveProperties(
                entryLength: entry.isCompressed ? entry.compressedSize : entry.uncompressedSize,
                isEntryCompressed: entry.isCompressed)
        })
    }

    func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        do {
            try Task.checkCancellation()
            if let range {
                try await archive.extractRange(range, of: entry) { data in
                    try Task.checkCancellation()
                    consume(data)
                }
            } else {
                _ = try await archive.extract(entry, skipCRC32: true) { data in
                    try Task.checkCancellation()
                    consume(data)
                }
            }
            return .success(())
        } catch {
            return .failure(.wrap(error) ?? .decoding(error))
        }
    }
}

/// One archive shares its directory tail and Readium's in-memory read buffer.
/// All reads still use the injected authenticated, version-validated Resource;
/// persistent ranges remain owned by RemoteLibraryResourceClient.
private actor RemoteZIPDataSource: ReadiumZIPFoundation.DataSource {
    static let readAheadSize = 64 * 1024
    let isWritable = false
    private let resource: any Resource
    private let byteCount: UInt64
    private let tailStart: UInt64
    private let tail: Data

    init(resource: any Resource) async throws {
        guard let length = try await resource.estimatedLength().get(), length > 0 else {
            throw ReadError.decoding("Missing ZIP content length")
        }
        // EOCD (including its maximum comment) and ZIP64 trailer. Subtract only
        // after clamping the count, so even very short/malformed ZIPs are safe.
        let tailStart = length - min(length, 65_557 + 76)
        let tail = try await resource.read(range: tailStart..<length).get()
        guard UInt64(tail.count) == length - tailStart else {
            throw ReadError.decoding("Incomplete ZIP directory tail")
        }
        self.byteCount = length
        self.tailStart = tailStart
        self.tail = tail
        self.resource = resource.buffered(size: Self.readAheadSize)
    }

    func length() async throws -> UInt64 { byteCount }

    func openRead() async throws -> any DataSourceTransaction { Transaction(source: self) }

    private func read(at offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard count > 0, offset < byteCount else { return Data() }
        let end = offset + min(UInt64(count), byteCount - offset)
        if offset >= tailStart {
            return tail.subdata(in: Int(offset - tailStart)..<Int(end - tailStart))
        }
        return try await resource.read(range: offset..<end).get()
    }

    private actor Transaction: ReadiumZIPFoundation.DataSourceTransaction {
        let source: RemoteZIPDataSource
        private var offset: UInt64 = 0

        init(source: RemoteZIPDataSource) { self.source = source }
        func position() async throws -> UInt64 { offset }
        func seek(to position: UInt64) async throws { offset = position }
        func read(length: Int) async throws -> Data {
            let data = try await source.read(at: offset, count: length)
            offset += UInt64(data.count)
            return data
        }
    }
}
