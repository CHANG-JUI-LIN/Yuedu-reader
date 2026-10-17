import SwiftUI

// MARK: - 資源庫 cards

// 資源庫's entries (Phase 5 plan, 5h). The old 探索 root's 格狀 and 列表 choice, restored from
// before 5d-1b; each entry is a card as the maintainer's reference draws its media servers and
// modules (2026-10-13): a small square picture top leading, a count or a time top trailing,
// then the name, a line about it and a line of detail. A source has no picture of its own, so
// every source shows the same symbol, as the reference's modules do.

/// What a card shows in its square.
enum ExploreArtwork: Equatable {
    /// A library's or a page's symbol, in the theme's tint.
    case symbol(String)
    /// A symbol on grey, the same for every entry of its kind: a source, a group of sources.
    case neutral(String)

    /// Every source's picture (maintainer, 2026-10-13: one symbol for a source without one).
    static let source = ExploreArtwork.neutral("square.grid.2x2.fill")
}

/// How many cards share a row of the grid. Narrower cards drop their lower lines.
enum ExploreGridDensity: Int, CaseIterable, Identifiable, Comparable {
    case two = 2
    case three = 3
    case four = 4

    static let `default` = ExploreGridDensity.two

    var id: Int { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The density the reader chose, a column narrower as the text grows so a name
    /// still fits its card. Accessibility sizes don't use the grid at all.
    static func fitting(_ chosen: Int, dynamicTypeSize: DynamicTypeSize) -> ExploreGridDensity {
        let density = ExploreGridDensity(rawValue: chosen) ?? .default
        switch dynamicTypeSize {
        case .xLarge: return min(density, .three)
        case .xxLarge, .xxxLarge: return .two
        default: return density
        }
    }

    /// The lines under the name a card this wide has room for.
    var lineCount: Int {
        switch self {
        case .two: 2
        case .three: 1
        case .four: 0
        }
    }

    var padding: CGFloat { self == .four ? DSSpacing.sm : DSSpacing.md }
}

/// One entry, a card in the grid or a card across the page in the list.
struct ExploreEntryLabel: View {
    enum Layout: Equatable {
        case grid(ExploreGridDensity)
        case list
    }

    /// The card's top trailing corner.
    enum Corner: Equatable {
        /// A count in a small pill: RSS 訂閱's unread articles, a group's sources.
        case count(Int)
    }

    let title: String
    let artwork: ExploreArtwork
    let layout: Layout
    var subtitle: String?
    var detail: String?
    var corner: Corner?

    init(title: String, artwork: ExploreArtwork, layout: Layout,
         subtitle: String? = nil, detail: String? = nil, corner: Corner? = nil) {
        self.title = title
        self.artwork = artwork
        self.layout = layout
        self.subtitle = subtitle
        self.detail = detail
        self.corner = corner
    }

    /// A source's entry: its groups, and the site it reads.
    init(source: BookSource, layout: Layout) {
        let groups = DiscoverViewModel.groupNames(of: source)
        self.init(title: source.bookSourceName, artwork: .source, layout: layout,
                  subtitle: groups.isEmpty ? nil : groups.joined(separator: localized("、")),
                  detail: URL(string: source.bookSourceUrl)?.host())
    }

    /// How many lines under the name: what the card has room for in the grid, where every card
    /// of a row keeps them so the row lines up; only the lines it has in the list.
    private var lineCount: Int? {
        switch layout {
        case .grid(let density): density.lineCount
        case .list: nil
        }
    }

    private var padding: CGFloat {
        switch layout {
        case .grid(let density): density.padding
        case .list: DSSpacing.md
        }
    }

    @ScaledMetric(relativeTo: .headline) private var artworkSide = DSLayout.exploreCardArtworkSide
    @ScaledMetric(relativeTo: .headline) private var artworkSize = DSLayout.exploreCardArtworkSize

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                ExploreArtworkView(artwork: artwork, side: artworkSide, size: artworkSize)
                Spacer(minLength: 0)
                if let corner {
                    // Ahead of the spacer, which would otherwise split the width with it: in
                    // four columns a count of three digits then broke a digit to a line and
                    // stood its card taller than the row (maintainer, 2026-10-17).
                    ExploreEntryCorner(corner: corner)
                        .layoutPriority(1)
                }
            }
            .padding(.bottom, DSSpacing.sm)
            Text(title)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
            line(subtitle, at: 1, font: DSFont.subheadline, color: DSColor.textSecondary)
            line(detail, at: 2, font: DSFont.caption, color: DSColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .interfaceCardSurface(in: exploreEntryShape)
        .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
        .contentShape(exploreEntryShape)
        .contentShape(.contextMenuPreview, exploreEntryShape)
    }

    /// A line under the name. In the grid an empty one keeps its height, so the cards of a row
    /// end together.
    @ViewBuilder
    private func line(_ text: String?, at index: Int, font: Font, color: Color) -> some View {
        if let lineCount {
            if index <= lineCount {
                Text(text ?? " ")
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .accessibilityHidden(text == nil)
            }
        } else if let text {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

private var exploreEntryShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
}

// MARK: - Corner

/// A card's count or time. The entry's link says it to VoiceOver as its value, so it is hidden.
private struct ExploreEntryCorner: View {
    let corner: ExploreEntryLabel.Corner

    var body: some View {
        switch corner {
        case .count(let count):
            Text(count, format: .number)
                .font(DSFont.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, DSSpacing.xxs)
                .background(DSColor.neutralControlFill, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Artwork

/// The card's square: a library's symbol in the theme's tint on a tinted ground, or a
/// source's in the text colour on grey.
private struct ExploreArtworkView: View {
    let artwork: ExploreArtwork
    let side: CGFloat
    let size: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
    }

    var body: some View {
        Group {
            switch artwork {
            case .symbol(let name):
                Image(systemName: name)
                    .font(DSFont.fixed(size: size, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: side, height: side)
                    .background(DSColor.accentLight, in: shape)
            case .neutral(let name):
                Image(systemName: name)
                    .font(DSFont.fixed(size: size, weight: .semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .frame(width: side, height: side)
                    .background(DSColor.neutralControlFill, in: shape)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("資源庫 grid") {
    ScrollView {
        ForEach(ExploreGridDensity.allCases) { density in
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: density.rawValue),
                spacing: DSSpacing.md
            ) {
                ExploreEntryLabel(title: "Project Gutenberg", artwork: .symbol("building.columns"), layout: .grid(density),
                                  subtitle: "gutenberg.org")
                ExploreEntryLabel(title: "RSS 訂閱", artwork: .symbol("newspaper"), layout: .grid(density),
                                  subtitle: "12 個訂閱源", corner: .count(8))
                ExploreEntryLabel(title: "📚书山聚合", artwork: .source, layout: .grid(density),
                                  subtitle: "男频、精品", detail: "shushan.example")
                ExploreEntryLabel(title: "男频", artwork: .neutral("folder.fill"), layout: .grid(density), corner: .count(42))
            }
            .padding()
        }
    }
    .background(DSColor.groupedBackground)
}

#Preview("資源庫 list") {
    ScrollView {
        LazyVStack(spacing: DSSpacing.md) {
            ExploreEntryLabel(title: "RSS 訂閱", artwork: .symbol("newspaper"), layout: .list,
                              subtitle: "12 個訂閱源", corner: .count(8))
            ExploreEntryLabel(title: "📚书山聚合", artwork: .source, layout: .list,
                              subtitle: "男频、精品", detail: "shushan.example")
            ExploreEntryLabel(title: "番茄小说", artwork: .source, layout: .list)
        }
        .padding()
    }
    .background(DSColor.groupedBackground)
}
