import UIKit
import XCTest

/// Feedback #77: under an imported pack whose accent is near white (F5F5F5, E6F2F4) the swipe
/// actions filled with the accent drew the system's white symbol on it at 1.09–1.25. The system
/// draws a swipe action's label and ignores its `foregroundStyle`, so these fill with
/// `DSColor.swipeAction` instead. A swipe action is out of reach of a pixel unit test, so this
/// opens each one for real under an injected near-white accent and measures the WCAG contrast
/// between the action's fill and its label against `DSColor.onAccentMinimumWhiteContrast` (3.0).
///
/// The theme reaches the app through the argument domain — `yd_custom_appearance_themes` as
/// `<data>`, `yd_appearance_theme_id` naming it — so the simulator's own settings keep their
/// selection; `-debug-force-pro`, or a Pro theme is not worn at all. Its light and dark palettes
/// both carry the accent: feedback #77's pack was near white in dark. The app still writes the
/// theme into the simulator's custom themes, and the appearance switches move its bound
/// reading theme: run it on a simulator whose settings can take that.
final class SwipeActionAccentContrastUITests: XCTestCase {
    private static let themeID = "uitest-near-white-accent"
    private static let accents: [UInt32] = [0xF5F5F5, 0xE6F2F4]
    private static let appearances: [XCUIDevice.Appearance] = [.light, .dark]
    /// `DSColor.onAccentMinimumWhiteContrast`.
    private static let minimumContrast = 3.0

    private var originalAppearance: XCUIDevice.Appearance = .light

    override func setUpWithError() throws {
        // Every site × accent × appearance is measured, whichever falls short.
        continueAfterFailure = true
        originalAppearance = XCUIDevice.shared.appearance
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = originalAppearance
    }

    // MARK: - Sites

    /// RSSFeedView's and RSSSmartFeedView's 標為已讀. `-seed-rss-articles` stores a feed of two
    /// unread articles.
    @MainActor
    func testRSSSwipeActions() throws {
        for accent in Self.accents {
            for appearance in Self.appearances {
                let app = try launch(accent: accent, appearance: appearance, extra: ["-seed-rss-articles"])
                let library = app.tabBars.buttons["資源庫"].firstMatch
                XCTAssertTrue(library.waitForExistence(timeout: 30), app.debugDescription)
                library.tap()
                // 訂閱 is the last section. Its RSS 訂閱 tile is drawn but reads as a 0×0 element with
                // no identifier here (theme and seeded feed on), so it is tapped where it is drawn.
                let header = app.staticTexts["訂閱"].firstMatch
                for _ in 0..<6 { app.swipeUp(velocity: .slow) }
                XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
                header.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 60, dy: 50)).tap()
                XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 10), app.debugDescription)

                // RSSListView:504's leading 標記全部已讀 is not measured: the page is a ScrollView, not a
                // List, so its `.swipeActions` never open (its context menu carries the same action).
                let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "首頁訂閱測試")).firstMatch
                XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
                source.tap()
                let article = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "首頁訂閱測試文章一")).firstMatch
                XCTAssertTrue(article.waitForExistence(timeout: 10), app.debugDescription)
                record(site: "RSSFeedView:309 標為已讀", accent: accent, appearance: appearance, app: app,
                       row: article, action: "標為已讀")
                app.navigationBars.buttons.element(boundBy: 0).tap()

                let unread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "所有未讀")).firstMatch
                XCTAssertTrue(unread.waitForExistence(timeout: 10), app.debugDescription)
                unread.tap()
                let smartArticle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "首頁訂閱測試文章一")).firstMatch
                XCTAssertTrue(smartArticle.waitForExistence(timeout: 10), app.debugDescription)
                record(site: "RSSFeedView:94 (RSSSmartFeedView) 標為已讀", accent: accent, appearance: appearance, app: app,
                       row: smartArticle, action: "標為已讀")
                app.terminate()
            }
        }
    }

    /// AISettingsView's 設為預設, on the service that is not the default. The two services
    /// come in through the argument domain, like the theme.
    @MainActor
    func testAIServiceSwipeAction() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        let profiles: [[String: Any]] = [
            ["id": first, "name": "Swipe Service A", "models": [],
             "configuration": ["endpoint": "https://api.deepseek.com/v1", "defaultModel": "deepseek-flash"]],
            ["id": second, "name": "Swipe Service B", "models": [],
             "configuration": ["endpoint": "https://api.openai.com/v1", "defaultModel": "gpt-5-mini"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: profiles)
        for accent in Self.accents {
            for appearance in Self.appearances {
                let app = try launch(accent: accent, appearance: appearance, extra: [
                    "-yd_ai_provider_configuration.profiles", "<data>\(data.base64EncodedString())</data>",
                    "-yd_ai_provider_configuration.active", first,
                ])
                let settings = app.tabBars.buttons["設定"].firstMatch
                XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
                settings.tap()
                let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AI 助手設定")).firstMatch
                for _ in 0..<8 where !(entry.exists && entry.isHittable) { app.swipeUp(velocity: .slow) }
                XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
                entry.tap()
                let service = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Swipe Service B")).firstMatch
                XCTAssertTrue(service.waitForExistence(timeout: 10), app.debugDescription)
                record(site: "AISettingsView:423 設為預設", accent: accent, appearance: appearance, app: app,
                       row: service, action: "設為預設")
                app.terminate()
            }
        }
    }

    /// ReaderStyleAssetLibraryView's 重新命名, in the sheet 對話氣泡's 選擇頭像 opens over 閱讀設定
    /// over the reader — the library is reached only from a book. The book is served from
    /// outside the simulator, from the repo root: `python3 -I scripts/reader_chrome_fixture.py`
    /// (port 18771), as for `ReaderFontImportUITests`. The library lists the simulator's own
    /// assets; it needs one. One launch per accent, the appearance switched under the open
    /// sheet, since reaching it takes a book.
    @MainActor
    func testReaderStyleAssetLibrarySwipeAction() throws {
        let fixture = "http://localhost:18771", sourceName = "Swipe Contrast Source"
        let token = String(Int.random(in: 1000...9999))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwipeContrast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source: [String: Any] = [
            "bookSourceName": sourceName, "bookSourceUrl": fixture, "bookSourceType": 0,
            "enabled": true, "enabledExplore": true,
            "exploreUrl": "熱門::\(fixture)/explore?page={{page}}",
            "searchUrl": "\(fixture)/search?q={{key}}&page={{page}}",
            "ruleExplore": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                            "bookUrl": "tag.a@href"],
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                           "bookUrl": "tag.a@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "id.content@html"],
            "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: directory.appendingPathComponent("book_sources.json"))

        for accent in Self.accents {
            _ = try Data(contentsOf: URL(string: "\(fixture)/reset?token=\(token)\(accent)")!)
            let app = try launch(accent: accent, appearance: .light,
                                 extra: ["-book-source-store-dir", directory.path])
            openBook(app, source: sourceName, title: "Chrome Fixture \(token)\(accent)")
            openReaderSettings(app)

            let bubble = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "對話氣泡")).firstMatch
            for _ in 0..<10 where !(bubble.exists && bubble.isHittable) { app.swipeUp(velocity: .slow) }
            bubble.tap()
            let toggle = app.switches["啟用對話氣泡"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
            let wasEnabled = toggle.value as? String == "1"
            if !wasEnabled { flip(toggle) }
            let avatar = app.buttons.matching(NSPredicate(format: "label IN %@", ["選擇頭像", "更換頭像"])).firstMatch
            for _ in 0..<10 where !(avatar.exists && avatar.isHittable) { app.swipeUp(velocity: .slow) }
            avatar.tap()
            XCTAssertTrue(app.navigationBars["素材庫"].waitForExistence(timeout: 10), app.debugDescription)
            let asset = app.buttons.matching(NSPredicate(format: "value CONTAINS %@", " × ")).firstMatch
            XCTAssertTrue(asset.waitForExistence(timeout: 10), "the library has no asset to swipe\n\(app.debugDescription)")

            for appearance in Self.appearances {
                XCUIDevice.shared.appearance = appearance
                record(site: "ReaderStyleAssetLibraryView:127 重新命名", accent: accent, appearance: appearance, app: app,
                       row: asset, action: "重新命名")
                // Dragged shut, not tapped: a tap on the row would pick the asset as the avatar.
                drag(asset, from: 0.2, to: 0.8)
                waitForDisappearance(app.buttons["重新命名"].firstMatch)
            }
            XCTAssertTrue(app.navigationBars["素材庫"].exists, "no asset was picked\n\(app.debugDescription)")
            if !wasEnabled {
                // Dragged down from its bar: a fast swipe there leaves the sheet up.
                let bar = app.navigationBars["素材庫"]
                bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                waitForDisappearance(bar)
                for _ in 0..<10 where !(toggle.exists && toggle.isHittable) { app.swipeDown(velocity: .slow) }
                XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
                flip(toggle)
                XCTAssertEqual(toggle.value as? String, "0", "對話氣泡 is left as it was")
            }
            app.terminate()
        }
    }

    /// The switch sits at the row's trailing end (the row is the element on iOS 17).
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
    }

    // MARK: - Reader route

    /// 資源庫 › 所有來源配置 › the source › the run's book › 立即閱讀 (`ReaderFontImportUITests`).
    @MainActor
    private func openBook(_ app: XCUIApplication, source: String, title: String) {
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let row = app.buttons["library.source.\(source)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '立即閱讀' OR label BEGINSWITH '開始閱讀'"))
            .firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<6 where !read.isHittable { app.swipeDown(velocity: .slow) }
        read.tap()
    }

    /// The reader's chrome › 主題 › 自訂: 閱讀設定.
    @MainActor
    private func openReaderSettings(_ app: XCUIApplication) {
        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "測試閱讀器工具列")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "the chapter never showed\n\(app.debugDescription)")
        let back = app.buttons["reader_back_button"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists, back.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed, app.debugDescription)
        app.buttons["reader_tool_settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["自動閱讀"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let customize = app.buttons.matching(NSPredicate(format: "label == %@", "自訂")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY }
        customize?.tap()
        XCTAssertTrue(app.navigationBars["閱讀設定"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    // MARK: - Launch

    @MainActor
    private func launch(accent: UInt32, appearance: XCUIDevice.Appearance, extra: [String]) throws -> XCUIApplication {
        XCUIDevice.shared.appearance = appearance
        let theme: [String: Any] = [
            "id": Self.themeID, "name": "Swipe Contrast",
            "backgroundHex": 0xFFFFFF, "textHex": 0x1C1C1E, "barHex": 0xF7F7F7,
            "accentHex": accent, "dialogueHex": 0x1C1C1E,
            "dark": ["backgroundHex": 0x000000, "textHex": 0xF2F2F7, "barHex": 0x1C1C1E,
                     "accentHex": accent, "dialogueHex": 0xF2F2F7],
        ]
        let themes = try JSONSerialization.data(withJSONObject: [theme])
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-debug-force-pro",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-yd_custom_appearance_themes", "<data>\(themes.base64EncodedString())</data>",
                               "-yd_appearance_theme_id", Self.themeID,
                               "-yd_appearance_dark_theme_id", Self.themeID] + extra
        app.launch()
        return app
    }

    // MARK: - Measuring

    /// Opens `row`'s trailing swipe actions by a slow drag across half the row — short of a
    /// full swipe, which would run the first action — and measures the button named `action`.
    @MainActor
    private func record(site: String, accent: UInt32, appearance: XCUIDevice.Appearance, app: XCUIApplication,
                        row: XCUIElement, action: String) {
        drag(row, from: 0.92, to: 0.5)
        let button = app.buttons[action].firstMatch
        let name = "\(site) · \(String(format: "%06X", accent)) · \(appearance == .dark ? "dark" : "light")"
        guard settled(button) else {
            XCTFail("\(name): the swipe action did not open\n\(app.debugDescription)")
            return
        }
        let shot = XCUIScreen.main.screenshot()
        let full = XCTAttachment(screenshot: shot)
        full.name = name
        full.lifetime = .keepAlways
        add(full)
        guard let result = measure(button.frame, in: shot.image) else {
            XCTFail("\(name): no pixels under \(button.frame)")
            return
        }
        let line = "SWIPE_CONTRAST|\(site)|\(String(format: "%06X", accent))|\(appearance == .dark ? "dark" : "light")"
            + "|fill \(result.fill.hex) (\(Int(result.fillShare * 100))%)|label \(result.label.hex)"
            + "|\(String(format: "%.2f", result.ratio))"
        print(line)
        XCTContext.runActivity(named: line) { activity in
            let crop = XCTAttachment(image: result.crop)
            crop.name = name
            crop.lifetime = .keepAlways
            activity.add(crop)
        }
        XCTAssertGreaterThanOrEqual(result.ratio, Self.minimumContrast, line)
    }

    /// A slow horizontal drag across `row`, between two fractions of its width.
    @MainActor
    private func drag(_ row: XCUIElement, from start: CGFloat, to end: CGFloat) {
        row.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Present, hittable, and no longer moving: the swipe has finished opening.
    @MainActor
    private func settled(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        var last = element.frame
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            let frame = element.frame
            if frame == last, element.isHittable { return true }
            last = frame
        }
        return false
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 5)
    }

    private struct RGB: Hashable {
        var red: Double, green: Double, blue: Double
        var hex: String {
            String(format: "%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
        }
    }

    private struct Measurement {
        var fill: RGB, label: RGB, ratio: Double, fillShare: Double, crop: UIImage
    }

    /// The action's fill is the commonest colour inside the ellipse inscribed in 80% of its
    /// frame, which keeps a circle's or capsule's corners — the row or sheet behind — out; its
    /// label is the pixel there that contrasts most with that fill — a glyph's core, past its
    /// antialiased edge.
    private func measure(_ frame: CGRect, in image: UIImage) -> Measurement? {
        guard let source = image.cgImage else { return nil }
        let width = source.width, height = source.height
        let scale = CGFloat(width) / (image.size.width)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let (centerX, centerY) = (frame.midX * scale, frame.midY * scale)
        let (radiusX, radiusY) = (frame.width * 0.4 * scale, frame.height * 0.4 * scale)
        let x0 = max(0, Int(centerX - radiusX)), x1 = min(width, Int(centerX + radiusX))
        let y0 = max(0, Int(centerY - radiusY)), y1 = min(height, Int(centerY + radiusY))
        guard x1 > x0, y1 > y0 else { return nil }

        var counts: [UInt32: Int] = [:]
        var total = 0
        // Rows top to bottom: the context's first row in memory is the image's top.
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (dx, dy) = ((CGFloat(x) + 0.5 - centerX) / radiusX, (CGFloat(y) + 0.5 - centerY) / radiusY)
                guard dx * dx + dy * dy <= 1 else { continue }
                total += 1
                let i = (y * width + x) * 4
                let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                counts[key, default: 0] += 1
            }
        }
        guard let (fillKey, fillCount) = counts.max(by: { $0.value < $1.value }) else { return nil }
        let fill = rgb(fillKey)
        var label = fill, best = 1.0
        for key in counts.keys {
            let candidate = rgb(key)
            let ratio = contrast(candidate, fill)
            if ratio > best { best = ratio; label = candidate }
        }
        let cropRect = CGRect(x: Int(frame.minX * scale), y: Int(frame.minY * scale),
                              width: Int(frame.width * scale), height: Int(frame.height * scale))
        let crop = source.cropping(to: cropRect).map { UIImage(cgImage: $0) } ?? image
        return Measurement(fill: fill, label: label, ratio: best, fillShare: Double(fillCount) / Double(total), crop: crop)
    }

    private func rgb(_ key: UInt32) -> RGB {
        RGB(red: Double((key >> 16) & 0xFF) / 255, green: Double((key >> 8) & 0xFF) / 255, blue: Double(key & 0xFF) / 255)
    }

    /// `CoverTint.luminance` / `CoverTint.contrast`: the UI-test target cannot import the app.
    private func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
