import Testing
@testable import yuedu_app

struct EPUBCFIResolverTests {
    @Test func parserExtractsSpineAssertionDocumentIDsAndOffset() throws {
        let cfi = try #require(EPUBCFIResolver.parse(
            "epubcfi(/6/4[ct]!/4/2[d10e42]/12[d10e85]/6[d10e93]/1:1552[...])"
        ))

        #expect(cfi.spineStep == 4)
        #expect(cfi.spineIDAssertion == "ct")
        #expect(cfi.documentSteps.compactMap(\.idAssertion) == ["d10e42", "d10e85", "d10e93"])
        #expect(cfi.textOffset == 1552)
    }

    @Test func resolverMapsSpineAssertionToChapterIndex() throws {
        let cfi = try #require(EPUBCFIResolver.parse(
            "package.opf#epubcfi(/6/4[ct]!/4/2[d10e42]/12[d10e85]/6[d10e93]/1:1552[...])"
        ))
        let resolver = EPUBCFIResolver(
            spineReferences: [
                EPUBSpineReference(index: 0, idref: "cover", itemrefID: "cover", href: "OPS/cover.xhtml", linear: false),
                EPUBSpineReference(index: 1, idref: "ct", itemrefID: "ct", href: "OPS/georgia.xhtml", linear: true)
            ],
            manifestItemsByID: [
                "cover": EPUBManifestReference(id: "cover", href: "OPS/cover.xhtml", mediaType: "application/xhtml+xml"),
                "ct": EPUBManifestReference(id: "ct", href: "OPS/georgia.xhtml", mediaType: "application/xhtml+xml")
            ]
        )
        let chapters = [
            PublicationChapterDescriptor(index: 0, href: "OPS/cover.xhtml", title: "Cover", mediaType: "application/xhtml+xml"),
            PublicationChapterDescriptor(index: 1, href: "OPS/georgia.xhtml", title: "Georgia", mediaType: "application/xhtml+xml")
        ]

        #expect(resolver.resolveSpineIndex(cfi, chapters: chapters) == 1)
    }

    @Test func resolverUsesDeepestExistingAnchorAndClampsTextOffset() throws {
        let cfi = try #require(EPUBCFIResolver.parse(
            "epubcfi(/6/4[ct]!/4/2[d10e42]/12[d10e85]/6[d10e93]/1:1552[...])"
        ))
        let resolver = EPUBCFIResolver(spineReferences: [], manifestItemsByID: [:])

        let offset = resolver.resolveCharOffset(
            cfi,
            anchorOffsets: ["d10e42": 8, "d10e85": 24, "d10e93": 40],
            contentLength: 96
        )

        #expect(offset == 96)
    }

    @Test func publicationSessionExposesOPFReferencesForCFIResolution() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.georgia().entries)
        let session = try await PublicationSession.open(sourceURL: epubURL)

        #expect(
            session.opfSpineReferences.map(\.idref) == ["cover", "intro", "ct"],
            "idrefs: \(session.opfSpineReferences.map(\.idref))"
        )
        #expect(
            session.opfSpineReferences.map(\.href) == ["OPS/cover.xhtml", "OPS/intro.xhtml", "OPS/georgia.xhtml"],
            "hrefs: \(session.opfSpineReferences.map(\.href))"
        )
        #expect(
            session.opfManifestItemsByID["ct"]?.href == "OPS/georgia.xhtml",
            "manifest ct: \(String(describing: session.opfManifestItemsByID["ct"]))"
        )
        #expect(
            session.tocEntries.contains { $0.href.contains("epubcfi(") },
            "toc hrefs: \(session.tocEntries.map(\.href))"
        )
    }

    @Test func tocMapperUsesCFISpineAssertionInsteadOfPackageHrefFallback() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.georgia().entries)
        let session = try await PublicationSession.open(sourceURL: epubURL)

        let chapters = ReaderTOCChapterMapper.chapters(from: session.tocEntries, session: session)
        let cfiChapter = try #require(chapters.first { $0.title == "CFI" })

        #expect(cfiChapter.index == 1)
        #expect(cfiChapter.href == "OPS/georgia.xhtml")
        #expect(cfiChapter.fragment?.hasPrefix("epubcfi(") == true)
    }
}
