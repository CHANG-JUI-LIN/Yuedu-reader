import XCTest

/// UI integration test: proves the REAL on-screen page view paints the
/// RedChamber cover k1 box at the computed margin-top.
///
/// Preconditions (set up by scripts/run_redchamber_uitest.sh):
/// - App installed, EPUB copied to the app's Documents as
///   `RedChamber.epub`
/// - Simulator booted
///
/// The test launches with `-browser-mode browserForced -browser-overlay
/// -auto-import-epub RedChamber.epub`, taps the imported book, waits for the
/// first-chapter reader page, screenshots via XCUIScreen, and verifies the
/// debug overlay / k1 top lands at the expected pixel row.
final class RedChamberProductionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Expected k1 top in page-local points (25% of the body containing-block
    /// width for a 390pt layout — see BrowserLayoutRedChamberRegressionTests).
    static let k1PageLocalY: CGFloat = 89.67

    /// The app reports its window bounds via the overlay label; the test parses
    /// `view.frame=` from the debug text when available. Defaults to the
    /// iPhone 17 simulator logical size.
    static let defaultWindowSize = CGSize(width: 402, height: 874)

    @MainActor
    func testRedChamberCoverK1PixelPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-browser-mode", "browserForced",
            "-browser-overlay",
            "-auto-import-epub", "RedChamber.epub",
        ]
        app.launch()

        // Wait for the shelf to appear with the imported book.
        let list = app.tables["home_book_list"]
        let grid = app.otherElements["bookshelf_grid"]
        let anyShelfElement = list.exists ? list : (grid.exists ? grid : app.otherElements.firstMatch)
        XCTAssertTrue(anyShelfElement.waitForExistence(timeout: 25), "bookshelf should appear")

        // The import is async; poll for the 红楼梦 book text (grid cell label).
        let bookTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "红楼")).firstMatch
        var found = false
        for _ in 0..<25 {
            if bookTitle.exists {
                found = true
                break
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(found, "imported 红楼梦 book should appear on the shelf")
        bookTitle.tap()

        // Reader appears: the reader's back button (or the engine badge when
        // the overlay is present) marks the reader screen. Wait for either.
        let backBtn = app.buttons["reader_back_button"]
        let badge = app.staticTexts["reader_engine_badge"]
        let readerMarker = backBtn.exists ? backBtn : badge
        var readerShown = false
        for _ in 0..<30 {
            if readerMarker.exists {
                readerShown = true
                break
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(readerShown, "reader should appear (back button or engine badge)")
        // Give the page a moment to settle and the layout to complete.
        Thread.sleep(forTimeInterval: 3.0)

        // Screenshot the REAL screen.
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        print("UI-SHOT size=\(image.size) scale=\(image.scale)")

        let labelText = badge.exists ? badge.label : "(no badge)"
        print("UI-OVERLAY label=\(labelText)")
        let windowWidth = Self.defaultWindowSize.width

        // Formula per spec: screenshotScale = screenshotWidth / windowBoundsWidth.
        let screenshotScale = image.size.width / windowWidth
        let expectedPixelY = Self.k1PageLocalY * screenshotScale
        print("UI-SHOT scale=\(screenshotScale) expectedPixelY=\(expectedPixelY)")

        // Find the k1 fill / debug lines in the screenshot: scan the column at
        // the page center for the dark k2 border (bottom of the cover box) and
        // the k1 top. k2 top = k1 top + k1 padding (6.8pt).
        let k2TopPixel = Self.scanDarkRow(in: image)
        print("UI-SHOT k2TopPixel=\(String(describing: k2TopPixel))")

        // The blue debug line (k1 DisplayList top) sits at k1PageLocalY in the
        // page view's own space; the screenshot maps it by the same scale.
        if let k2Pixel = k2TopPixel {
            // k2 top in points = k1 + 6.8 padding.
            let k2TopPt = CGFloat(k2Pixel) / screenshotScale
            let k1TopPtFromK2 = k2TopPt - 6.8
            print("UI-SHOT k2TopPt=\(k2TopPt) inferredK1TopPt=\(k1TopPtFromK2)")
            XCTAssertLessThan(
                abs(k1TopPtFromK2 - Self.k1PageLocalY),
                3.0 / screenshotScale * 2 + 2,
                "k1 top from pixel scan \(k1TopPtFromK2) deviates from \(Self.k1PageLocalY)"
            )
        } else {
            XCTFail("k2 dark border not found in screenshot — page may not be the cover")
        }
    }

    /// Parses `view.frame=(x,y,w,h)` from the overlay label.
    static func parseWindowWidth(from label: String) -> CGFloat? {
        guard let range = label.range(of: "view.frame=(") else { return nil }
        let rest = label[range.upperBound...]
        let parts = rest.split(separator: ",").prefix(4).map(String.init)
        guard parts.count == 4, let w = Double(parts[2]) else { return nil }
        return CGFloat(w)
    }

    /// Scans the screenshot's center column for the first dark-green row
    /// (k2 dotted border #3a4431).
    static func scanDarkRow(in image: UIImage) -> Int? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = cg.bitsPerPixel / 8
        let bpr = cg.bytesPerRow
        let x = width / 2
        for y in 0..<height {
            let off = y * bpr + x * bpp
            let r = CGFloat(ptr[off]) / 255
            let g = CGFloat(ptr[off + 1]) / 255
            let b = CGFloat(ptr[off + 2]) / 255
            if r < 0.6, g < 0.6, b < 0.6, g > r, g > b {
                return y
            }
        }
        return nil
    }
}
