import Foundation
import ReadiumZIPFoundation
import Testing
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

    @Test("pages extract to stable local image files")
    func pagesExtractToStableLocalFiles() async throws {
        let archiveURL = try await makeArchive(entries: [
            "page-02.webp": Data("two".utf8),
            "page-01.jpg": Data("one".utf8)
        ])
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let pages = try await LocalMangaArchive.extractPages(from: archiveURL, to: outputDirectory)

        #expect(pages.map(\.id) == [0, 1])
        #expect(pages.map { $0.localURL?.lastPathComponent } == ["0.jpg", "1.webp"])
        #expect(pages.allSatisfy { $0.headers.isEmpty })
        #expect(pages.allSatisfy { page in
            guard let localURL = page.localURL else { return false }
            return FileManager.default.fileExists(atPath: localURL.path)
        })
    }
}

private func makeArchive(entries: [String: Data]) async throws -> URL {
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
        try await archive.addEntry(with: path, fileURL: fileURL)
    }
    return archiveURL
}
