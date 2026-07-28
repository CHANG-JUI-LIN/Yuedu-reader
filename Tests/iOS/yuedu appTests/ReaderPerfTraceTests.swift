import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader performance tracing")
struct ReaderPerfTraceTests {

    @Test("pipeline stage names stay stable for Instruments and XCTOSSignpostMetric")
    func stageNamesStayStable() {
        let expectedNames: Set<String> = [
            "chapter.load",
            "html.parse",
            "css.collect",
            "css.parse",
            "css.match",
            "ast.build",
            "ir.convert",
            "attributed.render",
            "resource.image.load",
            "resource.image.decode",
            "layout.fingerprint",
            "layout.vertical.prepare",
            "layout.framesetter.create",
            "layout.pageRanges",
            "layout.displayList",
            "layout.firstPage.publish",
            "render.page",
            "render.chunk",
            "render.tile",
            "cache.document",
            "cache.layout",
            "cache.raster",
        ]

        #expect(Set(ReaderPerfStage.allCases.map(\.rawValue)) == expectedNames)
        #expect(
            ReaderPerfStage.allCases.allSatisfy {
                String(describing: $0.signpostName) == $0.rawValue
            }
        )
    }

    @Test("metadata uses a deterministic public schema without content text")
    func metadataUsesDeterministicSchema() {
        let metadata = ReaderPerfMetadata(
            resourceID: "fixture-plain-10k",
            spineIndex: 3,
            characterCount: 10_240,
            elementCount: 512,
            ruleCount: 300,
            pageCount: 12,
            chunkCount: 4,
            writingMode: "horizontal",
            cacheResult: "miss",
            executor: "background",
            generation: 7
        )

        #expect(
            metadata.logDescription
                == "resource=fixture-plain-10k spine=3 chars=10240 elements=512 rules=300 pages=12 chunks=4 writing=horizontal cache=miss executor=background generation=7"
        )
    }

    @Test("metadata omits unavailable fields instead of inventing sentinel values")
    func metadataOmitsUnavailableFields() {
        let metadata = ReaderPerfMetadata(
            spineIndex: 0,
            characterCount: 0,
            writingMode: "verticalRTL"
        )

        #expect(metadata.logDescription == "spine=0 chars=0 writing=verticalRTL")
    }
}
