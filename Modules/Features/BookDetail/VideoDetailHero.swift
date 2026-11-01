import SwiftUI

/// The top of a video's detail page, as plezy lays out a show and Infuse and VidHub a series:
/// the poster fills the width from the top edge of the screen and fades into the page's own
/// background, light or dark, with the title, its facts and the buttons on the faded part,
/// centred (maintainer, 2026-11-01: 「海報顏色淡出…往下滑顏色就沒了…就是正常黑白色」).
///
/// A portrait poster stretched across a wide window would be cropped to a band, so there — an
/// iPad, a phone on its side — the poster stands beside the title over a blur of itself, as
/// plezy's wide hero keeps its column at the leading edge. On a phone the poster card stands
/// above the title until there is artwork: a generated cover drawn across the width would
/// print the title twice.
struct VideoDetailHero<Cover: View, Actions: View>: View {
    /// The source's artwork, once it has loaded; nil while it loads and when there is none.
    let poster: UIImage?
    let title: String
    let subtitle: String
    /// The episode count and the genres, as plezy's chips.
    let facts: [String]
    @ViewBuilder var cover: Cover
    @ViewBuilder var actions: Actions

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.bookDetailHeroBarInset) private var barInset
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Wide enough that a full-width portrait poster would be cut to a band.
    private var isWide: Bool { horizontalSizeClass == .regular || verticalSizeClass == .compact }

    /// The poster is gone before the text begins, so the text is on the page alone.
    private var fadesEarly: Bool {
        contrast == .increased || reduceTransparency || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        if isWide {
            beside
        } else {
            centred
        }
    }

    private var centred: some View {
        ZStack(alignment: .bottom) {
            if poster != nil {
                // The poster's height; the text grows the hero past it at the larger sizes.
                Color.clear
                    .containerRelativeFrame(.vertical) { length, _ in length * DSLayout.videoHeroHeightFraction }
            }
            VStack(spacing: DSSpacing.lg) {
                if poster == nil { posterCard(width: DSLayout.videoPosterWidth) }
                titleBlock(alignment: .center)
                actions
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.top, barInset + DSSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .background {
            if let poster {
                VideoPosterBackdrop(image: poster, isBlurred: false, fadesEarly: fadesEarly)
            }
        }
    }

    private var beside: some View {
        HStack(alignment: .bottom, spacing: DSSpacing.xl) {
            posterCard(width: DSLayout.videoPosterWideWidth)
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                titleBlock(alignment: .leading)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, barInset + DSSpacing.xl)
        .frame(maxWidth: .infinity)
        .background {
            if let poster, !reduceTransparency {
                VideoPosterBackdrop(image: poster, isBlurred: true, fadesEarly: fadesEarly)
            }
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
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(2)
            }
            if !facts.isEmpty {
                WrappingFlowLayout(spacing: DSSpacing.xs, alignment: alignment) {
                    ForEach(facts, id: \.self) { fact in
                        Text(fact)
                            .font(DSFont.caption.weight(.semibold))
                            .foregroundStyle(DSColor.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, DSSpacing.sm)
                            .padding(.vertical, DSSpacing.xxs)
                            .background(DSColor.neutralControlFill,
                                        in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// The poster behind the hero: filling it from the top edge of the screen, faded into the page
/// below it and dimmed under the bars above it, so their text and buttons read over a bright
/// poster. Pulled down past the top of the page, it grows from its bottom edge into the gap.
private struct VideoPosterBackdrop: View {
    let image: UIImage
    let isBlurred: Bool
    let fadesEarly: Bool

    @Environment(\.bookDetailHeroBarInset) private var barInset

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: isBlurred ? DSLayout.videoBackdropBlur : 0, opaque: true)
            }
            .clipped()
            // Only a mask's opacity counts, so its colour is any opaque one.
            .mask { LinearGradient(stops: fadeStops, startPoint: .top, endPoint: .bottom) }
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(DSLayout.videoHeroBarOpacity), .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: barInset)
                    Color.black
                }
            }
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
        VideoDetailHero(poster: nil, title: "示範短劇", subtitle: "主演 示範演員",
                        facts: ["共 80 集", "都市", "短劇"]) {
            GeneratedBookCover(title: "示範短劇", author: nil)
        } actions: {
            Button(localized("開始播放"), systemImage: "play.fill") {}
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}
