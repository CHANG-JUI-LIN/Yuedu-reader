import SwiftUI
import UIKit

/// Content of the popover 現代 hangs off the cover thumbnail in its toolbar: the book's
/// identity on top (tap it to open the detail page) and the actions underneath —
/// 搜尋書籍 plus the book-scoped `ReaderView.readerSecondaryActions` list
/// (刷新 / 換源 / 下載 / 聽書 / AI …) Apple Books renders in its own menu.
///
/// Two levels, not one slab: the identity sits on its own inset surface and the actions
/// sit directly on the card. The card was a single flat rectangle before, with the whole
/// thing reading as one undifferentiated block.
///
/// The popover supplies the shape, the arrow and the shadow; the surface comes from
/// 界面效果 through `presentationBackground` at the call site, so on iOS 26 the card
/// is the same Liquid Glass as the 現代 bottom bar below it and 自定義's `panelFill`
/// is what shows through as 透明度 drops. The card itself paints no fill — an opaque
/// background here would sit on top of that surface and hide it, which is what made
/// the card read as a flat slab over a glass toolbar. The inset behind the identity is
/// a tint of the panel's own text colour for the same reason: it lifts on a light card
/// and on a dark one without either assuming an opaque fill. Local books have no detail
/// page, so `onOpenDetail` is nil for them and the identity block isn't tappable.
struct ReaderModernBookCard: View {
    let coverImage: UIImage?
    let bookTitle: String
    let author: String
    let formatText: String
    let progressText: String
    let actions: [ReaderSecondaryAction]
    let palette: ReaderChromePalette

    /// Width of the reader the popover hangs over; the card insets from it rather than
    /// taking a fixed width. See `DSLayout.readerModernBookCardWidth(viewportWidth:)`.
    let availableWidth: CGFloat

    /// 搜尋書籍 — always the first cell of the action grid. Book-scoped actions come and
    /// go with the book and 自定義's roster; whole-book search applies to every book, so
    /// it is its own entry rather than a `ReaderSecondaryAction`.
    let onOpenSearch: () -> Void

    let onOpenDetail: (() -> Void)?

    @Bindable private var settings = GlobalSettings.shared

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            identityBlock
            actionBlock
        }
        .padding(DSSpacing.md)
        .frame(width: DSLayout.readerModernBookCardWidth(viewportWidth: availableWidth))
        .foregroundStyle(palette.panelText)
    }

    @ViewBuilder
    private var identityBlock: some View {
        if let onOpenDetail {
            Button(action: onOpenDetail) {
                identityContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(author.isEmpty ? bookTitle : "\(bookTitle), \(author)")
            .accessibilityHint(localized("作品詳情"))
        } else {
            identityContent
                .accessibilityElement(children: .combine)
        }
    }

    private var identityContent: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            cover
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(bookTitle)
                    .font(DSFont.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !author.isEmpty {
                    Text(author)
                        .font(DSFont.subheadline)
                        .foregroundStyle(palette.panelText.opacity(0.62))
                        .lineLimit(1)
                }
                // Stacked, not side by side. Two capsules sharing one line had to fit
                // 格式 and 進度 into half the column each, and truncated both of their
                // labels — 「For… EPUB」 next to 「Progr… 1 / 1…」.
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    chip(icon: "doc", title: localized("格式"), value: formatText)
                    chip(icon: "chart.bar", title: localized("進度"), value: progressText)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                .fill(palette.panelText.opacity(0.07))
        )
        .contentShape(Rectangle())
    }

    private var cover: some View {
        Group {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: bookTitle, author: author)
            }
        }
        .frame(
            width: DSLayout.readerModernBookCardCoverWidth,
            height: DSLayout.readerModernBookCardCoverHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    private func chip(icon: String, title: String, value: String) -> some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(palette.bottomAccent)
            Text(title)
                .foregroundStyle(palette.panelText.opacity(0.62))
            Text(value)
                .fontWeight(.medium)
        }
        .font(DSFont.caption)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.xs)
        .background(palette.panelText.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    /// One cell of the action block. 搜尋 is not a `ReaderSecondaryAction` — it has no
    /// book-scoped state and no entry in 自定義's icon roster — so the two sources are
    /// flattened into this before layout rather than branched inside it.
    private struct ActionCell: Identifiable {
        let id: String
        let label: String
        let isLocked: Bool
        /// The 自定義 entry whose imported icon replaces `fallbackIcon`, when there is one.
        let item: ReaderChromeActionItem?
        let fallbackIcon: String
        let action: () -> Void
    }

    private var cells: [ActionCell] {
        var cells = [
            ActionCell(
                id: "search",
                label: localized("Search Book"),
                isLocked: false,
                item: nil,
                fallbackIcon: "magnifyingglass",
                action: onOpenSearch
            )
        ]
        cells.append(contentsOf: actions.map { action in
            ActionCell(
                id: action.id.rawValue,
                label: action.label,
                isLocked: action.isLocked,
                item: ReaderChromeActionItem(action.id),
                fallbackIcon: action.icon,
                action: action.action
            )
        })
        return cells
    }

    /// Plain stacks, deliberately not a `LazyVGrid`. A popover takes its size from its
    /// content, and a lazy container measures as zero height on that first pass — the
    /// card presented empty and only filled in a layout pass or two later, which read
    /// as the card failing to open. There are at most eight cells here; nothing about
    /// them is worth deferring.
    private var actionBlock: some View {
        VStack(spacing: 0) {
            ForEach(Array(actionRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { cell in
                        actionCell(cell)
                    }
                    // Keeps a short last row's cells at the column width of the rows
                    // above instead of stretching them across the card.
                    if row.count < actionColumnCount {
                        ForEach(0..<(actionColumnCount - row.count), id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private var actionRows: [[ActionCell]] {
        stride(from: 0, to: cells.count, by: actionColumnCount).map { start in
            Array(cells[start..<min(start + actionColumnCount, cells.count)])
        }
    }

    /// One row past four entries would shave every cell below the width of its own
    /// label, so the count splits into two balanced rows instead.
    private var actionColumnCount: Int {
        let count = cells.count
        guard count > DSLayout.readerModernBookCardActionColumns else { return max(count, 1) }
        return min(
            DSLayout.readerModernBookCardActionColumns,
            Int((Double(count) / 2).rounded(.up))
        )
    }

    private func actionCell(_ cell: ActionCell) -> some View {
        Button(action: cell.action) {
            VStack(spacing: DSSpacing.xs) {
                actionGlyph(for: cell)
                    .frame(
                        width: DSLayout.readerModernBookCardActionGlyphSize,
                        height: DSLayout.readerModernBookCardActionGlyphSize
                    )
                    // Needs Pro: a lock on the icon, and the tap opens the paywall.
                    .overlay(alignment: .topTrailing) {
                        if cell.isLocked {
                            Image(systemName: "lock.fill")
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.accent)
                                .offset(x: DSSpacing.xs, y: -DSSpacing.xs)
                                .accessibilityHidden(true)
                        }
                    }
                // Two lines rather than a shrunk one: at four across, 「AI Translation」
                // does not fit on a single line in English and wrapping keeps it legible.
                Text(cell.label)
                    .font(DSFont.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DSSpacing.xs)
            .frame(
                maxWidth: .infinity,
                minHeight: DSLayout.readerModernBookCardActionHeight
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.label)
        .accessibilityValue(cell.isLocked ? localized("需要 Pro") : "")
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint. `fallback` is the live symbol `ReaderView`
    /// picked, which for 下載 changes with download state.
    @ViewBuilder
    private func actionGlyph(for cell: ActionCell) -> some View {
        if let item = cell.item, let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: cell.fallbackIcon)
                .imageScale(.large)
                .foregroundStyle(palette.bottomAccent)
        }
    }
}

#Preview("Modern Book Card") {
    ReaderModernBookCard(
        coverImage: nil,
        bookTitle: "红楼梦脂评汇校本-繁体竖排版",
        author: "脂砚斋",
        formatText: "EPUB",
        progressText: "9 / 92",
        actions: [
            ReaderSecondaryAction(id: .refresh, icon: "arrow.clockwise", label: "刷新", action: {}),
            ReaderSecondaryAction(
                id: .changeSource,
                icon: "arrow.left.and.right",
                label: "換源",
                action: {}
            ),
            ReaderSecondaryAction(id: .download, icon: "arrow.down.circle", label: "下載", action: {}),
            ReaderSecondaryAction(id: .playback, icon: "headphones", label: "聽書", action: {}),
            ReaderSecondaryAction(id: .aiAssistant, icon: "sparkles", label: "AI 助手", isLocked: true, action: {})
        ],
        palette: ReaderChromePalette(interface: .modern, theme: .sepia, settings: .shared),
        availableWidth: 440,
        onOpenSearch: {},
        onOpenDetail: {}
    )
    // The popover supplies this in the reader; the preview has to stand it in or the
    // card floats on nothing.
    .floatingSurface(
        in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous),
        fill: ReaderTheme.sepia.barColor
    )
    .padding()
}
