import SwiftUI
import UIKit

/// Content of the popover 現代 hangs off the cover thumbnail in its toolbar:
/// the book's identity on top (tap it to open the detail page) and the book-scoped
/// actions underneath — 刷新 / 換源 / 下載 / 聽書, the same
/// `ReaderView.readerSecondaryActions` list Apple Books renders in its menu.
///
/// The popover supplies the shape, the arrow and the shadow; the surface comes from
/// 界面效果 through `presentationBackground` at the call site, so on iOS 26 the card
/// is the same Liquid Glass as the 現代 bottom bar below it and 自定義's `panelFill`
/// is what shows through as 透明度 drops. The card itself paints no fill — an opaque
/// background here would sit on top of that surface and hide it, which is what made
/// the card read as a flat slab over a glass toolbar. Local books have no detail
/// page, so `onOpenDetail` is nil for them and the identity block isn't tappable.
struct ReaderModernBookCard: View {
    let coverImage: UIImage?
    let bookTitle: String
    let author: String
    let formatText: String
    let progressText: String
    let actions: [ReaderSecondaryAction]
    let palette: ReaderChromePalette

    let onOpenDetail: (() -> Void)?

    @ObservedObject private var settings = GlobalSettings.shared

    /// Popovers size to their content; without a width the title would stretch the
    /// card to the full screen on a long book name.
    private let contentWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            identityBlock
            if !actions.isEmpty {
                Divider()
                actionRow
            }
        }
        .frame(width: contentWidth)
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
            .accessibilityHint(localized("書籍詳情"))
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
                    .font(DSFont.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !author.isEmpty {
                    Text(author)
                        .font(DSFont.caption)
                        .foregroundStyle(palette.panelText.opacity(0.62))
                        .lineLimit(1)
                }
                HStack(spacing: DSSpacing.sm) {
                    chip(icon: "doc", title: localized("格式"), value: formatText)
                    chip(icon: "chart.bar", title: localized("進度"), value: progressText)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.lg)
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
        .frame(width: 62, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    private func chip(icon: String, title: String, value: String) -> some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(title)
            Text(value)
                .fontWeight(.medium)
        }
        .font(DSFont.caption2)
        .foregroundStyle(palette.panelText.opacity(0.62))
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 4)
        .background(palette.panelText.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    VStack(spacing: 5) {
                        actionGlyph(for: ReaderChromeActionItem(action.id), fallback: action.icon)
                        Text(action.label)
                            .font(DSFont.caption2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.label)
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.bottom, DSSpacing.sm)
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint. `fallback` is the live symbol `ReaderView`
    /// picked, which for 下載 changes with download state.
    @ViewBuilder
    private func actionGlyph(for item: ReaderChromeActionItem, fallback: String) -> some View {
        if let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: fallback)
                .imageScale(.large)
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
            ReaderSecondaryAction(id: .playback, icon: "headphones", label: "聽書", action: {})
        ],
        palette: ReaderChromePalette(interface: .modern, theme: .sepia, settings: .shared),
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
