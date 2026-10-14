import StoreKitTest
import XCTest

/// Drives Settings → account → 「閱讀Pro」 against the local StoreKit configuration.
///
/// The row always opens the paywall, the only Pro page: the offer without Pro, its
/// member page with it. What the member page offers — the lifetime upgrade, Apple's
/// subscription management — and the thank-you after a purchase depend on the
/// entitlements StoreKit reports, so they are only observable with real transactions.
/// `SKTestSession` supplies them from `Configuration/YueduPro.storekit`, the file
/// the scheme's Run action uses, with no purchase dialogs or Apple Account.
final class ProStatusNavigationUITests: XCTestCase {
    private static let monthlyID = "com.zhangruilin.yuedureader.pro.monthly"
    private static let lifetimeID = "com.zhangruilin.yuedureader.pro.lifetime"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreeUserOpensThePaywall() throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }

        let app = openProRow(expectsPro: false, subtitle: "Unlock the AI Reading Assistant")
        XCTAssertTrue(
            app.buttons["paywall_purchase_button"].waitForExistence(timeout: 10),
            "a free user should land on the paywall"
        )
        XCTAssertFalse(app.descendants(matching: .any)["pro_status_summary"].exists)
        attach("pro-row-free-paywall")
    }

    @MainActor
    func testMonthlySubscriberCanManageAndUpgrade() async throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: Self.monthlyID, options: [])

        let app = openProRow(expectsPro: true, subtitle: "Subscribed. Thanks for your support!")
        assertStatusPage(app)
        XCTAssertTrue(
            app.buttons["pro_status_plan_action"].label.hasPrefix("Upgrade to Lifetime"),
            "the upgrade names what it buys: \(app.buttons["pro_status_plan_action"].label)"
        )
        XCTAssertTrue(
            reveal(app.buttons["pro_status_manage_subscription"], in: app),
            "a monthly subscriber must reach subscription management"
        )
        XCTAssertTrue(app.buttons["pro_status_restore"].exists)
        attach("pro-status-monthly")
    }

    @MainActor
    func testLifetimeOwnerHasNothingToManageOrBuy() async throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: Self.lifetimeID, options: [])

        let app = openProRow(expectsPro: true, subtitle: "Lifetime member. Thanks for your support!")
        assertStatusPage(app)
        XCTAssertTrue(reveal(app.buttons["pro_status_restore"], in: app), "restore should stay available")
        // Same section as restore, so it would be materialized if it were shown.
        XCTAssertFalse(app.buttons["pro_status_manage_subscription"].exists)
        XCTAssertFalse(app.buttons["pro_status_plan_action"].exists)
        attach("pro-status-lifetime")
    }

    @MainActor
    func testMonthlyAlongsideLifetimeKeepsTheCancellationReminder() async throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }
        // The Swift API returns once each transaction is written. With the deprecated
        // `buyProduct(productIdentifier:)` the app read only the monthly one of two
        // back-to-back purchases and named the plan 已訂閱.
        _ = try await session.buyProduct(identifier: Self.monthlyID, options: [])
        _ = try await session.buyProduct(identifier: Self.lifetimeID, options: [])

        let app = openProRow(expectsPro: true, subtitle: "Lifetime member. Thanks for your support!")
        assertStatusPage(app)
        XCTAssertFalse(app.buttons["pro_status_plan_action"].exists)
        XCTAssertTrue(
            reveal(app.buttons["pro_status_manage_subscription"], in: app),
            "monthly held next to lifetime still needs a way to cancel"
        )
        XCTAssertTrue(
            app.staticTexts["After upgrading, remember to cancel your monthly subscription, or you'll continue to be charged."].exists
        )
        attach("pro-status-monthly-and-lifetime")
    }

    @MainActor
    func testBuyingProCelebratesOnTheSamePage() throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }

        let app = openProRow(expectsPro: false, subtitle: "Unlock the AI Reading Assistant")
        let buy = app.buttons["paywall_purchase_button"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), "a free user should land on the paywall")
        purchase(tapping: buy, in: app)

        assertThankYouPage(app)
        attach("pro-unlocked-celebration")
        app.buttons["pro_celebration_continue"].tap()
        XCTAssertTrue(
            app.buttons["pro_celebration_continue"].waitForNonExistence(timeout: 10),
            "開始使用 closes the paywall, back to where it was opened"
        )
        XCTAssertTrue(app.buttons["settings_pro_row"].firstMatch.label.contains("Enabled"))
    }

    /// Pro stays active through an upgrade, so this is the path a thank-you page keyed
    /// only to Pro turning on never reached — along with its cancellation reminder.
    @MainActor
    func testUpgradeToLifetimeCelebratesAndRemindsToCancelMonthly() async throws {
        let session = try makeStoreKitSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: Self.monthlyID, options: [])

        let app = openProRow(expectsPro: true, subtitle: "Subscribed. Thanks for your support!")
        assertStatusPage(app)
        purchase(tapping: app.buttons["pro_status_plan_action"], in: app)

        assertThankYouPage(app)
        XCTAssertTrue(
            app.staticTexts["Cancel Your Monthly Subscription"].waitForExistence(timeout: 5),
            "the monthly plan keeps billing after the upgrade; the thank-you page has to say so"
        )
        attach("pro-upgrade-celebration")
    }

    /// Taps a buy button once its product has loaded and buys without signing in —
    /// the guest choice every signed-out purchase asks for first.
    @MainActor
    private func purchase(tapping button: XCUIElement, in app: XCUIApplication) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, "the product should load")
        button.tap()
        let guest = app.alerts.buttons["Buy Without Signing In"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10), "a signed-out purchase asks how to buy")
        guest.tap()
    }

    @MainActor
    private func assertThankYouPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["pro_status_summary"].firstMatch
        let unlocked = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Yuedu Pro Unlocked"),
            object: title
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [unlocked], timeout: 20), .completed,
            "the purchase should turn the paywall into its thank-you page",
            file: file,
            line: line
        )
        XCTAssertTrue(app.buttons["pro_celebration_continue"].exists, file: file, line: line)
    }

    @MainActor
    private func makeStoreKitSession() throws -> SKTestSession {
        try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
    }

    @MainActor
    /// `subtitle`: what the row must say under 閱讀Pro before it is tapped — the plan held,
    /// or what Pro unlocks.
    private func openProRow(expectsPro: Bool, subtitle: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // The notification prompt can land on top of the shelf on a fresh install.
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }

        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "settings tab should exist")
        settings.tap()

        let account = app.buttons["settings_account_row"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "the account row should exist")
        account.tap()

        let proRow = app.buttons["settings_pro_row"].firstMatch
        XCTAssertTrue(proRow.waitForExistence(timeout: 10), "the Yuedu Pro row should exist")
        if expectsPro {
            // Entitlements resolve after launch. Wait for the row to show them rather
            // than tapping into whichever destination the unresolved state picks.
            let unlocked = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "Enabled"),
                object: proRow
            )
            XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 20), .completed, "StoreKit should unlock Pro")
        }
        // The plan comes from the same StoreKit read as Pro itself, but Pro can arrive first
        // from the iCloud mirror; wait for the line rather than reading it once.
        let says = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", subtitle),
            object: proRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [says], timeout: 20), .completed,
            "the row should say \"\(subtitle)\"; it says \"\(proRow.label)\""
        )
        attach("settings-pro-row")
        proRow.tap()
        return app
    }

    /// The member page's title heads it, so it is on screen as soon as the paywall
    /// opens on that page. The failure names the visible navigation bar to tell "no
    /// paywall" apart from "the offer instead of the member page".
    @MainActor
    private func assertStatusPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let summary = app.descendants(matching: .any)["pro_status_summary"].firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 10),
            "the paywall should open on its member page; visible navigation bar: \(app.navigationBars.firstMatch.identifier); offer shown: \(app.buttons["paywall_purchase_button"].exists)",
            file: file,
            line: line
        )
    }

    /// Scroll toward controls that can sit below the fold on small screens or large text.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<4 where !element.exists {
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
