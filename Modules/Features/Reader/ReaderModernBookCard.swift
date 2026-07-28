import SwiftUI
import UIKit

/// Content of the popover 現代 hangs off the cover thumbnail in its toolbar:
/// the book's identity on top (tap it to open the detail page) and the book-scoped
/// actions underneath — 刷新 / 換源 / 下載 / 聽書, the same
/// `ReaderView.readerSecondaryActions` list Apple Books renders in its menu.
///
/// The popover supplies the surface, so nothing here paints a background or a shadow.
/// Local books have no detail page, so `onOpenDetail` is nil for them and the identity
/// block simply isn't tappable.
struct ReaderModernBookCard: View {
    let coverImage: UIImage?
    let bookTitle: String
    let author: String
    let formatText: String
    let progressText: String
    let actions: [ReaderSecondaryAction]

    let onOpenDetail: (() -> Void)?

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
                        .foregroundStyle(.secondary)
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
                TitleCardPlaceholder(title: bookTitle)
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
        .foregroundStyle(.secondary)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    VStack(spacing: 5) {
                        Label(action.label, systemImage: action.icon)
                            .labelStyle(.iconOnly)
                            .imageScale(.large)
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
        onOpenDetail: {}
    )
}
