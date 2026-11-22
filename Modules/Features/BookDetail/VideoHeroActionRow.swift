import SwiftUI

/// VidHub's action row on a video's detail page: the play button, then the page's other actions
/// together in one glass capsule as tall as it (maintainer, 2026-11-01: 「那三個按鈕包在一個
/// 膠囊裡面」, 「我要的是這樣的玻璃膠囊」); the capsule goes under it when the text is too large
/// for one line.
struct VideoHeroActionRow<Icons: View>: View {
    /// 開始播放 or 繼續播放, and in `detail` the episode it plays.
    let action: BookDetailAction
    /// The capsule's icon buttons, each in a `VideoHeroCapsuleIcon` slot.
    @ViewBuilder var icons: Icons

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.lg) {
                playButton
                capsule
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: DSSpacing.md) {
                playButton
                capsule
            }
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) { icons }
            .font(DSFont.title3)
            .foregroundStyle(DSColor.textPrimary)
            .buttonStyle(.borderless)
            .frame(maxHeight: .infinity)
            .modifier(CardButtonGlass())
    }

    /// The white capsule plezy, Infuse and VidHub lead with, in light and dark alike
    /// (maintainer, 2026-11-01: 「給我調成白色吧，白天模式下」): its title, and the episode
    /// it plays on a second line under it.
    private var playButton: some View {
        Button(action: action.action) {
            HStack(spacing: DSLayout.videoPlayIconSpacing) {
                Image(systemName: action.systemImage)
                    .font(DSFont.subheadline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(action.title)
                        .font(DSFont.footnote.weight(.semibold))
                    if let detail = action.detail {
                        // The episode's name asks for no width of its own: it takes what the
                        // row gives the button and truncates. Counted in, a long name made
                        // the row too wide to fit and the stacked layout was chosen at the
                        // default text size (回饋中心 #237).
                        Text(detail)
                            .font(DSFont.caption2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                }
                .lineLimit(1)
            }
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.lg)
            .frame(maxWidth: DSLayout.videoPlayButtonMaxWidth)
        }
        .buttonStyle(BookDetailCardActionStyle(fill: DSColor.cardPrimaryActionFill,
                                               label: DSColor.cardPrimaryActionLabel,
                                               minHeight: DSLayout.videoPlayButtonHeight))
        .disabled(!action.isEnabled)
        .accessibilityLabel(action.title)
        .accessibilityValue(action.detail ?? "")
    }
}

/// One icon's slot in the hero's glass capsule: a full-height tap target.
struct VideoHeroCapsuleIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: DSLayout.videoActionSlotWidth, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }
}

#Preview("集名：短、60 字、大字級") {
    let longName = String(repeating: "很長的集名", count: 12)
    let row = { (detail: String) in
        VideoHeroActionRow(action: BookDetailAction(title: localized("繼續播放"), systemImage: "play.fill",
                                                    detail: detail, action: {})) {
            Button {} label: { Image(systemName: "plus").modifier(VideoHeroCapsuleIcon()) }
                .accessibilityLabel(localized("加入書架"))
            Button {} label: { Image(systemName: "list.bullet").modifier(VideoHeroCapsuleIcon()) }
                .accessibilityLabel(localized("選集"))
            Button {} label: { Image(systemName: "arrow.triangle.2.circlepath").modifier(VideoHeroCapsuleIcon()) }
                .accessibilityLabel(localized("換源"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    return VStack(spacing: DSSpacing.xl) {
        row("第 3 集")
        row(longName)
        row(longName).environment(\.dynamicTypeSize, .accessibility3)
    }
    .padding(DSLayout.videoDetailMargin)
    .background(DSColor.textSecondary)
}
