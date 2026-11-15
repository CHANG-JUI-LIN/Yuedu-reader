import SwiftUI

/// The paywall's picture: a small drawing of what the pillar feels like in use — a
/// question answered with its source, the page in other colours with dialogue as
/// bubbles, the page cut into tap zones, modules being added. Built from the reader's own themes and design
/// tokens, so it follows light and dark with the app.
///
/// Decorative: the headline next to it says the same thing in words, so VoiceOver skips it.
struct PaywallShowcase: View {
    let pillar: PremiumPillar

    var body: some View {
        Group {
            switch pillar {
            case .understanding: understanding
            case .comfort: comfort
            case .habits: habits
            case .modules: modules
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DSLayout.paywallShowcaseHeight)
        // A fixed-height drawing: past this size its words would spill out of it. The
        // headline beside it carries the meaning at every size.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }

    // MARK: - AI 讀懂一本書

    private var understanding: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Spacer(minLength: DSSpacing.xl)
                Text(localized("這段在說什麼？"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textOnAccent)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.accent, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            }
            Label(localized("AI 助手"), systemImage: "sparkles")
                .font(DSFont.caption.weight(.semibold))
                .foregroundStyle(DSColor.accent)
            textLine(widthRatio: 1)
            textLine(widthRatio: 0.86)
            HStack(spacing: DSSpacing.sm) {
                textLine(widthRatio: 0.55)
                Label(localized("原文出處"), systemImage: "text.quote")
                    .font(DSFont.caption2.weight(.semibold))
                    .foregroundStyle(DSColor.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, DSSpacing.xs / 2)
                    .background(DSColor.accentLight, in: Capsule())
                    .fixedSize()
            }
        }
        .padding(DSSpacing.lg)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    private func textLine(widthRatio: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(DSColor.textSecondary.opacity(0.28))
                .frame(width: proxy.size.width * widthRatio, height: DSSpacing.sm)
        }
        .frame(height: DSSpacing.sm)
    }

    // MARK: - 讀得更舒服

    private var comfort: some View {
        HStack(spacing: -DSSpacing.lg) {
            page(ReaderTheme.white)
                .rotationEffect(.degrees(-DSLayout.paywallShowcaseTiltDegrees))
            page(ReaderTheme.sepia, bubbles: true)
                .zIndex(1)
            page(ReaderTheme.night)
                .rotationEffect(.degrees(DSLayout.paywallShowcaseTiltDegrees))
        }
    }

    private func page(_ theme: ReaderTheme, bubbles: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            ForEach([1.0, 0.9, 0.95, 0.7] as [CGFloat], id: \.self) { ratio in
                pageLine(theme, widthRatio: ratio)
            }
            if bubbles {
                bubble(filled: false, theme: theme)
                bubble(filled: true, theme: theme)
            } else {
                ForEach([0.92, 0.8, 0.88] as [CGFloat], id: \.self) { ratio in
                    pageLine(theme, widthRatio: ratio)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.md)
        .frame(width: DSLayout.paywallShowcasePageWidth, height: DSLayout.paywallShowcaseHeight - DSSpacing.lg)
        .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .stroke(DSColor.separator, lineWidth: 0.5)
        )
    }

    private func pageLine(_ theme: ReaderTheme, widthRatio: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(theme.textColor.opacity(0.35))
                .frame(width: proxy.size.width * widthRatio, height: DSSpacing.xs)
        }
        .frame(height: DSSpacing.xs)
    }

    /// Dialogue as a chat bubble: the speaker's line on one side, the reply on the other.
    private func bubble(filled: Bool, theme: ReaderTheme) -> some View {
        HStack {
            if filled { Spacer(minLength: DSSpacing.lg) }
            Capsule()
                .fill(filled ? DSColor.accent.opacity(0.85) : theme.textColor.opacity(0.14))
                .frame(height: DSSpacing.md)
            if !filled { Spacer(minLength: DSSpacing.lg) }
        }
    }

    // MARK: - 照你的習慣讀

    private var habits: some View {
        let symbols: [String?] = [
            nil, "bookmark", nil,
            "chevron.left", "line.3.horizontal", "chevron.right",
            nil, "speaker.wave.2", nil,
        ]
        return VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { column in
                        let symbol = symbols[row * 3 + column]
                        ZStack {
                            Rectangle()
                                .fill(symbol == nil ? Color.clear : DSColor.accentLight)
                            Rectangle()
                                .strokeBorder(DSColor.accent.opacity(0.35),
                                              style: StrokeStyle(lineWidth: 1, dash: [DSSpacing.xs, DSSpacing.xs]))
                            if let symbol {
                                Image(systemName: symbol)
                                    .font(DSFont.headline)
                                    .foregroundStyle(DSColor.accent)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: DSLayout.paywallShowcaseGridWidth)
        .background(ReaderTheme.sepia.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .stroke(DSColor.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - 接上更多內容

private extension PaywallShowcase {
    /// Three modules in a list: two already in, one about to be added.
    var modules: some View {
        VStack(spacing: DSSpacing.sm) {
            moduleRow("books.vertical", widthRatio: 0.7, isAdded: true)
            moduleRow("magnifyingglass", widthRatio: 0.55, isAdded: true)
            moduleRow("text.bubble", widthRatio: 0.62, isAdded: false)
        }
        .padding(DSSpacing.lg)
        .frame(maxHeight: .infinity)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    func moduleRow(_ symbol: String, widthRatio: CGFloat, isAdded: Bool) -> some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: symbol)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.accent)
                .frame(width: DSSpacing.xl, height: DSSpacing.xl)
                .background(DSColor.accentLight, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            GeometryReader { proxy in
                Capsule()
                    .fill(DSColor.textSecondary.opacity(0.28))
                    .frame(width: proxy.size.width * widthRatio, height: DSSpacing.sm)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: DSSpacing.xl)
            Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(DSFont.headline)
                .foregroundStyle(isAdded ? DSColor.textSecondary : DSColor.accent)
        }
    }
}

#Preview("Paywall showcases") {
    ScrollView {
        VStack(spacing: DSSpacing.xl) {
            ForEach(PremiumPillar.allCases) { pillar in
                PaywallShowcase(pillar: pillar)
            }
        }
        .padding()
    }
    .softScrollEdges()
}
