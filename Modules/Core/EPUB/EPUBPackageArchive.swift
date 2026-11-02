import CryptoKit
import Foundation
import ReadiumZIPFoundation

/// Packs the files of an EPUB that a converter wrote (Aozora Bunko text, MOBI) into
/// one OCF archive: `mimetype` first and stored, as OCF requires, then every entry
/// deflated, in the order given.
enum EPUBPackageArchive {
    struct Entry {
        enum Content {
            case data(Data)
            /// A file already on disk, added without reading it into memory.
            case file(URL)
        }

        /// The path inside the archive, e.g. `OPS/package.opf`.
        var path: String
        var content: Content

        static func data(_ path: String, _ data: Data) -> Entry { Entry(path: path, content: .data(data)) }
        static func text(_ path: String, _ text: String) -> Entry { Entry(path: path, content: .data(Data(text.utf8))) }
        static func file(_ path: String, _ url: URL) -> Entry { Entry(path: path, content: .file(url)) }
    }

    /// The container both converters write: the package document is `OPS/package.opf`.
    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>

        """

    /// Writes `entries` to `url`, replacing any file there.
    static func write(_ entries: [Entry], to url: URL) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                AppLogger.parse("[EPUB] could not remove the package staging folder: \(error)", level: .notice)
            }
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try await Archive(url: url, accessMode: .create)
        try await add(.data("mimetype", Data("application/epub+zip".utf8)), to: archive, in: staging,
                      compression: .none)
        for entry in entries {
            try await add(entry, to: archive, in: staging, compression: .deflate)
        }
    }

    /// The archive library adds entries from files, so in-memory data goes through
    /// the staging folder.
    private static func add(_ entry: Entry, to archive: Archive, in staging: URL,
                            compression: CompressionMethod) async throws {
        switch entry.content {
        case .data(let data):
            let file = staging.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file)
            try await archive.addEntry(with: entry.path, fileURL: file, compressionMethod: compression)
        case .file(let url):
            try await archive.addEntry(with: entry.path, fileURL: url, compressionMethod: compression)
        }
    }

    /// Now, as `dcterms:modified` wants it: `2026-11-01T09:30:00Z`.
    static func modifiedTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
