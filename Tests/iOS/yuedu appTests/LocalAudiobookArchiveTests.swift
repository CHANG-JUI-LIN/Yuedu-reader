import AVFoundation
import Foundation
import ReadiumZIPFoundation
import Testing
@testable import yuedu_app

@Suite("Local audiobook archive")
struct LocalAudiobookArchiveTests {

    @Test("audio entries are filtered and naturally sorted")
    func audioEntriesAreFilteredAndSorted() async throws {
        let archiveURL = try await makeAudioArchive(entries: [
            "book/002.m4a": Data("two".utf8),
            "book/001.mp3": Data("one".utf8),
            "book/.hidden.mp3": Data("hidden".utf8),
            "__MACOSX/003.mp3": Data("macos".utf8),
            "cover.jpg": Data("image".utf8),
            "notes.txt": Data("text".utf8)
        ])

        let paths = try await LocalAudiobookArchive.audioEntryPaths(in: archiveURL)

        #expect(paths == ["book/001.mp3", "book/002.m4a"])
        #expect(await LocalAudiobookArchive.zipContainsAudio(archiveURL))
    }

    @Test("zip without audio is not treated as audiobook")
    func zipWithoutAudioIsNotAudiobook() async throws {
        let archiveURL = try await makeAudioArchive(entries: [
            "001.jpg": Data("image".utf8),
            "notes.txt": Data("text".utf8)
        ])

        #expect(await LocalAudiobookArchive.zipContainsAudio(archiveURL) == false)
    }

    @Test("chapter seed fallback and duration clamp")
    func chapterSeedFallbackAndClamp() {
        let empty = LocalAudiobookArchive.chapterSeeds(
            fromGroups: [],
            totalDurationSeconds: 120,
            fallbackTitle: "Whole Book"
        )
        #expect(empty == [
            LocalAudiobookChapterSeed(
                title: "Whole Book",
                audioStartSeconds: nil,
                audioDurationSeconds: nil
            )
        ])

        let groups = [
            makeTimedMetadataGroup(title: "Intro", start: 0, duration: 30),
            makeTimedMetadataGroup(title: "Final", start: 30, duration: 100)
        ]
        let seeds = LocalAudiobookArchive.chapterSeeds(
            fromGroups: groups,
            totalDurationSeconds: 80,
            fallbackTitle: "Book"
        )

        #expect(seeds.count == 2)
        #expect(seeds[0].title == "Intro")
        #expect(seeds[0].audioStartSeconds == 0)
        #expect(seeds[0].audioDurationSeconds == 30)
        #expect(seeds[1].title == "Final")
        #expect(seeds[1].audioStartSeconds == 30)
        #expect(seeds[1].audioDurationSeconds == 50)
    }
}

@Suite("Local audiobook metadata")
struct LocalAudiobookMetadataTests {

    @Test("OnlineChapterRef decodes old JSON and round-trips audio timing")
    func onlineChapterRefAudioCodable() throws {
        let oldJSON = """
        {
          "id": "\(UUID().uuidString)",
          "index": 0,
          "title": "Ch 1",
          "url": "local_audio/book/000.mp3",
          "isVolume": false,
          "isVip": false,
          "isPay": false,
          "cachedFilename": null,
          "runtimeVariables": null
        }
        """
        let decoded = try JSONDecoder().decode(OnlineChapterRef.self, from: Data(oldJSON.utf8))
        #expect(decoded.audioStartSeconds == nil)
        #expect(decoded.audioDurationSeconds == nil)

        let timed = OnlineChapterRef(
            index: 1,
            title: "Marker",
            url: "book.m4b",
            audioStartSeconds: 12.5,
            audioDurationSeconds: 34.0
        )
        let roundTrip = try JSONDecoder().decode(
            OnlineChapterRef.self,
            from: try JSONEncoder().encode(timed)
        )
        #expect(roundTrip.audioStartSeconds == 12.5)
        #expect(roundTrip.audioDurationSeconds == 34.0)
    }

    @Test("local_audio source resolves to audiobook pipeline")
    func localAudioSourceResolvesToAudio() {
        let book = ReadingBook(title: "Local Audio", source: "local_audio", contentFilename: "local_audio/book")

        #expect(book.resolvedPipelineKind == .audio)
        #expect(book.allowsUserSelectedReaderFont == false)
    }
}

@Suite("Local chapter audio provider")
@MainActor
struct LocalChapterAudioProviderTests {

    @Test("resolves local chapter URL and timing")
    func resolvesLocalChapterURLAndTiming() async throws {
        let filename = "local-audio-\(UUID().uuidString).mp3"
        let fileURL = documentsURL(for: filename)
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var book = ReadingBook(title: "Local Audio", source: "local_audio", contentFilename: filename)
        book.contentPipelineKind = .audio
        book.onlineChapters = [
            OnlineChapterRef(
                index: 0,
                title: "Chapter",
                url: filename,
                audioStartSeconds: 10,
                audioDurationSeconds: 20
            )
        ]

        let audio = try await LocalChapterAudioProvider().audio(
            for: book,
            chapterIndex: 0,
            store: BookStore(metadataFileURL: tempMetadataURL())
        )

        #expect(audio.url == fileURL)
        #expect(audio.headers.isEmpty)
        #expect(audio.chapterStartSeconds == 10)
        #expect(audio.chapterDurationSeconds == 20)
    }

    @Test("missing local audio asks for reimport")
    func missingLocalAudioThrowsReimportError() async throws {
        var book = ReadingBook(title: "Missing Audio", source: "local_audio", contentFilename: "missing.mp3")
        book.contentPipelineKind = .audio
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "Missing", url: "missing-\(UUID().uuidString).mp3")
        ]

        do {
            _ = try await LocalChapterAudioProvider().audio(
                for: book,
                chapterIndex: 0,
                store: BookStore(metadataFileURL: tempMetadataURL())
            )
            Issue.record("Expected missing local audio to throw")
        } catch let error as ChapterAudioProviderError {
            #expect(error.localizedDescription == localized("音訊檔案不在此裝置上，請重新匯入"))
        }
    }
}

@Suite("iCloud audio sync exclusion")
struct ICloudAudioSyncExclusionTests {

    @Test("audio content is excluded but cover remains syncable")
    func audioContentExcluded() {
        var audio = ReadingBook(title: "Audio", source: "local_audio", contentFilename: "local_audio/book")
        audio.contentPipelineKind = .audio
        audio.coverImagePath = "audio-cover.jpg"

        var text = ReadingBook(title: "Text", source: "local", contentFilename: "book.txt")
        text.coverImagePath = "text-cover.jpg"

        #expect(ICloudSyncManager.syncableContentFilename(for: audio) == nil)
        #expect(audio.coverImagePath == "audio-cover.jpg")
        #expect(ICloudSyncManager.syncableContentFilename(for: text) == "book.txt")
    }
}

@Suite("BookStore audiobook import")
@MainActor
struct BookStoreAudiobookImportTests {

    @Test("zip import creates numbered chapter refs and delete removes audio directory")
    func zipImportCreatesChapterRefsAndDeletesDirectory() async throws {
        let archiveURL = try await makeAudioArchive(entries: [
            "Book/02 Outro.m4a": Data("two".utf8),
            "Book/01 Intro.mp3": Data("one".utf8),
            "cover.jpg": Data("cover".utf8)
        ])
        let store = BookStore(metadataFileURL: tempMetadataURL())

        let book = try await store.importLocalAudiobook(
            url: archiveURL,
            title: "Imported Audio",
            author: "Narrator"
        )

        #expect(book.title == "Imported Audio")
        #expect(book.author == "Narrator")
        #expect(book.source == "local_audio")
        #expect(book.resolvedPipelineKind == .audio)
        #expect(book.onlineChapters?.map(\.title) == ["01 Intro", "02 Outro"])
        #expect(book.onlineChapters?.map { ($0.url as NSString).lastPathComponent } == ["000.mp3", "001.m4a"])

        let directory = documentsURL(for: book.contentFilename)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("000.mp3").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("001.m4a").path))

        store.delete(bookId: book.id)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

private func makeTimedMetadataGroup(title: String, start: Double, duration: Double) -> AVTimedMetadataGroup {
    let item = AVMutableMetadataItem()
    item.keySpace = .common
    item.key = AVMetadataKey.commonKeyTitle as NSString
    item.value = title as NSString
    return AVTimedMetadataGroup(
        items: [item],
        timeRange: CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    )
}

private func makeAudioArchive(entries: [String: Data]) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let archiveURL = root.appendingPathComponent("sample.zip")
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

private func documentsURL(for relativePath: String) -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(relativePath)
}

private func tempMetadataURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("books-\(UUID().uuidString).json")
}
