import Foundation
import CoreGraphics
import Testing
@testable import yuedu_app

@Suite("TXTInitialPreviewPlanner")
struct TXTInitialPreviewPlannerTests {
    @Test("preview stays bounded for UTF-8")
    func previewStaysBoundedForUTF8() {
        #expect(
            TXTInitialPreviewPlanner.byteCount(
                fileByteCount: 2_000_000,
                encoding: .utf8
            ) == 64 * 1024
        )
    }

    @Test("preview keeps UTF-16 code units aligned")
    func previewKeepsUTF16CodeUnitsAligned() {
        #expect(
            TXTInitialPreviewPlanner.byteCount(
                fileByteCount: 65_535,
                encoding: .utf16LittleEndian
            ) == 65_534
        )
        #expect(
            TXTInitialPreviewPlanner.byteCount(
                fileByteCount: 65_535,
                encoding: .utf16BigEndian
            ) == 65_534
        )
    }

    @Test("small files are not padded beyond their end")
    func smallFilesAreNotPaddedBeyondTheirEnd() {
        #expect(
            TXTInitialPreviewPlanner.byteCount(
                fileByteCount: 123,
                encoding: .utf8
            ) == 123
        )
    }
}
