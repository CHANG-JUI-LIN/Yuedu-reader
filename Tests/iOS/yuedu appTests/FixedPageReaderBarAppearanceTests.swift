import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

@MainActor
final class FixedPageReaderBarAppearanceTests: XCTestCase {
    func testDetailAndShelfHostsBackReaderToolbarAndRestoreItOnExit() throws {
        guard #unavailable(iOS 18.0) else {
            throw XCTSkip("The UIKit toolbar compatibility path is specific to iOS 17")
        }
        for isShelf in [false, true] {
            let metadata = FileManager.default.temporaryDirectory
                .appendingPathComponent("bar-test-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: metadata) }
            let store = BookStore(metadataFileURL: metadata)
            var book = ReadingBook(title: "Manga", author: "", contentFilename: "")
            book.isOnline = true
            let reader = FixedPageReaderViewController(
                book: book, store: store, state: FixedPageReaderState(),
                chapterFetcher: MockChapterFetcher()
            )
            let host: UIViewController = isShelf
                ? ReaderHostingController(content: AnyView(Color.clear))
                : UIHostingController(rootView: Color.clear)
            let nav = UINavigationController()
            nav.setViewControllers([UIViewController(), host], animated: false)
            host.addChild(reader)
            host.view.addSubview(reader.view)
            reader.didMove(toParent: host)

            let original = UIToolbarAppearance()
            original.configureWithTransparentBackground()
            original.backgroundColor = .systemPink
            let edge = UIToolbarAppearance()
            edge.configureWithTransparentBackground()
            edge.backgroundColor = .systemGreen
            nav.toolbar.standardAppearance = original
            nav.toolbar.compactAppearance = nil
            nav.toolbar.scrollEdgeAppearance = edge
            nav.toolbar.compactScrollEdgeAppearance = nil

            reader.beginAppearanceTransition(true, animated: false)
            reader.endAppearanceTransition()
            XCTAssertNotNil(nav.toolbar.standardAppearance.backgroundEffect)
            XCTAssertNotNil(nav.toolbar.compactAppearance?.backgroundEffect)
            XCTAssertNotNil(nav.toolbar.scrollEdgeAppearance?.backgroundEffect)
            XCTAssertNotNil(nav.toolbar.compactScrollEdgeAppearance?.backgroundEffect)
            if isShelf {
                XCTAssertNotNil(host.navigationItem.scrollEdgeAppearance?.backgroundEffect)
            } else {
                XCTAssertNil(host.navigationItem.scrollEdgeAppearance)
            }

            reader.beginAppearanceTransition(false, animated: false)
            reader.endAppearanceTransition()
            XCTAssertEqual(nav.toolbar.standardAppearance.backgroundColor, original.backgroundColor)
            XCTAssertEqual(nav.toolbar.scrollEdgeAppearance?.backgroundColor, edge.backgroundColor)
            XCTAssertNil(nav.toolbar.compactAppearance)
            XCTAssertNil(nav.toolbar.compactScrollEdgeAppearance)
        }
    }
}
