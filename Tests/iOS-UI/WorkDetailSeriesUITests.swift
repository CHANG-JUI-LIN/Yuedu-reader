import XCTest
import zlib

/// 同系列 on 作品詳情 (maintainer, 2026-10-12): the hero names the series and its number and
/// opens the series page; the section lists the other volumes, each numbered in place of its
/// author.
///
/// The books are five EPUB 3 files the test writes (`belongs-to-collection` + `group-position`,
/// each with a cover of its own colour, so the series page fans them as it does real artwork),
/// imported one per launch (`-auto-import-epub` with an absolute path, DEBUG). The test deletes
/// them from the shelf at the end.
final class WorkDetailSeriesUITests: XCTestCase {
    private let series = "系列驗收"
    private let titles = ["系列驗收一", "系列驗收二", "系列驗收三", "系列驗收四", "系列驗收五"]
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetailSeries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (offset, title) in titles.enumerated() {
            try Self.epub(title: title, series: series, position: offset + 1).write(to: file(title))
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func file(_ title: String) -> URL { folder.appendingPathComponent("\(title).epub") }

    @MainActor
    private func launch(importing title: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", file(title).path, "-auto-import-title", title]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        XCTAssertTrue(shelfBook(app, title).waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    @MainActor
    private func shelfBook(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
    }

    /// The cell's •••, as `WorkDetailUITests` reaches it in the grid and the list.
    @MainActor
    private func openMenu(_ app: XCUIApplication, _ title: String) {
        let cell = shelfBook(app, title)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        let more = cell.buttons["更多"].firstMatch
        if more.exists {
            more.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        }
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testSeriesOnWorkDetail() {
        var app: XCUIApplication!
        for title in titles {
            app?.terminate()
            app = launch(importing: title)
        }

        // Volume 2's 作品詳情: the hero names the series, 同系列 lists volumes 1 and 3.
        openMenu(app, titles[1])
        let detailItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(detailItem.waitForExistence(timeout: 5), app.debugDescription)
        detailItem.tap()
        let link = app.buttons["detail.link.series"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(link.label, "\(series) · 第 2 冊")
        let volumes = app.descendants(matching: .any).matching(identifier: "detail.series.book")
        let first = volumes.firstMatch
        if !first.exists { app.swipeUp() }
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(volumes.count, titles.count - 1, "the page's own volume is not listed again")
        // A shelf copy says what the shelf says of it (title, author, status), then its number.
        XCTAssertTrue(volumes.element(boundBy: 0).label.hasPrefix(titles[0] + "，"), app.debugDescription)
        XCTAssertEqual(volumes.element(boundBy: 0).value as? String, "第 1 冊")
        XCTAssertTrue(volumes.element(boundBy: 1).label.hasPrefix(titles[2] + "，"), app.debugDescription)
        XCTAssertEqual(volumes.element(boundBy: 1).value as? String, "第 3 冊")
        screenshot(app, "work-detail-series-section")

        // The hero's link: every volume, in series order, under the series' name.
        if !link.isHittable { app.swipeDown() }
        link.tap()
        let page = app.navigationBars[series].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), app.debugDescription)
        // As Apple Books' store draws a series (2026-11-14): its name and how many it holds on
        // the hero, one button to the first volume, then a row for each, numbered.
        XCTAssertTrue(app.staticTexts["系列 · 5 本"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["檢視第 1 冊"].firstMatch.exists, app.debugDescription)
        // The author the volumes share opens their page, as 作品詳情's does.
        XCTAssertTrue(app.buttons["publicLibrary.author.系列驗收作者"].firstMatch.exists, app.debugDescription)
        screenshot(app, "work-detail-series-page")
        let rows = app.buttons.matching(identifier: "detail.series.volume")
        for (offset, title) in titles.enumerated() {
            let row = rows.matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
            for _ in 0..<4 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title)\n\(app.debugDescription)")
            XCTAssertEqual(row.value as? String, "第 \(offset + 1) 冊")
        }
        // Books only, so no 書籍｜有聲書 to choose between.
        XCTAssertFalse(app.buttons["detail.series.form.books"].exists)
        screenshot(app, "work-detail-series-page-volumes")

        // A volume opens its own 作品詳情.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", titles[2] + "，")).firstMatch.tap()
        let third = app.buttons["detail.link.series"].firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(third.label, "\(series) · 第 3 冊")

        // The books leave the shelf, so the next run starts from the same place.
        app.terminate()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        for title in titles {
            openMenu(app, title)
            let delete = app.buttons["刪除書籍"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
            delete.tap()
            let confirm = app.alerts.buttons["刪除"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            confirm.tap()
            XCTAssertTrue(shelfBook(app, title).waitForNonExistence(timeout: 10))
        }
    }

    // MARK: - The books

    /// A minimal EPUB 3 in a series, as Calibre writes one.
    private static func epub(title: String, series: String, position: Int) throws -> Data {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:series-acceptance-\(position)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>系列驗收作者</dc:creator>
            <dc:language>zh-Hant</dc:language>
            <meta property="belongs-to-collection" id="series">\(series)</meta>
            <meta refines="#series" property="collection-type">series</meta>
            <meta refines="#series" property="group-position">\(position)</meta>
          </metadata>
          <manifest>
            <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        func xhtml(_ body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(title)</title></head><body>\(body)</body></html>
            """
        }
        return StoredZip.archive([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
            ("OPS/package.opf", Data(opf.utf8)),
            ("OPS/nav.xhtml", Data(xhtml(#"<nav epub:type="toc"><ol><li><a href="chapter1.xhtml">一</a></li></ol></nav>"#).utf8)),
            ("OPS/chapter1.xhtml", Data(xhtml("<p>\(title)的正文。</p>").utf8)),
            ("OPS/cover.png", cover(title, hue: CGFloat(position) / 6)),
        ])
    }

    /// A jacket in one colour with the title on it: real artwork to the app, which fans only
    /// volumes that have some.
    private static func cover(_ title: String, hue: CGFloat) -> Data {
        let size = CGSize(width: 400, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: hue, saturation: 0.75, brightness: 0.78, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (title as NSString).draw(in: CGRect(x: 40, y: 70, width: 320, height: 400),
                                     withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white])
        }
    }
}

/// A ZIP of stored (uncompressed) entries: all an EPUB needs, and the UI-test target links no
/// archive library.
private enum StoredZip {
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = entry.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = UInt32(archive.count)
            var local = Data()
            local.append(le32(0x0403_4b50)); local.append(le16(20)); local.append(le16(0x0800)); local.append(le16(0))
            local.append(le16(0)); local.append(le16(0x21))
            local.append(le32(crc)); local.append(le32(UInt32(entry.data.count))); local.append(le32(UInt32(entry.data.count)))
            local.append(le16(UInt16(name.count))); local.append(le16(0))
            archive.append(local); archive.append(name); archive.append(entry.data)

            directory.append(le32(0x0201_4b50)); directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(UInt32(entry.data.count))); directory.append(le32(UInt32(entry.data.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4b50)); archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(directoryOffset)); archive.append(le16(0))
        return archive
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
