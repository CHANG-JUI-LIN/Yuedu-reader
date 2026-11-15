import SwiftUI
import Testing
@testable import yuedu_app

/// 回饋中心 #198 and #199 (iPad, iOS 27.2): 探索's home and 呈現方式's gallery jumped by a row as
/// they were scrolled back up. Their lazy stacks make a row again as it comes back, and 一大四小,
/// 固定封面網格 and 色帶 sized their covers from a width they measured a pass later: laid out
/// first at no width, the row then grew by 355 to 483 points, which the stack did not take
/// back from the offset. Sized from the width the page hands down (`homeRowWidth`), the row has
/// its whole height on its first layout.
@MainActor
struct HomeRowFirstLayoutTests {
    private static let width: CGFloat = 1024

    private func firstLayoutHeight(_ style: HomeLayoutStyle, rowWidth: CGFloat?) -> CGFloat {
        let row = HomeSectionCards(layout: HomeSectionLayout(style: style), cards: (0..<6).map(HomeCardContent.placeholder),
                                   rowID: "firstLayout.\(style.rawValue)", hasShowAll: true, open: { _, _ in })
            .environment(\.homeRowWidth, rowWidth)
            .environment(\.horizontalSizeClass, .regular)
        // One layout pass: what a lazy stack sees as it makes the row.
        return UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
    }

    @Test("a row sized by its page's width has its covers on its first layout",
          arguments: [HomeLayoutStyle.heroGrid, .coverGrid, .colorBand])
    func rowHasItsHeightOnItsFirstLayout(style: HomeLayoutStyle) {
        let height = firstLayoutHeight(style, rowWidth: Self.width)
        // A cover is taller than this at any width a page has; the jumping rows measured 0 here.
        #expect(height > 100, "\(style.rawValue): \(height)")
    }
}
