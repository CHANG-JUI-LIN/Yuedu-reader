import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// A comment card with glass panels on a page the package lays out: the page on screen puts
/// the system's glass behind it, a picture of the page a still stand-in — what the CoreText
/// page does (`ReviewCardGlassDrawing`).
@MainActor
@Suite struct BrowserReviewCardGlassTests {
    private static let cardRect = CGRect(x: 10, y: 20, width: 80, height: 40)

    /// A card of clear pixels, so whatever a bitmap shows where it is came from the glass.
    private static func list(glass: Bool) -> DisplayList {
        let clear = UIGraphicsImageRenderer(size: cardRect.size).image { _ in }
        let panels = glass ? [ReviewCardGlassPanel(rect: CGRect(origin: .zero, size: cardRect.size), cornerRadius: 0)] : []
        let card = ReviewCardImage(image: clear, glassPanels: panels, isNight: false)!
        return DisplayList(items: [
            .image(DisplayImageItem(source: "yd-added:card/0/0", image: card, sourceRange: NSRange(location: 4, length: 0),
                                    nodeID: 1, linkTarget: nil, writingMode: .horizontal,
                                    rect: PageLocalRect(rawValue: cardRect), alt: nil)),
        ])
    }

    /// The red of the pixel in the middle of the card on a black page.
    private static func middleRed(_ list: DisplayList, glassCards: ReviewCardGlassDrawing) -> UInt8 {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Eight bits a channel: the default on a wide-colour device is sixteen-bit floats.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ReaderDisplayListDrawer.draw(list, in: context.cgContext, glassCards: glassCards)
        }
        let bitmap = image.cgImage!
        precondition(bitmap.bitsPerPixel == 32)
        let data = bitmap.dataProvider!.data! as Data
        let offset = Int(cardRect.midY) * bitmap.bytesPerRow + Int(cardRect.midX) * 4
        // BGRA or RGBA: the stand-in is white, so the middle channels read the same.
        return data[offset + 1]
    }

    @Test func aPictureOfThePageDrawsTheStandInUnderTheCard() {
        #expect(Self.middleRed(Self.list(glass: true), glassCards: .baked) > 0)
    }

    @Test func thePageOnScreenLeavesTheCardToItsGlassView() {
        #expect(Self.middleRed(Self.list(glass: true), glassCards: .liveViews) == 0)
    }

    @Test func aCardWithoutGlassIsAnOrdinaryPicture() {
        #expect(Self.list(glass: false).items[0].reviewCardGlass == nil)
        #expect(Self.middleRed(Self.list(glass: false), glassCards: .liveViews) == 0)
    }

    @Test func aPageShownWholeHostsOneGlassViewPerCard() {
        let page = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        page.displayList = Self.list(glass: true)
        let views = page.subviews.compactMap { $0 as? ReviewCardGlassView }
        #expect(views.map(\.frame) == [Self.cardRect])

        page.displayList = .empty
        #expect(page.subviews.contains { $0 is ReviewCardGlassView } == false)
    }

    /// A scroll tile is a window on its chapter: it holds the glass of the cards in it too.
    @Test func aScrollTileHostsItsCardsGlass() {
        let page = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        page.usesContinuousScrolling = true
        page.usesExternalContentSurface = true
        page.displayList = Self.list(glass: true)
        #expect(page.subviews.compactMap { $0 as? ReviewCardGlassView }.map(\.frame) == [Self.cardRect])
    }
}
