import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Manga zoomable scroll view")
@MainActor
struct MangaZoomableScrollViewTests {

    @Test("setting zoomView inserts it into the scroll view")
    func settingZoomViewInsertsSubview() {
        let scrollView = MangaZoomableScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let imageView = UIImageView()

        scrollView.zoomView = imageView

        #expect(imageView.superview === scrollView)
        #expect(scrollView.subviews.contains(imageView))
    }

    @Test("replacing zoomView removes the previous view")
    func replacingZoomViewRemovesPreviousView() {
        let scrollView = MangaZoomableScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let firstView = UIImageView()
        let secondView = UIImageView()

        scrollView.zoomView = firstView
        scrollView.zoomView = secondView

        #expect(firstView.superview == nil)
        #expect(secondView.superview === scrollView)
        #expect(!scrollView.subviews.contains(firstView))
        #expect(scrollView.subviews.contains(secondView))
    }
}
