import CryptoKit
import Foundation

/// On-disk store for the illustrations of an ONLINE book's chapters, keyed by image URL.
///
/// Offline download fills it (`OfflineChapterStore.persistTextImages`), the reader reads it before
/// touching the network (`OnlineProviderAttributedStringBuilder.loadImage`). Prose chapters used to
/// have nothing here at all — only comics downloaded their images — so a downloaded light novel
/// still needed a live connection to show its 插图 pages, and re-opening the chapter re-downloaded
/// every plate. Legado has always cached them per book (`BookHelp.saveImage` → `ImageProvider`).
///
/// One flat directory per book instead of one per chapter: images are keyed by URL, so the same
/// plate referenced from two chapters is stored once, and a source switch cannot leave a chapter
/// pointing at another chapter's file. `OfflineChapterStore.removeBook` deletes the book directory
/// this lives under, so nothing here outlives its book.
struct OnlineImageDiskCache {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Extensions worth preserving from the URL. Anything else (a query-string URL, an API
    /// endpoint) is stored as `.img`; the decoder sniffs the bytes, it never reads the name.
    private static let knownExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "svg"
    ]

    /// Stable filename for an image URL: SHA-256 of the URL plus its extension. Hashing keeps
    /// path-length and illegal-character problems out of a name we don't control, and makes the
    /// same URL resolve to the same file from either side of the app.
    static func filename(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        return knownExtensions.contains(ext) ? "\(hex).\(ext)" : "\(hex).img"
    }

    func fileURL(for url: String) -> URL {
        directory.appendingPathComponent(Self.filename(for: url))
    }

    func contains(_ url: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: url).path)
    }

    func data(for url: String) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    func write(_ data: Data, for url: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: url), options: .atomic)
    }
}
