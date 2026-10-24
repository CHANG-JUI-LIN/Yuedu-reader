import SwiftUI

// The tour's pictures. Each says again what its page says in words, so VoiceOver skips them.

/// 從探索找書: books of every kind side by side, the middle one in front. The covers are
/// `HomeLayoutSample`'s, which the app carries for the layout previews: a Japanese first
/// edition, a comic, a classic, a magazine and a Chinese first edition.
struct OnboardingCoverShelf: View {
    private static let covers = ["midaregami", "little-nemo", "pride-and-prejudice", "cocorico-1898", "panghuang"]

    static var books: [HomeLayoutSampleBook] {
        let samples = HomeLayoutSample.books.values.flatMap { $0 } + HomeLayoutSample.lists.flatMap(\.books)
        return covers.compactMap { cover in samples.first { $0.cover == cover } }
    }

    var body: some View {
        let books = Self.books
        let middle = books.count / 2
        HStack(spacing: -DSSpacing.md) {
            ForEach(Array(books.enumerated()), id: \.element.cover) { index, book in
                let distance = abs(index - middle)
                HomeCardCover(
                    cover: .reference(HomeLayoutSample.bundledCover(of: book), session: nil),
                    title: book.title,
                    author: book.author,
                    size: CGSize(width: DSLayout.onboardingCoverWidth, height: DSLayout.onboardingCoverHeight)
                )
                .scaleEffect(1 - CGFloat(distance) * DSLayout.onboardingCoverDepthScale, anchor: .bottom)
                .zIndex(Double(-distance))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 一部作品，一個頁面: one work in front of its other versions, with the count of places 搜尋
/// gives a work.
struct OnboardingWorkStack: View {
    /// The shelf's classic, the kind of book many places have.
    static let cover = "pride-and-prejudice"
    /// The work's versions, the one in front among them.
    private static let versions = 3

    var body: some View {
        let size = CGSize(width: DSLayout.onboardingWorkCoverWidth, height: DSLayout.onboardingWorkCoverHeight)
        let shape = RoundedRectangle(cornerRadius: DSRadius.searchListCover, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            // The deepest first, so the nearer ones are drawn over it.
            ForEach((1..<Self.versions).reversed(), id: \.self) { depth in
                let inset = CGFloat(depth) * DSLayout.onboardingWorkVersionStep
                shape
                    .fill(DSColor.surface)
                    .overlay(shape.strokeBorder(DSColor.separator, lineWidth: DSLayout.onboardingSketchBorderWidth))
                    .frame(width: size.width, height: size.height)
                    .shadow(color: DSColor.searchListCoverShadow, radius: DSLayout.searchListCoverShadowRadius,
                            y: DSLayout.searchListCoverShadowY)
                    .padding(.leading, inset)
                    .padding(.bottom, inset)
            }
            if let book = OnboardingCoverShelf.books.first(where: { $0.cover == Self.cover }) {
                HomeCardCover(
                    cover: .reference(HomeLayoutSample.bundledCover(of: book), session: nil),
                    title: book.title,
                    author: book.author,
                    size: size
                )
            }
        }
        // ProLockBadge's capsule, on the corner only the versions behind reach. The tint is
        // faint, so it lies on a card of its own: over the cover's art, the count went unread.
        .overlay(alignment: .topTrailing) {
            Text(String(format: localized("%d 源"), Self.versions))
                .font(DSFont.caption2.weight(.semibold))
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xxs)
                .background(DSColor.accentLight, in: Capsule())
                .background(DSColor.surface, in: Capsule())
                .foregroundStyle(DSColor.accent)
                .padding(DSSpacing.xxs)
        }
        .accessibilityHidden(true)
    }
}

/// 長時間閱讀也舒服: a page set across in 白色 and one set down in 棕色, its columns running
/// from the right.
struct OnboardingPageSketches: View {
    private static let lineFractions: [CGFloat] = [1, 0.92, 1, 0.84, 0.96, 0.6]

    var body: some View {
        HStack(spacing: DSSpacing.lg) {
            sketchPage(theme: .white) {
                VStack(alignment: .leading, spacing: DSLayout.onboardingSketchLineGap) {
                    ForEach(Self.lineFractions.indices, id: \.self) { index in
                        Capsule()
                            .frame(
                                width: DSLayout.onboardingSketchTextExtent * Self.lineFractions[index],
                                height: DSLayout.onboardingSketchLineThickness
                            )
                    }
                }
                .frame(width: DSLayout.onboardingSketchTextExtent, alignment: .leading)
            }
            sketchPage(theme: .sepia) {
                HStack(alignment: .top, spacing: DSLayout.onboardingSketchLineGap) {
                    ForEach(Self.lineFractions.indices, id: \.self) { index in
                        Capsule()
                            .frame(
                                width: DSLayout.onboardingSketchLineThickness,
                                height: DSLayout.onboardingSketchColumnExtent * Self.lineFractions[index]
                            )
                    }
                }
                // Vertical text starts at the right edge.
                .environment(\.layoutDirection, .rightToLeft)
                .frame(height: DSLayout.onboardingSketchColumnExtent, alignment: .top)
            }
        }
        .accessibilityHidden(true)
    }

    private func sketchPage<Lines: View>(theme: ReaderTheme, @ViewBuilder lines: () -> Lines) -> some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return lines()
            .foregroundStyle(theme.previewTextColor.opacity(DSLayout.onboardingSketchLineOpacity))
            .frame(width: DSLayout.onboardingSketchPageWidth, height: DSLayout.onboardingSketchPageHeight)
            .background(theme.previewBackgroundColor, in: shape)
            .overlay(shape.strokeBorder(DSColor.separator, lineWidth: DSLayout.onboardingSketchBorderWidth))
            .shadow(color: DSColor.searchListCoverShadow, radius: DSLayout.searchListCoverShadowRadius,
                    y: DSLayout.searchListCoverShadowY)
    }
}

#Preview("封面書架") {
    OnboardingCoverShelf()
        .padding()
}

#Preview("一部作品的版本") {
    OnboardingWorkStack()
        .padding()
}

#Preview("橫排與直排") {
    OnboardingPageSketches()
        .padding()
}
