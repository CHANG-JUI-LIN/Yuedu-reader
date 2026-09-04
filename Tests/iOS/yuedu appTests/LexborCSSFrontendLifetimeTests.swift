import CLexbor
import Testing
@testable import yuedu_app

@Suite(.serialized)
struct LexborCSSFrontendLifetimeTests {
    @Test func ownsValidDocumentUntilScopeExit() throws {
        #expect(ylx_debug_live_document_count() == 0)

        do {
            let owner = try LexborDocumentOwner(
                html: "<html><body><main><p>Hello</p></main></body></html>"
            )
            #expect(ylx_debug_live_document_count() == 1)
            #expect(owner.withDocument(ylx_document_element_count) >= 4)
        }

        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func acceptsHTMLParserRecovery() throws {
        do {
            let owner = try LexborDocumentOwner(html: "<html><body><section><p>Recovered")
            #expect(owner.withDocument(ylx_document_element_count) >= 4)
        }

        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func rejectsEmptyInputWithoutLeaking() {
        #expect(throws: LexborDocumentOwner.Error.invalidInput) {
            _ = try LexborDocumentOwner(html: "")
        }
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func sixSequentialOwnersDestroyExactlyOnce() throws {
        #expect(ylx_debug_live_document_count() == 0)

        for index in 0..<6 {
            do {
                let owner = try LexborDocumentOwner(
                    html: "<html><body><p>Cycle \(index)</p></body></html>"
                )
                #expect(ylx_debug_live_document_count() == 1)
                #expect(owner.withDocument(ylx_document_element_count) >= 3)
            }
            #expect(ylx_debug_live_document_count() == 0)
        }
    }
}
