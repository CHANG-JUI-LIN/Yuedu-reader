import Foundation
import ReadiumZIPFoundation
import UIKit

struct LocalMangaComicInfo: Equatable {
    var title: String?
    var series: String?
    var number: String?
    var volume: Int?
    var summary: String?
    var writer: String?
    var penciller: String?
    var manga: String?
}

struct LocalMangaImportInfo: Equatable {
    let title: String
    let author: String
    let chapterTitle: String
    let pageCount: Int
    let comicInfo: LocalMangaComicInfo?
}

enum LocalMangaArchiveError: LocalizedError {
    case invalidFileType
    case cannotReadArchive
    case noImagesFound
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return localized("不支援的漫畫格式")
        case .cannotReadArchive:
            return localized("無法讀取漫畫壓縮檔")
        case .noImagesFound:
            return localized("漫畫壓縮檔中未找到圖片")
        case .extractionFailed:
            return localized("漫畫圖片解壓失敗")
        }
    }
}

enum LocalMangaArchive {
    static let allowedArchiveExtensions = Set(["cbz", "zip"])
    static let allowedImageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"])

    static func supports(_ url: URL) -> Bool {
        allowedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    static func archiveURL(for filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    static func bookDirectory(bookId: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("local_manga", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    static func chapterDirectory(bookId: UUID, chapterIndex: Int) -> URL {
        bookDirectory(bookId: bookId)
            .appendingPathComponent(String(chapterIndex), isDirectory: true)
    }

    static func inspect(url: URL) async throws -> LocalMangaImportInfo {
        guard supports(url) else { throw LocalMangaArchiveError.invalidFileType }
        let paths = try await imageEntryPaths(in: url)
        guard !paths.isEmpty else { throw LocalMangaArchiveError.noImagesFound }

        let comicInfo = await comicInfo(in: url)
        let fallbackTitle = cleanTitle(url.deletingPathExtension().lastPathComponent)
        let title = firstNonEmpty(comicInfo?.series, fallbackTitle)
        let chapterTitle = firstNonEmpty(comicInfo?.title, fallbackTitle)
        let author = firstNonEmpty(comicInfo?.writer, comicInfo?.penciller, localized("未知作者"))
        return LocalMangaImportInfo(
            title: title,
            author: author,
            chapterTitle: chapterTitle,
            pageCount: paths.count,
            comicInfo: comicInfo
        )
    }

    static func imageEntryPaths(in archiveURL: URL) async throws -> [String] {
        guard supports(archiveURL) else { throw LocalMangaArchiveError.invalidFileType }
        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LocalMangaArchiveError.cannotReadArchive
        }
        let entries = (try? await archive.entries()) ?? []
        let paths = entries.map(\.path)
            .filter(isImageEntryPath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !paths.isEmpty else { throw LocalMangaArchiveError.noImagesFound }
        return paths
    }

    static func extractPages(from archiveURL: URL, to directory: URL) async throws -> [MangaPage] {
        let paths = try await imageEntryPaths(in: archiveURL)
        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LocalMangaArchiveError.cannotReadArchive
        }

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LocalMangaArchiveError.extractionFailed
        }

        var pages: [MangaPage] = []
        for (index, path) in paths.enumerated() {
            guard let entry = try? await archive.get(path) else {
                throw LocalMangaArchiveError.extractionFailed
            }
            let ext = (path as NSString).pathExtension.lowercased()
            let outputURL = directory.appendingPathComponent("\(index).\(ext)")
            do {
                _ = try await archive.extract(entry, to: outputURL, skipCRC32: true)
            } catch {
                throw LocalMangaArchiveError.extractionFailed
            }
            pages.append(MangaPage(id: index, imageURL: outputURL.absoluteString, headers: [:], localURL: outputURL))
        }
        return pages
    }

    static func pagesForExtractedChapter(bookId: UUID, chapterIndex: Int) -> [MangaPage] {
        let directory = chapterDirectory(bookId: bookId, chapterIndex: chapterIndex)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { allowedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                localPageIndex(lhs) < localPageIndex(rhs)
            }
            .enumerated()
            .map { index, url in
                MangaPage(id: index, imageURL: url.absoluteString, headers: [:], localURL: url)
            }
    }

    static func coverImageData(from archiveURL: URL) async -> (data: Data, fileExtension: String)? {
        guard let firstPath = try? await imageEntryPaths(in: archiveURL).first,
              let archive = try? await Archive(url: archiveURL, accessMode: .read),
              let entry = try? await archive.get(firstPath)
        else { return nil }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? await archive.extract(entry, to: tempURL, skipCRC32: true)) != nil,
              let data = try? Data(contentsOf: tempURL)
        else { return nil }
        return (data, (firstPath as NSString).pathExtension.lowercased())
    }

    private static func comicInfo(in archiveURL: URL) async -> LocalMangaComicInfo? {
        guard let archive = try? await Archive(url: archiveURL, accessMode: .read),
              let entries = try? await archive.entries(),
              let path = entries.map(\.path).first(where: { $0.lowercased().hasSuffix("comicinfo.xml") }),
              let entry = try? await archive.get(path)
        else { return nil }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? await archive.extract(entry, to: tempURL, skipCRC32: true)) != nil,
              let data = try? Data(contentsOf: tempURL),
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        return LocalMangaComicInfoParser.parse(xml)
    }

    private static func isImageEntryPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.hasPrefix(".") else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
        return allowedImageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    private static func localPageIndex(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent) ?? Int.max
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func cleanTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-,"))
    }
}

private final class LocalMangaComicInfoParser: NSObject, XMLParserDelegate {
    private var currentValue = ""

    private var title: String?
    private var series: String?
    private var number: String?
    private var volume: Int?
    private var summary: String?
    private var writer: String?
    private var penciller: String?
    private var manga: String?

    static func parse(_ xml: String) -> LocalMangaComicInfo? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = LocalMangaComicInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return LocalMangaComicInfo(
            title: delegate.title,
            series: delegate.series,
            number: delegate.number,
            volume: delegate.volume,
            summary: delegate.summary,
            writer: delegate.writer,
            penciller: delegate.penciller,
            manga: delegate.manga
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch elementName {
            case "Title": title = value
            case "Series": series = value
            case "Number": number = value
            case "Volume": volume = Int(value)
            case "Summary": summary = value
            case "Writer": writer = value
            case "Penciller": penciller = value
            case "Manga": manga = value
            default: break
            }
        }
        currentValue = ""
    }
}
