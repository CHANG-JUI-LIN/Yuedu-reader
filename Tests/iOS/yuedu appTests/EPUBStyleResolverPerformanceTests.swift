import Foundation
import Testing
@testable import yuedu_app

@Suite("EPUB style resolver performance")
struct EPUBStyleResolverPerformanceTests {
    @Test("raw archive bytes are only required for obfuscated resources")
    func rawArchiveBytesAreOnlyRequiredForObfuscatedResources() {
        #expect(PublicationSession.requiresRawArchiveData(encryptionAlgorithm: nil) == false)
        #expect(
            PublicationSession.requiresRawArchiveData(
                encryptionAlgorithm: "http://www.idpf.org/2008/embedding"
            )
        )
        #expect(
            PublicationSession.requiresRawArchiveData(
                encryptionAlgorithm: "http://ns.adobe.com/pdf/enc#RC"
            )
        )
    }

    @Test("known missing font resources are not read")
    @MainActor
    func knownMissingFontResourcesAreNotRead() async {
        let resourceProvider = ResourceAvailabilityProvider(availability: false)
        let resolver = EPUBStyleResolver(
            resourceProvider: resourceProvider,
            fontRegistrationService: RejectingFontRegistrationService()
        )

        _ = await resolver.processStylesheet(
            """
            @font-face {
                font-family: "Missing Font";
                src: url("../Fonts/missing.ttf");
            }
            body { font-family: "Missing Font"; }
            """,
            cssHref: "OPS/Styles/fonts.css",
            chapterHref: "OPS/Text/chapter.xhtml"
        )

        #expect(resourceProvider.responseCount == 0)
    }
}

private final class ResourceAvailabilityProvider: BookResourceProvider {
    let customScheme = "reader-test"
    let chapters: [BookResourceChapterDescriptor] = []
    let availability: Bool?
    private(set) var responseCount = 0

    init(availability: Bool?) {
        self.availability = availability
    }

    func cssResourceHrefs() -> [String] { [] }

    func resourceURL(for href: String) -> URL {
        URL(string: "\(customScheme)://book/\(href)")!
    }

    func chapterDataSize(at index: Int) async throws -> Int { 0 }
    func chapterIndex(for href: String) -> Int? { nil }
    func chapterHTML(at index: Int) async throws -> String { "" }

    func resourceAvailability(for requestURL: URL) -> Bool? {
        availability
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        responseCount += 1
        return PublicationResourceResponse(
            data: Data(),
            mimeType: "font/ttf",
            textEncodingName: nil
        )
    }
}

private struct RejectingFontRegistrationService: FontRegistrationServicing {
    func registerFont(
        data: Data,
        alias: String,
        existingTempURL: URL?
    ) -> FontRegistrationResult? {
        nil
    }

    func cleanupTemporaryFile(at url: URL) {}
}
