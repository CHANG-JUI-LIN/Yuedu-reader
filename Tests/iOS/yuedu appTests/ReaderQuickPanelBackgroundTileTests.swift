import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Feedback #12 (iPad): a saved reading background whose picture was landscape came
/// out wider than its cell in the quick panel's row, and its star badge sat over the
/// ＋自定義 tile beside it. The picture was framed by `maxWidth: .infinity` alone, so a
/// scaled-to-fill picture wider than the tile's 74×82 grew the whole tile.
@MainActor
struct ReaderQuickPanelBackgroundTileTests {
    private static let tileSize = CGSize(
        width: DSLayout.readerQuickPanelBackgroundTileWidth,
        height: DSLayout.readerQuickPanelReadingBackgroundTileHeight
    )

    @Test("a tile keeps to its own width whatever the shape of its picture", arguments: [
        CGSize(width: 120, height: 90),  // 4:3
        CGSize(width: 160, height: 90),  // 16:9
        CGSize(width: 90, height: 90),   // square — still wider than 74×82
        CGSize(width: 90, height: 120),  // portrait, which never overflowed
    ])
    func tileWidthIgnoresPictureAspect(pictureSize: CGSize) {
        // Only the aspect matters; render at 1× so the bitmaps stay tiny.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: pictureSize, format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: pictureSize))
        }
        let tile = ReaderQuickPanelBackgroundTile(
            fill: DSColor.neutralControlFill,
            image: picture,
            title: "Landscape",
            titleColor: DSColor.textPrimary,
            selected: true
        )
        let host = UIHostingController(rootView: tile)

        // What the row offers each tile, and an offer far larger than that: neither
        // may come back wider than the tile.
        for proposal in [Self.tileSize, CGSize(width: 1000, height: 1000)] {
            let fitted = host.sizeThatFits(in: proposal)
            #expect(fitted.width == Self.tileSize.width,
                    "picture \(pictureSize) offered \(proposal) fitted \(fitted)")
            #expect(fitted.height == Self.tileSize.height,
                    "picture \(pictureSize) offered \(proposal) fitted \(fitted)")
        }
    }
}
