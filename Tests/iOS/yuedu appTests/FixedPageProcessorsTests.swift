import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("FixedPage Processors Tests")
struct FixedPageProcessorsTests {

    @Test("FixedPageSplitProcessor detects wide landscape images")
    func testWideImageDetection() {
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { _ in }
        let square = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000)).image { _ in }
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1000)).image { _ in }

        #expect(!FixedPageSplitProcessor.isWideImage(portrait))
        #expect(!FixedPageSplitProcessor.isWideImage(square))
        #expect(FixedPageSplitProcessor.isWideImage(landscape))
    }

    @Test("FixedPageSplitProcessor splits image into left and right halves")
    func testSplitHalves() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let wideImage = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }

        let halves = FixedPageSplitProcessor.split(image: wideImage)
        #expect(halves != nil)
        guard let (left, right) = halves else { return }

        #expect(Int(left.size.width) == 100)
        #expect(Int(left.size.height) == 100)
        #expect(Int(right.size.width) == 100)
        #expect(Int(right.size.height) == 100)
    }

    @Test("FixedPageCropBordersProcessor crops border from framed image")
    func testCropBorders() {
        // 200x200 image with a 30px white border and a 140x140 blue center
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
        let borderedImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))

            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 30, y: 30, width: 140, height: 140))
        }

        let processor = FixedPageCropBordersProcessor()
        let result = processor.process(borderedImage)
        #expect(result != nil)
        guard let cropped = result else { return }

        // Cropped width and height should be smaller than original 200x200
        #expect(cropped.size.width < 200)
        #expect(cropped.size.height < 200)
    }
}
