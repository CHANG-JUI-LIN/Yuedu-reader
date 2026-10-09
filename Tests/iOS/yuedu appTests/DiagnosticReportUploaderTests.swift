import Foundation
import Testing
@testable import yuedu_app

/// What the "send to developer" button writes: a report number the Firestore rule accepts,
/// and a payload that fits one document by keeping the newest entries.
@Suite("Diagnostic report upload payload")
struct DiagnosticReportUploaderTests {
    private func entries(_ count: Int, bytesEach: Int) -> [DiagnosticEntry] {
        // Newest first, as `DiagnosticLog.snapshot()` returns them. Random text so it does
        // not compress away.
        (0..<count).map { index in
            let filler = (0..<bytesEach).map { _ in String(UnicodeScalar(UInt8.random(in: 33...126))) }.joined()
            return DiagnosticEntry(
                sequence: UInt64(count - index), timestamp: Date(), severity: .info,
                category: .general, message: "entry \(count - index) \(filler)", detail: nil
            )
        }
    }

    private func bundle(_ entries: [DiagnosticEntry]) -> DiagnosticReportBundle {
        DiagnosticReportBundle(
            filename: "t.txt", entries: entries, session: DiagnosticLog.shared.currentSession, uncleanSessions: []
        )
    }

    @Test("report numbers use the alphabet the Firestore rule allows")
    func reportIDFormat() throws {
        let pattern = try Regex("^YD-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}$")
        for _ in 0..<200 {
            #expect(DiagnosticReportUploader.makeReportID().wholeMatch(of: pattern) != nil)
        }
    }

    @Test("a small log is sent whole and decompresses to the rendered text")
    func smallLogSentWhole() throws {
        let small = bundle(entries(20, bytesEach: 50))
        let prepared = try DiagnosticReportUploader.preparePayload(small, reportID: "YD-TEST-TEST")
        #expect(prepared.keptEntries == 20)
        let text = String(decoding: try (prepared.compressed as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)
        #expect(text.hasPrefix("report YD-TEST-TEST · entries 20 of 20"))
        #expect(text.contains("entry 20 "))
    }

    @Test("an oversized log keeps its newest entries and fits one document")
    func oversizedLogKeepsNewest() throws {
        let large = bundle(entries(3_000, bytesEach: 600))
        let prepared = try DiagnosticReportUploader.preparePayload(large, reportID: "YD-TEST-TEST")
        #expect(prepared.compressed.count <= DiagnosticReportUploader.payloadLimit)
        #expect(prepared.keptEntries < 3_000)
        let text = String(decoding: try (prepared.compressed as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)
        #expect(text.contains("entry 3000 "))
        #expect(!text.contains("entry 1 "))
    }
}
