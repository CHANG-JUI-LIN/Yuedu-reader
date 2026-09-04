import CLexbor
import Testing

@Suite(.serialized)
struct CLexborSmokeTests {
    @Test func reportsPinnedVersion() {
        #expect(String(cString: ylx_lexbor_version()) == "3.0.0")
    }

    @Test func parsesAndDestroysValidXHTML() {
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Hello</p></body></html>"
        var status = YLX_STATUS_OK
        let document = withDocumentBytes(html) { bytes in
            ylx_document_create(bytes.baseAddress, bytes.count, &status)
        }

        #expect(status == YLX_STATUS_OK)
        #expect(document != nil)
        #expect(ylx_document_element_count(document) >= 3)
        ylx_document_destroy(document)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func recoversMalformedHTML() {
        let html = "<html><body><section><p>Recovered"
        var status = YLX_STATUS_OK
        let document = withDocumentBytes(html) { bytes in
            ylx_document_create(bytes.baseAddress, bytes.count, &status)
        }

        #expect(status == YLX_STATUS_OK)
        #expect(document != nil)
        #expect(ylx_document_element_count(document) >= 4)
        ylx_document_destroy(document)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func rejectsEmptyInputWithoutLeaking() {
        var status = YLX_STATUS_OK
        let document = ylx_document_create(nil, 0, &status)

        #expect(document == nil)
        #expect(status == YLX_STATUS_INVALID_ARGUMENT)
        #expect(ylx_debug_live_document_count() == 0)
    }

    @Test func sequentialCreateDestroyLeavesNoLiveDocuments() {
        #expect(ylx_debug_live_document_count() == 0)

        for index in 0..<6 {
            let html = "<html><body><p>Cycle \(index)</p></body></html>"
            var status = YLX_STATUS_OK
            let document = withDocumentBytes(html) { bytes in
                ylx_document_create(bytes.baseAddress, bytes.count, &status)
            }

            #expect(status == YLX_STATUS_OK)
            #expect(document != nil)
            #expect(ylx_debug_live_document_count() == 1)
            ylx_document_destroy(document)
            #expect(ylx_debug_live_document_count() == 0)
        }
    }
}

private func withDocumentBytes<T>(
    _ html: String,
    _ body: (UnsafeBufferPointer<UInt8>) -> T
) -> T {
    Array(html.utf8).withUnsafeBufferPointer(body)
}
