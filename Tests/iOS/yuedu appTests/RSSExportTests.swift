import Foundation
import Testing
import UniformTypeIdentifiers
@testable import yuedu_app

/// Exporting subscriptions must not lose a failure on the way out: an export that cannot be
/// built used to write an empty file, and a failed save was dropped by `{ _ in }`. The OPML
/// file must also carry the OPML type the importer reads, not generic XML.
@Suite("RSS export", .serialized)
struct RSSExportTests {
    private struct ExportFailure: LocalizedError {
        let token: String
        var errorDescription: String? { "export failure \(token)" }
    }

    private func logLines(since before: Set<UUID>, containing text: String) -> [DiagnosticEntry] {
        DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains(text) }
    }

    // MARK: - Legado JSON document

    @Test("a Legado JSON export that cannot be built throws instead of writing an empty file")
    func failedJSONExportThrows() {
        let token = UUID().uuidString
        let document = RSSJSONDocument(sources: [RSSSource(id: "s1", name: "One", url: "https://one.example/feed")]) { _ in
            throw ExportFailure(token: token)
        }

        #expect(throws: ExportFailure.self) { _ = try document.exportedData() }
    }

    @Test("a Legado JSON export that works writes the parser's bytes")
    func successfulJSONExportKeepsSources() throws {
        let sources = [RSSSource(id: "s1", name: "One", url: "https://one.example/feed")]

        let data = try RSSJSONDocument(sources: sources).exportedData()

        #expect(!data.isEmpty)
        #expect(try LegadoSourceJSONParser.parse(data: data).map(\.url) == ["https://one.example/feed"])
    }

    // MARK: - OPML document

    @Test("OPML is exported as org.opml.opml, the type the importer reads")
    func opmlExportUsesOPMLType() {
        let opml = UTType(importedAs: "org.opml.opml")

        #expect(RSSOPMLDocument.writableContentTypes == [opml])
        #expect(RSSOPMLDocument.exportContentType == opml)
        #expect(opml.conforms(to: .xml))
        #expect(opml.preferredFilenameExtension == "opml")
    }

    // MARK: - Completion handling

    @Test("a failed export is logged once with its reason and reported to the user")
    func failedExportIsLoggedAndReported() throws {
        let token = UUID().uuidString
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        let message = RSSExportReport.failureMessage(for: .failure(ExportFailure(token: token)), format: .opml)

        #expect(try #require(message).contains(token))
        #expect(try #require(message).contains("OPML"))
        let added = logLines(since: before, containing: token)
        #expect(added.count == 1)
        #expect(added.first?.severity == .error)
    }

    @Test("each format names itself in the report")
    func reportNamesTheFormat() throws {
        let failure = ExportFailure(token: UUID().uuidString)

        let json = try #require(RSSExportReport.failureMessage(for: .failure(failure), format: .legadoJSON))

        #expect(json.contains("JSON"))
        #expect(json.contains(failure.token))
    }

    @Test("dismissing the save panel is neither logged nor reported")
    func cancelIsSilent() {
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        let message = RSSExportReport.failureMessage(for: .failure(CocoaError(.userCancelled)), format: .opml)

        #expect(message == nil)
        #expect(logLines(since: before, containing: "RSS export failed").isEmpty)
    }

    @Test("a saved file is neither logged nor reported")
    func successIsSilent() {
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        let message = RSSExportReport.failureMessage(for: .success(URL(fileURLWithPath: "/tmp/yuedu-rss.opml")), format: .opml)

        #expect(message == nil)
        #expect(logLines(since: before, containing: "RSS export failed").isEmpty)
    }
}
