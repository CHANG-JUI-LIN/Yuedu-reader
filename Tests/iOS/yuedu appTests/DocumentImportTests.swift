import AVFoundation
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import yuedu_app

@Suite("Document import and reader handoff", .serialized)
@MainActor
struct DocumentImportTests {
    @Test("Every readable extension resolves to a registered Open In document type")
    func documentRegistration() throws {
        let declarations = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let identifiers = declarations.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let types = identifiers.compactMap { UTType($0) }
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool == true)
        for ext in LocalBookImportService.supportedExtensions {
            let type = try #require(UTType(filenameExtension: ext), "Missing type: \(ext)")
            #expect(!type.isDynamic, "Undeclared extension: \(ext)")
            #expect(types.contains { type.conforms(to: $0) }, "Open In missing: \(ext) / \(type.identifier)")
            #expect(LocalBookImportService.supportedContentTypes.contains(type))
        }
    }

    @Test("All local formats use the document import path", arguments: [
        "epub", "pdf", "txt", "md", "markdown", "json", "cbz", "zip",
        "mp3", "m4a", "m4b", "aac", "flac", "wav"
    ])
    func allFormatRouting(ext: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("原始書名.\(ext)")
        let bytes = Data((ext == "json" ? "{\"title\":\"Book\",\"chapters\":[\"Body\"]}" : "第一章\n內文").utf8)
        try bytes.write(to: file)
        var received: [URL] = []
        let importer = SharedImportQueueDrainer(defaults: nil, importBookFile: { url in
            received.append(url)
            let receivedBytes = try Data(contentsOf: url)
            #expect(receivedBytes == bytes)
            return 1
        })
        let result = await importer.openFile(file)
        #expect(result.importedBookCount == 1)
        #expect(result.failureCount == 0)
        #expect(received == [file])
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Real documents are saved before requesting their format reader", arguments: ["txt", "md", "markdown", "json", "epub", "pdf", "cbz", "zip", "wav", "audiozip"])
    func realImportAndOpen(ext: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("分享書籍-\(UUID()).\(ext == "audiozip" ? "zip" : ext)")
        switch ext {
        case "epub":
            let epub = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
            defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
            try FileManager.default.copyItem(at: epub, to: file)
        case "pdf":
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in
                context.beginPage()
                ("Reading body" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            }
            try data.write(to: file)
        case "cbz", "zip", "audiozip":
            let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).pngData { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            var entries = ["001.png": image]
            if ext == "audiozip" {
                let wav = root.appendingPathComponent("chapter.wav")
                try writeWAV(to: wav)
                entries = ["chapter.wav": try Data(contentsOf: wav)]
            }
            let archive = try await EPUBTestFixtures.makeArchive(entries: entries)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            try FileManager.default.copyItem(at: archive, to: file)
        case "wav":
            try writeWAV(to: file)
        case "json":
            try Data(#"{"title":"JSON Book","chapters":[{"title":"第一章","content":"測試正文"}]}"#.utf8).write(to: file)
        default:
            try Data("# 第一章\n分享匯入後直接閱讀 😀".utf8).write(to: file)
        }
        let original = try Data(contentsOf: file)
        let metadata = root.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        defer { for book in store.books { store.delete(bookId: book.id) } }
        let importer = SharedImportQueueDrainer(defaults: nil)
        importer.bind(bookStore: store)
        let result = await importer.openFile(file)
        #expect(result.failureCount == 0)
        let request = try #require(importer.readerRequest)
        let book = try #require(store.readingBook(id: request.bookID))
        #expect(book.isInBookshelf)
        if ext == "wav" || ext == "audiozip" { #expect(book.resolvedPipelineKind == .audio) }
        if ext == "cbz" || ext == "zip" { #expect(book.resolvedPipelineKind == .manga) }
        if ext == "pdf" { #expect(book.resolvedPipelineKind == .fixedPage) }
        #expect(BookStore(metadataFileURL: metadata).readingBook(id: book.id) != nil)
        #expect(importer.lastOutcome == nil)
        #expect(importer.activeImportCount == 0)
        #expect(try Data(contentsOf: file) == original)
        importer.didPresentReader(requestID: UUID())
        #expect(importer.readerRequest == request)
        importer.didPresentReader(requestID: request.id)
        #expect(importer.readerRequest == nil)
    }

    @Test("Failed documents report failure and never request a reader")
    func failedDocument() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.epub")
        try Data("not an EPUB".utf8).write(to: file)
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let importer = SharedImportQueueDrainer(defaults: nil)
        importer.bind(bookStore: store)
        let result = await importer.openFile(file)
        #expect(result.failureCount == 1)
        #expect(importer.readerRequest == nil)
        #expect(importer.lastOutcome?.failureCount == 1)
        #expect(store.books.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Open In copies leave the inbox, but not one still being imported")
    func openInCopiesRemoved() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for name in ["earlier.epub", "earlier-1.epub", "rules.json"] {
            try Data("left behind".utf8).write(to: inbox.appendingPathComponent(name))
        }
        try Data("第一章\n內文".utf8).write(to: inbox.appendingPathComponent("新書.txt"))
        // Delivered under another spelling of the inbox, as a device's /private/var and /var.
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inbox)
        var removeOpenInCopies: () -> Void = {}
        var keptWhileImporting = false
        let importer = SharedImportQueueDrainer(defaults: nil, openInInboxURL: inbox, importBookFile: { url in
            removeOpenInCopies()
            keptWhileImporting = FileManager.default.fileExists(atPath: url.path)
            return 1
        })
        removeOpenInCopies = { importer.removeOpenInCopies() }
        let result = await importer.openFile(alias.appendingPathComponent("新書.txt"))
        #expect(result.importedBookCount == 1)
        #expect(keptWhileImporting)
        // The leftovers went with the sweep, the delivered copy with its own import.
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
    }

    @Test("An Open In copy goes once its import is over, whatever the outcome", arguments: [true, false])
    func openInCopyRemovedAfterImport(succeeds: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // Another delivery whose import may not have started: only the sweep may take it.
        try Data("第一章\n下一本".utf8).write(to: inbox.appendingPathComponent("下一本.txt"))
        let delivered = inbox.appendingPathComponent("新書.txt")
        try Data("第一章\n內文".utf8).write(to: delivered)
        let importer = SharedImportQueueDrainer(defaults: nil, openInInboxURL: inbox, importBookFile: { _ in
            if succeeds { return 1 }
            throw CocoaError(.fileReadCorruptFile)
        })
        let result = await importer.openFile(delivered)
        #expect(result.failureCount == (succeeds ? 0 : 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path) == ["下一本.txt"])
    }

    @Test("An app nothing was ever opened into has no inbox, and that is not an error")
    func openInInboxNeverMade() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        let importer = SharedImportQueueDrainer(defaults: nil, openInInboxURL: root.appendingPathComponent("Inbox"))
        importer.removeOpenInCopies()
        let logged = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains("Open In") }
        #expect(logged.isEmpty)
    }

    @Test("JSON source documents keep their existing non-reader route")
    func sourceDocument() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.json")
        try Data(#"[{"bookSourceName":"Source","bookSourceUrl":"https://example.com"}]"#.utf8).write(to: file)
        var calls = 0
        let importer = SharedImportQueueDrainer(defaults: nil, importData: { _ in calls += 1; return 1 })
        let result = await importer.openFile(file)
        #expect(calls == 1)
        #expect(result.importedBookSourceCount == 1)
        #expect(importer.readerRequest == nil)
        #expect(importer.lastOutcome == result)
    }

    @Test("Plain text disguised as JSON is staged with its classified extension")
    func normalizedFilename() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("小說.json")
        try Data("第一章\n這是文字書籍".utf8).write(to: file)
        var receivedName: String?
        let importer = SharedImportQueueDrainer(defaults: nil, importBookFile: { url in
            receivedName = url.lastPathComponent
            return 1
        })
        let result = await importer.openFile(file)
        #expect(result.failureCount == 0)
        #expect(receivedName == "小說.txt")
    }

    @Test("The link extension excludes local files and advertises its separate purpose")
    func linkExtensionActivation() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let extensionURL = try #require(FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("ShareExtension") })
        let bundle = try #require(Bundle(url: extensionURL))
        let configuration = try #require(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let attributes = try #require(configuration["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)
        func accepts(_ identifiers: [String]) -> Bool {
            predicate.evaluate(with: ["extensionItems": [["attachments": [["registeredTypeIdentifiers": identifiers]]]]])
        }
        #expect(accepts(["public.url"]))
        #expect(!accepts(["public.file-url", "public.url"]))
        for type in LocalBookImportService.supportedContentTypes {
            #expect(!accepts([type.identifier]), "File leaked to queue extension: \(type.identifier)")
        }
    }

    private func writeWAV(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 800)
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try audioFile.write(from: buffer)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
