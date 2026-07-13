import Testing
@testable import yuedu_app

@Suite("Apple Books reader controls", .serialized)
struct AppleBooksReaderControlsTests {
    @Test("tapping the same panel twice toggles it closed")
    func repeatedTapClosesPanel() {
        let opened = AppleBooksReaderControlPanel.panel(
            afterTapping: .menu,
            current: nil
        )
        let closed = AppleBooksReaderControlPanel.panel(
            afterTapping: .menu,
            current: opened
        )

        #expect(opened == .menu)
        #expect(closed == nil)
    }

    @Test("dragging the progress capsule maps and clamps reading progress")
    func progressCapsuleMapsDragLocation() {
        #expect(AppleBooksProgressScrubber.value(at: 50, width: 200) == 0.25)
        #expect(AppleBooksProgressScrubber.value(at: -20, width: 200) == 0)
        #expect(AppleBooksProgressScrubber.value(at: 240, width: 200) == 1)
    }
}
