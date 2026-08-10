import Testing
@testable import yuedu_app

@Suite("Legado Rhino Normalizer Scanner", .serialized)
struct LegadoRhinoNormalizerScannerTests {
    @Test("non-BMP identifiers do not crash the UTF-16 scanner")
    func nonBMPIdentifierDoesNotCrash() {
        let input = "function read(𠮷) { let 𠮷 = 1; return 𠮷; }"

        let normalized = LegadoRhinoNormalizer.normalize(input)

        #expect(normalized.source == "function read(𠮷) { var 𠮷 = 1; return 𠮷; }")
        #expect(normalized.edits.count == 1)
    }
}
