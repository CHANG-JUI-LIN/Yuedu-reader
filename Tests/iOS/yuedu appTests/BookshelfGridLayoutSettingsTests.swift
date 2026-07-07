import Testing
@testable import yuedu_app

@Suite("Bookshelf Grid Layout Settings")
struct BookshelfGridLayoutSettingsTests {
    @Test("grid column options start with 2, 3, and 4")
    func gridColumnOptionsAreTwoThreeFour() {
        #expect(GlobalSettings.bookshelfGridColumnCountOptions == [2, 3, 4])
        #expect(GlobalSettings.defaultBookshelfGridColumnCount == 3)
    }

    @Test("grid column count is clamped to supported options")
    func gridColumnCountIsClampedToSupportedOptions() {
        #expect(GlobalSettings.sanitizedBookshelfGridColumnCount(1) == 2)
        #expect(GlobalSettings.sanitizedBookshelfGridColumnCount(2) == 2)
        #expect(GlobalSettings.sanitizedBookshelfGridColumnCount(3) == 3)
        #expect(GlobalSettings.sanitizedBookshelfGridColumnCount(4) == 4)
        #expect(GlobalSettings.sanitizedBookshelfGridColumnCount(5) == 4)
    }
}
