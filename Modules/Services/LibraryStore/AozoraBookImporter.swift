import Foundation
import ReadiumZIPFoundation

/// Imports an Aozora Bunko text, or an official Aozora zip, as an EPUB book
/// converted at import (Phase 1b, route C). The original file is kept next to the
/// EPUB, so another device can convert its own copy and a converter change can
/// regenerate it. One type reads Aozora zips.
@MainActor
enum AozoraBookImporter {
    enum ImportError: Error, CustomStringConvertible {
        case undecodable(String)
        var description: String {
            switch self {
            case .undecodable(let file): return "\(file) could not be decoded"
            }
        }
    }

    /// A text the detector accepted, decoded, with the figures its document names.
    struct Converted: Sendable {
        let epub: URL
        let manifest: AozoraEPUBManifest
        let encoding: String.Encoding
        let workDirectory: URL
    }

    /// Whether a `.txt` is an Aozora Bunko text, read off the main actor: a TXT novel
    /// can be tens of megabytes. A file that cannot be decoded is not one; the TXT
    /// importer reports it.
    static func isAozoraText(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                return AozoraDocumentDetector.isAozoraDocument(try TXTFileReader.readTextFile(url: url))
            } catch {
                AppLogger.error("Aozora detection could not read a text", error: error,
                                context: ["file": url.lastPathComponent])
                return false
            }
        }.value
    }

    /// Converts and imports an Aozora `.txt`, or a zip whose text the detector
    /// accepts. Returns nil for a zip that holds no Aozora text, so its caller can
    /// try the next importer; a conversion failure throws, with no TXT fallback.
    static func importBook(at url: URL, title: String?, store: BookStore) async throws -> ReadingBook? {
        let isZip = url.pathExtension.lowercased() == "zip"
        let result = try await Task.detached(priority: .userInitiated) {
            try await SourcePerfTrace.spanAsync("aozora.import.convert", url.pathExtension.lowercased()) {
                try await convert(url, isZip: isZip)
            }
        }.value
        guard let converted = result else { return nil }
        defer { remove(converted.workDirectory, reason: "work folder") }
        try Task.checkCancellation()

        var book = try await store.importEpub(url: converted.epub, title: title, requireValidPublication: true)
        let original = (book.contentFilename as NSString).deletingPathExtension + ".aozora." + (isZip ? "zip" : "txt")
        let originalURL = StorageLocations.bookFile(original)
        do {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: originalURL.path) {
                try FileManager.default.removeItem(at: originalURL)
            }
            try FileManager.default.copyItem(at: url, to: originalURL)
            book.aozora = AozoraBookSource(originalFilename: original, sourceEncoding: converted.encoding.rawValue)
            store.saveReadingBook(book)
            return book
        } catch {
            // The book is on the shelf already; take it off with its files.
            store.delete(bookId: book.id)
            remove(originalURL, reason: "original")
            throw error
        }
    }

    /// Off the main actor: the text, decoded and converted into an EPUB in a work
    /// folder, with the zip's figures beside it. Nil when a zip holds no Aozora text.
    /// A regeneration passes the book's identifier so the package keeps it.
    nonisolated static func convert(_ url: URL, isZip: Bool, identifier: String? = nil) async throws -> Converted? {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("AozoraImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let textURL: URL
            var archive: Archive?
            if isZip {
                let opened = try await Archive(url: url, accessMode: .read)
                guard let found = try await aozoraText(in: opened, into: work) else {
                    remove(work, reason: "work folder")
                    return nil
                }
                archive = opened
                textURL = found
            } else {
                textURL = url
            }
            // The TXT reader's own decoding, and the encoding its detection picks.
            let encoding = try TXTFileReader.detectEncodingBySampling(url: textURL)
            let text = try TXTFileReader.readTextFile(url: textURL)
            let document = AozoraDocumentParser.parse(text)
            let chapters = AozoraChapterPlanner.plan(document, source: text)
            var images: [String: URL] = [:]
            if let archive {
                images = try await figures(named: AozoraEPUBWriter.figureNames(in: document), in: archive,
                                           beside: textURL, into: work)
            }
            let original = try Data(contentsOf: url)
            let epub = work.appendingPathComponent("book.epub")
            let manifest = try await AozoraEPUBWriter.write(
                document, chapters: chapters, images: images,
                source: AozoraEPUBManifest.Source(sha256: AozoraEPUBWriter.sha256(original), encoding: encoding.rawValue,
                                                  length: text.utf16.count),
                identifier: identifier ?? "urn:uuid:\(UUID().uuidString)", to: epub)
            return Converted(epub: epub, manifest: manifest, encoding: encoding, workDirectory: work)
        } catch {
            remove(work, reason: "work folder")
            throw error
        }
    }

    // MARK: Zips

    /// The first visible `.txt` entry the detector accepts, extracted into `work`.
    /// A comic's readme is not enough: the detector needs a notation block or a
    /// 底本 colophon.
    nonisolated static func aozoraText(in archive: Archive, into work: URL) async throws -> URL? {
        let paths = try await archive.entries()
            .filter { $0.type == .file && isVisible($0.path) && ($0.path as NSString).pathExtension.lowercased() == "txt" }
            .map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for path in paths {
            let destination = work.appendingPathComponent("text-" + (path as NSString).lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                guard let entry = try await archive.get(path) else { continue }
                _ = try await archive.extract(entry, to: destination)
                if AozoraDocumentDetector.isAozoraDocument(try TXTFileReader.readTextFile(url: destination)) {
                    return destination
                }
            } catch {
                AppLogger.error("Aozora zip probe skipped a text entry", error: error,
                                context: ["entry": (path as NSString).lastPathComponent])
            }
        }
        return nil
    }

    /// The figures the document names, from the zip: an entry whose file name is the
    /// figure's, nearest the text's own folder first.
    nonisolated static func figures(named names: [String], in archive: Archive, beside text: URL,
                                    into work: URL) async throws -> [String: URL] {
        let entries = try await archive.entries().filter { $0.type == .file && isVisible($0.path) }
        var result: [String: URL] = [:]
        for name in Set(names) {
            let wanted = (name as NSString).lastPathComponent.lowercased()
            let candidates = entries.filter { ($0.path as NSString).lastPathComponent.lowercased() == wanted }
            guard let entry = candidates.min(by: { $0.path.count < $1.path.count }) else {
                AppLogger.parse("[Aozora] a figure the text names is not in the zip", context: ["figure": name],
                                level: .notice)
                continue
            }
            let destination = work.appendingPathComponent("figure-\(result.count)-" + wanted)
            _ = try await archive.extract(entry, to: destination)
            result[name] = destination
        }
        return result
    }

    nonisolated private static func isVisible(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.hasPrefix(".") else { return false }
        return !components.contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
    }

    nonisolated static func remove(_ url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.error("Aozora import could not remove its \(reason)", error: error,
                            context: ["file": url.lastPathComponent])
        }
    }
}
