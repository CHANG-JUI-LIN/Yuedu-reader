import Foundation
import Testing
@testable import yuedu_app

/// Why an import failed reaches the person who tried it (MOBI plan, step 5; maintainer,
/// 2026-11-02: every format, not only Kindle files). The Files importer always printed
/// `error.localizedDescription`; Open In and the share sheet printed only a count. Every
/// error those routes can meet now says something a reader can use, and what it leaves out
/// goes to the log.
@Suite("Import failure reasons", .serialized)
@MainActor
struct ImportFailureReasonTests {
    private static let mobiFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MOBI")

    /// What a Swift error with no description of its own reads as, in either apostrophe.
    private static func isGeneric(_ text: String) -> Bool {
        text.contains("couldn't be completed") || text.contains("couldn’t be completed")
            || text.contains("yuedu_app.")
    }

    @Test("a refused Kindle file says why, and the log keeps the case", arguments: [
        (MOBIError.encrypted(2), "這個 Kindle 檔案有 DRM 保護，無法開啟"),
        (.unknownCompression(17480), "這個 Kindle 檔案的壓縮方式目前不支援"),
        (.notMOBI, "無法讀取這個 Kindle 檔案"),
        (.unsupportedEncoding(1200), "無法讀取這個 Kindle 檔案"),
        (.missingMOBIHeader(record: 3), "無法讀取這個 Kindle 檔案"),
        (.truncatedRecord(nil), "無法讀取這個 Kindle 檔案"),
        (.corruptText(record: 4), "無法讀取這個 Kindle 檔案"),
        (.corruptIndex(record: 7), "無法讀取這個 Kindle 檔案"),
    ])
    func kindleRefusals(error: MOBIError, key: String) {
        #expect(error.localizedDescription == localized(key))
        #expect(error.diagnosticDescription == String(describing: error))
    }

    @Test("the log line carries the cause beside the sentence")
    func logCarriesCause() {
        let marker = "ImportFailureReasonTests \(UUID().uuidString)"
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        AppLogger.error(marker, error: MOBIError.corruptIndex(record: 7))
        let line = DiagnosticLog.shared.snapshot().first { !before.contains($0.id) && $0.message.contains(marker) }
        #expect(line?.message.contains("error=\(localized("無法讀取這個 Kindle 檔案"))") == true)
        #expect(line?.message.contains("cause=corruptIndex(record: 7)") == true)
    }

    /// Bad files of every kind, through the real Open In route: each failure names the file
    /// and gives a reason, none of them the generic one.
    @Test("Open In reports a reason for every kind of bad file")
    func openInReportsReasons() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFailureReasonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        defer {
            for book in store.books { store.delete(bookId: book.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let drainer = SharedImportQueueDrainer(defaults: nil, payloadDirectoryURL: nil)
        drainer.bind(bookStore: store)

        var encrypted = try Data(contentsOf: Self.mobiFixtures.appendingPathComponent("features.azw3"))
        let record0 = encrypted[78..<82].reduce(0) { $0 << 8 | Int($1) }
        encrypted[record0 + 13] = 2
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        let files: [(name: String, data: Data, reason: String?)] = [
            ("protected.azw3", encrypted, localized("這個 Kindle 檔案有 DRM 保護，無法開啟")),
            ("broken.mobi", garbage, localized("無法讀取這個 Kindle 檔案")),
            ("broken.epub", garbage, localized("無法讀取這本 EPUB")),
            ("broken.pdf", garbage, nil),
            ("broken.cbz", garbage, nil),
            ("unknown.xyz", garbage, localized("不支援這種檔案格式")),
            ("sources.yds", garbage, localized("無法讀取來源配置資料")),
            ("sources.mrs", garbage, String(format: localized("%@ 格式經過加密，無法直接匯入。請用原本的 App 匯出成 JSON 或 TXT。"), "MRS")),
        ]
        for file in files {
            let url = root.appendingPathComponent(file.name)
            try file.data.write(to: url)
            let outcome = await drainer.openFile(url)
            #expect(outcome.failureCount == 1, "\(file.name)")
            let failure = try #require(outcome.failures.first, "\(file.name)")
            #expect(failure.hasPrefix(file.name + ": "), "\(failure)")
            let reason = String(failure.dropFirst(file.name.count + 2))
            #expect(!reason.isEmpty && !Self.isGeneric(reason), "\(file.name): \(reason)")
            if let expected = file.reason { #expect(reason == expected, "\(file.name)") }
        }
        #expect(store.books.isEmpty)
    }

    @Test("the alert lists the first reasons under the count")
    func alertMessage() {
        var outcome = SharedImportQueueDrainer.Outcome(importedCount: 1, failureCount: 0)
        let reasons = (1...5).map { "\($0).epub: \(localized("無法讀取這本 EPUB"))" }
        for (index, _) in reasons.enumerated() {
            outcome.recordFailure(PublicationSessionError.parsingFailed("x"), item: "\(index + 1).epub")
        }
        let message = ContentView.sharedImportMessage(for: outcome)
        let lines = message.components(separatedBy: "\n")
        #expect(lines.first == String(format: localized("成功匯入 %1$d 個項目，%2$d 個失敗"), 1, 5))
        #expect(Array(lines.suffix(ContentView.sharedImportReasonLimit)) == Array(reasons.prefix(ContentView.sharedImportReasonLimit)))
        #expect(!message.contains(reasons[ContentView.sharedImportReasonLimit]))
        #expect(!message.contains("parsingFailed"))
    }
}
