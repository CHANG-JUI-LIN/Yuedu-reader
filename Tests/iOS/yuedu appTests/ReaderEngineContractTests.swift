import Testing
@testable import yuedu_app

@MainActor
struct ReaderEngineContractTests {
    @Test("paged engines expose explicit capability contracts")
    func pagedEnginesExposeExplicitCapabilityContracts() {
        assertPagedReaderEngine(CoreTextPageEngine.self)
        assertPagedReaderEngine(TXTPageEngine.self)
        assertPagedReaderEngine(FixedLayoutPageEngine.self)
        assertPagedReaderEngine(MixedLayoutPageEngine.self)
    }

    @Test("scroll engine exposes the scroll capability contract")
    func scrollEngineExposesScrollCapabilityContract() {
        assertScrollReaderEngine(CoreTextScrollEngine.self)
    }

    private func assertPagedReaderEngine<T: PagedReaderEngine>(_ type: T.Type) {
        _ = type
    }

    private func assertScrollReaderEngine<T: ScrollReaderEngine>(_ type: T.Type) {
        _ = type
    }
}
