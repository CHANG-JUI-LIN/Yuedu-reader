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
        await resolver.registerFontFaces(requests: [
            ResolvedFontRequest(family: "Missing Font", weight: 400, italic: false)
        ])

        #expect(resourceProvider.responseCount == 0)
    }

    @Test("font resources load lazily for referenced families only")
    @MainActor
    func fontResourcesLoadLazilyForReferencedFamiliesOnly() async {
        let resourceProvider = ResourceAvailabilityProvider(availability: true)
        let registrationService = RecordingFontRegistrationService()
        let resolver = EPUBStyleResolver(
            resourceProvider: resourceProvider,
            fontRegistrationService: registrationService
        )

        _ = await resolver.processStylesheet(
            """
            @font-face {
                font-family: "Used Font";
                font-weight: 400;
                src: url("../Fonts/used-regular.ttf");
            }
            @font-face {
                font-family: "Used Font";
                font-weight: 700;
                src: url("../Fonts/used-bold.ttf");
            }
            @font-face {
                font-family: "Unused Font";
                src: url("../Fonts/unused.ttf");
            }
            .used { font-family: "Used Font"; }
            """,
            cssHref: "OPS/Styles/fonts.css",
            chapterHref: "OPS/Text/chapter.xhtml"
        )

        #expect(resourceProvider.responseCount == 0)
        #expect(registrationService.registeredAliases.isEmpty)

        let usedRequest = ResolvedFontRequest(
            family: "Used Font",
            weight: 700,
            italic: false
        )
        await resolver.registerFontFaces(requests: [usedRequest])

        #expect(resourceProvider.responseCount == 1)
        #expect(resourceProvider.requestedURLs[0].path.hasSuffix("/Fonts/used-bold.ttf"))
        #expect(registrationService.registeredAliases.count == 1)
        #expect(registrationService.registeredAliases[0].hasPrefix("asset-"))
        #expect(resolver.registeredFontFaces["used font"] != nil)
        #expect(resolver.registeredFontFaces["unused font"] == nil)

        await resolver.registerFontFaces(requests: [usedRequest])
        #expect(resourceProvider.responseCount == 1)
        #expect(registrationService.registeredAliases.count == 1)
    }
}

private final class ResourceAvailabilityProvider: BookResourceProvider {
    let customScheme = "reader-test"
    let chapters: [BookResourceChapterDescriptor] = []
    let availability: Bool?
    private(set) var responseCount = 0
    private(set) var requestedURLs: [URL] = []

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
        requestedURLs.append(requestURL)
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

private final class RecordingFontRegistrationService: FontRegistrationServicing {
    private(set) var registeredAliases: [String] = []

    func registerFont(
        data: Data,
        alias: String,
        existingTempURL: URL?
    ) -> FontRegistrationResult? {
        registeredAliases.append(alias)
        return FontRegistrationResult(
            familyName: "Recorded Family",
            postScriptName: "RecordedPostScript",
            tempFileURL: nil
        )
    }

    func cleanupTemporaryFile(at url: URL) {}
}
