//
//  yuedu_appUITests.swift
//  yuedu appUITests
//
//  Created by 張瑞麟 on 2026/2/27.
//

import XCTest

final class yuedu_appUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// 進入第一本書並截圖閱讀器畫面，供驗證狀態列 / 頂部標題用。
    @MainActor
    func testOpenFirstBookAndCaptureReaderScreenshot() throws {
        let app = XCUIApplication()
        app.launch()

        // 等首頁出現（書架或空書架）
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 8), "首頁應出現")

        // 若有書本列表，點第一本進入閱讀器
        let bookList = app.tables["home_book_list"]
        if bookList.waitForExistence(timeout: 2) && bookList.cells.count > 0 {
            bookList.cells.firstMatch.tap()
            // 等閱讀器出現（返回鍵或至少等 EPUB 有時間載入）
            let backBtn = app.buttons["reader_back_button"]
            if backBtn.waitForExistence(timeout: 10) {
                // 再等一點讓正文與底部狀態列穩定
                Thread.sleep(forTimeInterval: 2.0)
            } else {
                Thread.sleep(forTimeInterval: 4.0)
            }
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reader Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
