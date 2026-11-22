import SwiftUI
import Testing
@testable import yuedu_app

/// 回饋中心 #237 (3.0.2 (156)): a video whose episode had a 60-character name drew its play
/// button on a row of its own, a very wide capsule, with ＋／選集／換源 under it. The name,
/// which truncates, was counted in the width the row asked for, so the row no longer fitted a
/// phone and the layout meant for large text was chosen at the default size.
@MainActor
struct VideoHeroActionRowLayoutTests {
    /// The hero's width on a phone 375 and 393 points wide, inside its margins.
    nonisolated private static let phoneWidths: [CGFloat] = [375, 393].map { $0 - 2 * DSLayout.videoDetailMargin }
    private static let shortName = "第 3 集"
    private static let longName = String(repeating: "很長的集名", count: 12)

    private func rowSize(detail: String?, width: CGFloat, textSize: DynamicTypeSize = .large) -> CGSize {
        let row = Self.row(detail: detail)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, textSize)
        return UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    static func row(detail: String?) -> some View {
        VideoHeroActionRow(action: BookDetailAction(title: "繼續播放", systemImage: "play.fill",
                                                    detail: detail, action: {})) {
            ForEach(["plus", "list.bullet", "arrow.triangle.2.circlepath"], id: \.self) { symbol in
                Button {} label: { Image(systemName: symbol).modifier(VideoHeroCapsuleIcon()) }
            }
        }
    }

    @Test("a 60-character episode name keeps the buttons on one row", arguments: phoneWidths)
    func longEpisodeNameKeepsOneRow(width: CGFloat) {
        #expect(Self.longName.count == 60)
        let short = rowSize(detail: Self.shortName, width: width)
        let long = rowSize(detail: Self.longName, width: width)
        #expect(long.height == short.height, "long \(long), short \(short)")
        #expect(long.width <= width)
    }

    @Test("the capsule still goes under the play button at an accessibility text size",
          arguments: phoneWidths)
    func largeTextStacks(width: CGFloat) {
        let oneRow = rowSize(detail: Self.shortName, width: 2000, textSize: .accessibility5)
        let onPhone = rowSize(detail: Self.shortName, width: width, textSize: .accessibility5)
        #expect(onPhone.height >= oneRow.height + DSLayout.minimumTapTarget,
                "phone \(onPhone), one row \(oneRow)")
    }
}
