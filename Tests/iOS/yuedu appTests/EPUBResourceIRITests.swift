import Foundation
import Testing
@testable import yuedu_app

struct EPUBResourceIRITests {
    @Test
    func encodedSpineHrefReadsUnicodeArchiveEntry() async throws {
        let sample = EPUBTestFixtures.nonASCIIResourceIRI()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let chapter = try #require(session.chapters.first)

        #expect(chapter.href.contains("%E4%B8%80.xhtml"))
        let html = try await session.chapterHTML(at: chapter.index)
        #expect(html.contains("山路を登りながら"))

        let request = session.resourceURL(for: "OPS/xhtml/一.xhtml")
        let response = try await session.response(for: request)
        #expect(String(data: response.data, encoding: .utf8)?.contains("山路を登りながら") == true)
    }
}
