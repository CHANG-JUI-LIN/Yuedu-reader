import SwiftUI

/// The top of a video's detail page, point for point as VidHub draws a series (maintainer,
/// 2026-11-01: 「我叫你 1 比 1 pt 復刻」 against its 法網遊龍 page): the poster across the width
/// at 2:3 from the top edge of the screen, fading at its foot into the colour the whole page is
/// drawn in (`BookDetailScaffold.pageTint`, taken from that foot), with the title, a line of
/// facts and the buttons over the faded part, and the intro under it.
///
/// A wide window — an iPad, a phone on its side — keeps the poster across the width but only as
/// tall as part of the window, the text in a bottom-leading column, as plezy, Infuse, VidHub and
/// Swiftfin lay out their iPad pages (maintainer, 2026-11-01: 「你確定他們 ipad 版本橫屏是這樣嗎？」):
/// a 2:3 box that wide would be taller than the window. A poster card stands above the title
/// until there is artwork: a generated cover drawn across the width would print the title twice.
struct VideoDetailHero<Cover: View, Actions: View, Intro: View>: View {
    /// The source's artwork, once it has loaded; nil while it loads and when there is none.
    let poster: UIImage?
    let title: String
    /// The maker, the episode count and the genres: one line under the title, a dot between
    /// each, as VidHub lists a series' first air date, country and episodes.
    let facts: [String]
    @ViewBuilder var cover: Cover
    @ViewBuilder var actions: Actions
    @ViewBuilder var intro: Intro

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.bookDetailHeroBarInset) private var barInset
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Wide enough that a centred title would float in the middle of the poster: the text
    /// moves to the leading edge, as plezy's hero does past a phone's width.
    private var isWide: Bool { horizontalSizeClass == .regular || verticalSizeClass == .compact }

    /// The poster is gone before the text begins, so the text is on the page alone.
    private var fadesEarly: Bool {
        contrast == .increased || reduceTransparency || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        let alignment: HorizontalAlignment = isWide ? .leading : .center
        let margin = isWide ? DSSpacing.xl : DSLayout.videoDetailMargin
        VStack(alignment: alignment, spacing: DSLayout.videoHeroIntroSpacing) {
            ZStack(alignment: .bottom) {
                if poster != nil { posterFrame }
                VStack(alignment: alignment, spacing: 0) {
                    if poster == nil {
                        posterCard(width: isWide ? DSLayout.videoPosterWideWidth : DSLayout.videoPosterWidth)
                            .padding(.bottom, DSSpacing.lg)
                    }
                    titleBlock(alignment: alignment)
                        .padding(.bottom, DSLayout.videoHeroFactsActionsSpacing)
                    actions
                }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                .padding(.horizontal, margin)
                .padding(.top, barInset + margin)
                .padding(.bottom, DSSpacing.xs)
            }
            .frame(maxWidth: .infinity)
            .background {
                if let poster {
                    VideoPosterBackdrop(image: poster, fadesEarly: fadesEarly)
                }
            }
            intro
                .frame(maxWidth: isWide ? DSLayout.readableListWidth : nil)
                .padding(.horizontal, margin)
        }
    }

    /// The poster's box: 2:3 across a phone, part of the window's height on a wide one. The
    /// text grows the hero past it at the larger sizes.
    @ViewBuilder
    private var posterFrame: some View {
        if isWide {
            Color.clear
                .containerRelativeFrame(.vertical) { length, _ in length * DSLayout.videoHeroHeightFraction }
        } else {
            Color.clear
                .aspectRatio(DSLayout.videoPosterAspectRatio, contentMode: .fit)
        }
    }

    private func posterCard(width: CGFloat) -> some View {
        cover
            .frame(width: width, height: width / DSLayout.discoverCoverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .shadow(color: DSColor.bookDetailCoverShadow, radius: DSLayout.bookDetailCoverShadowRadius,
                    y: DSLayout.bookDetailCoverShadowOffsetY)
            .accessibilityHidden(true)
    }

    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: DSSpacing.sm) {
            Text(title)
                .font(DSFont.largeTitle.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(textAlignment)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !facts.isEmpty {
                Text(factLine)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(2)
                    // Read as a list, not with its dots.
                    .accessibilityLabel(facts.formatted(.list(type: .and, width: .narrow)))
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    /// The facts with a dimmer dot between each.
    private var factLine: AttributedString {
        var line = AttributedString()
        for (index, fact) in facts.enumerated() {
            if index > 0 {
                var dot = AttributedString(" · ")
                dot.foregroundColor = DSColor.textSecondary
                line += dot
            }
            line += AttributedString(fact)
        }
        return line
    }
}

/// The poster behind the hero: filling it from the top edge of the screen and faded out at its
/// foot, where the page's own colour shows through. Pulled down past the top of the page, it
/// grows from its bottom edge into the gap.
private struct VideoPosterBackdrop: View {
    let image: UIImage
    let fadesEarly: Bool

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            // Only a mask's opacity counts, so its colour is any opaque one.
            .mask { LinearGradient(stops: fadeStops, startPoint: .top, endPoint: .bottom) }
            .visualEffect { content, proxy in
                let pull = max(0, proxy.frame(in: .scrollView).minY)
                let height = max(proxy.size.height, 1)
                return content.scaleEffect((height + pull) / height, anchor: .bottom)
            }
            // Across the sensor housing's side of a phone on its side too, as the page is.
            .ignoresSafeArea(.container, edges: .horizontal)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Eased from opaque to clear: a straight ramp shows its two ends as bands.
    private var fadeStops: [Gradient.Stop] {
        let start = fadesEarly ? DSLayout.videoHeroStrongFadeStart : DSLayout.videoHeroFadeStart
        let end = fadesEarly ? DSLayout.videoHeroStrongFadeEnd : DSLayout.videoHeroFadeEnd
        let samples = 8
        return (0...samples).map { step in
            let t = Double(step) / Double(samples)
            let eased = t * t * (3 - 2 * t)
            return Gradient.Stop(color: .black.opacity(1 - eased), location: start + (end - start) * t)
        }
    }
}

#Preview("No artwork") {
    ScrollView {
        VideoDetailHero(poster: nil, title: "示範短劇", facts: ["主演 示範演員", "共 80 集", "都市", "短劇"]) {
            GeneratedBookCover(title: "示範短劇", author: nil)
        } actions: {
            Button(localized("開始播放"), systemImage: "play.fill") {}
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } intro: {
            Text("示範簡介：一部示範用的短劇。")
                .font(DSFont.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .background(CoverTint.placeholder.color)
    .environment(\.colorScheme, .dark)
}
