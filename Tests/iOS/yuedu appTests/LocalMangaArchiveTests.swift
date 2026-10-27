import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Local manga archive")
struct LocalMangaArchiveTests {

    @Test("image entries are filtered and naturally sorted")
    func imageEntriesAreFilteredAndSorted() async throws {
        let archiveURL = try await makeArchive(entries: [
            "chapter/002.png": Data("two".utf8),
            "chapter/001.jpg": Data("one".utf8),
            "chapter/.hidden.jpg": Data("hidden".utf8),
            "__MACOSX/003.jpg": Data("macos".utf8),
            "notes.txt": Data("text".utf8)
        ])

        let paths = try await LocalMangaArchive.imageEntryPaths(in: archiveURL)

        #expect(paths == ["chapter/001.jpg", "chapter/002.png"])
    }

    @Test("ComicInfo metadata supplies import defaults")
    func comicInfoSuppliesImportDefaults() async throws {
        let comicInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ComicInfo>
            <Title>Episode 5</Title>
            <Series>Sample Series</Series>
            <Number>5</Number>
            <Volume>2</Volume>
            <Summary>Imported summary</Summary>
            <Writer>Writer A</Writer>
            <Penciller>Artist B</Penciller>
            <Manga>YesAndRightToLeft</Manga>
        </ComicInfo>
        """
        let archiveURL = try await makeArchive(entries: [
            "001.jpg": Data("one".utf8),
            "ComicInfo.xml": Data(comicInfo.utf8)
        ])

        let info = try await LocalMangaArchive.inspect(url: archiveURL)

        #expect(info.title == "Sample Series")
        #expect(info.chapterTitle == "Episode 5")
        #expect(info.author == "Writer A")
        #expect(info.pageCount == 1)
        #expect(info.comicInfo?.number == "5")
        #expect(info.comicInfo?.volume == 2)
    }

    @Test("pages are archive entries, loaded on demand in reading order")
    @MainActor
    func pagesLoadFromArchiveInOrder() async throws {
        // Real images, each its own width, so the loaded page says which entry it came from.
        let archiveURL = try await makeArchive(entries: [
            "vol/page-10.png": try pngData(width: 30),
            "vol/page-2.png": try pngData(width: 20),
            "vol/page-1.png": try pngData(width: 10),
            "ComicInfo.xml": Data("<ComicInfo/>".utf8)
        ], compressed: ["vol/page-10.png"])
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        // `pages(archiveFilename:)` resolves the filename in Documents, as for an imported book.
        let filename = "\(UUID().uuidString).cbz"
        let documentsArchive = LocalMangaArchive.archiveURL(for: filename)
        try FileManager.default.copyItem(at: archiveURL, to: documentsArchive)
        defer { try? FileManager.default.removeItem(at: documentsArchive) }

        let pages = try await LocalMangaArchive.pages(archiveFilename: filename)

        #expect(pages.map(\.id) == [0, 1, 2])
        #expect(pages.map(\.renderSource) == [
            .archiveImage(sourceFilename: filename, entryPath: "vol/page-1.png"),
            .archiveImage(sourceFilename: filename, entryPath: "vol/page-2.png"),
            .archiveImage(sourceFilename: filename, entryPath: "vol/page-10.png")
        ])
        #expect(pages.allSatisfy { $0.localURL == nil && $0.headers.isEmpty })
        #expect(pages.allSatisfy { !$0.renderSource.isRasterizedOnDemand })

        // The reader's loader reads each page straight out of the archive — stored and
        // deflated entries alike.
        var widths: [Int] = []
        for page in pages {
            let image = await FixedPageImageLoader.loadImage(for: page, targetWidth: 0, renderScale: 1)
            widths.append(image?.cgImage?.width ?? 0)
        }
        #expect(widths == [10, 20, 30])
    }

    @Test("the reader serves entries from one opened archive")
    func readerServesEntries() async throws {
        let archiveURL = try await makeArchive(entries: [
            "b.png": Data("bee".utf8),
            "a.jpg": Data("ay".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let reader = LocalMangaArchiveReader()

        let paths = try await reader.imageEntryPaths(in: archiveURL)
        let second = try await reader.data(entryPath: "b.png", in: archiveURL)
        let first = try await reader.data(entryPath: "a.jpg", in: archiveURL)

        #expect(paths == ["a.jpg", "b.png"])
        #expect(first == Data("ay".utf8))
        #expect(second == Data("bee".utf8))
        await #expect(throws: LocalMangaArchiveError.self) {
            _ = try await reader.data(entryPath: "missing.jpg", in: archiveURL)
        }
    }

    @Test("legacy extracted pages go once the archive is verified, and stay without it")
    func legacyExtractedPagesCleanup() async throws {
        let archiveURL = try await makeArchive(entries: ["001.jpg": Data("one".utf8)])
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_manga-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readable = UUID()
        let orphaned = UUID()
        for bookId in [readable, orphaned] {
            let chapter = LocalMangaArchive.legacyExtractedPagesDirectory(bookId: bookId, root: root)
                .appendingPathComponent("0", isDirectory: true)
            try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: chapter.appendingPathComponent("0.jpg"))
        }

        // The archive is gone (deleted in Files): the extracted pages are the only copy left.
        let missingArchive = archiveURL.deletingLastPathComponent().appendingPathComponent("gone.cbz")
        let removedOrphan = await LocalMangaArchive.discardLegacyExtractedPages(
            bookId: orphaned, archiveURL: missingArchive, root: root
        )
        #expect(!removedOrphan)
        #expect(FileManager.default.fileExists(
            atPath: LocalMangaArchive.legacyExtractedPagesDirectory(bookId: orphaned, root: root).path
        ))

        let removed = await LocalMangaArchive.discardLegacyExtractedPages(
            bookId: readable, archiveURL: archiveURL, root: root
        )
        #expect(removed)
        #expect(!FileManager.default.fileExists(
            atPath: LocalMangaArchive.legacyExtractedPagesDirectory(bookId: readable, root: root).path
        ))
        // Another book's pages are still there, so the root stays.
        #expect(FileManager.default.fileExists(atPath: root.path))

        // Once the last book's pages are gone, so is the root.
        #expect(LocalMangaArchive.removeLegacyExtractedPages(bookId: orphaned, root: root))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // Nothing to remove is not an error.
        #expect(!LocalMangaArchive.removeLegacyExtractedPages(bookId: orphaned, root: root))
    }
}

@Suite("BookStore local comic import")
@MainActor
struct BookStoreLocalMangaImportTests {

    @Test("importing a CBZ keeps only the archive and extracts no pages")
    func importWritesNoExtractedPages() async throws {
        let archiveURL = try await makeArchive(entries: [
            "002.jpg": Data("two".utf8),
            "001.jpg": Data("one".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json"))

        let book = try await store.importLocalManga(url: archiveURL)

        #expect(book.source == "local_manga")
        #expect(book.resolvedPipelineKind == .manga)
        let storedArchive = LocalMangaArchive.archiveURL(for: book.contentFilename)
        #expect(FileManager.default.fileExists(atPath: storedArchive.path))
        #expect(!FileManager.default.fileExists(
            atPath: LocalMangaArchive.legacyExtractedPagesDirectory(bookId: book.id).path
        ))

        let pages = try await LocalMangaArchive.pages(archiveFilename: book.contentFilename)
        #expect(pages.map(\.renderSource) == [
            .archiveImage(sourceFilename: book.contentFilename, entryPath: "001.jpg"),
            .archiveImage(sourceFilename: book.contentFilename, entryPath: "002.jpg")
        ])

        store.delete(bookId: book.id)

        #expect(!FileManager.default.fileExists(atPath: storedArchive.path))
    }
}

private func makeArchive(entries: [String: Data], compressed: Set<String> = []) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let archiveURL = root.appendingPathComponent("sample.cbz")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let archive = try await Archive(url: archiveURL, accessMode: .create)
    for (path, data) in entries {
        let fileURL = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
        try await archive.addEntry(
            with: path,
            fileURL: fileURL,
            compressionMethod: compressed.contains(path) ? .deflate : .none
        )
    }
    return archiveURL
}

private func pngData(width: Int) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: width, height: 16)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.gray.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return try #require(image.pngData())
}
