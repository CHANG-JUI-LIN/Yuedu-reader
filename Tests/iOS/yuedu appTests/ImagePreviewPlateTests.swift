import Testing
import UIKit
@testable import yuedu_app

/// A picture with transparency is previewed on the colour of the page it was
/// drawn on. 洪武大帝's maps and calligraphy are black ink on a transparent
/// ground: legible on the page, solid black on the preview's black background.
@Suite("Image preview plate")
@MainActor
struct ImagePreviewPlateTests {
    private static let paper = UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)

    /// Black ink in the left half, nothing in the right.
    private static func ink(opaque: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
    }

    @Test("Only a picture with transparency gets the page's colour behind it")
    func plateFollowsTransparency() {
        #expect(CoreTextImagePreviewController.plate(for: Self.ink(opaque: false), pageColor: Self.paper) == Self.paper)
        #expect(CoreTextImagePreviewController.plate(for: Self.ink(opaque: true), pageColor: Self.paper) == nil)
        #expect(CoreTextImagePreviewController.plate(for: Self.ink(opaque: false), pageColor: nil) == nil)
    }

    @Test("The empty part of a transparent picture shows the page's colour, not black")
    func transparentPictureIsDrawnOnThePage() throws {
        let preview = CoreTextImagePreviewController(
            attachment: .init(rect: CGRect(x: 0, y: 0, width: 40, height: 40), image: Self.ink(opaque: false), opacity: 1),
            pageColor: Self.paper)
        preview.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        preview.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: preview.view.bounds.size, format: format).image { context in
            preview.view.layer.render(in: context.cgContext)
        }
        let bitmap = try #require(drawn.cgImage)
        let data = try #require(bitmap.dataProvider?.data as Data?)
        func pixel(x: Int, y: Int) -> [UInt8] {
            let offset = y * bitmap.bytesPerRow + x * 4
            return [data[offset], data[offset + 1], data[offset + 2]]
        }
        // The picture fills the 200pt square: ink on the left, page colour on the right.
        let inked = pixel(x: 50, y: 100), empty = pixel(x: 150, y: 100)
        #expect(inked.allSatisfy { $0 < 20 }, "\(inked)")
        #expect(empty.allSatisfy { $0 > 200 }, "\(empty)")
    }
}
