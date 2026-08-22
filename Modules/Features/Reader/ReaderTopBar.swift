import SwiftUI

struct ReaderTopBar: View {
    let theme: ReaderTheme
    let chapterTitle: String
    let titleVisible: Bool
    let titleSize: CGFloat
    let titleTopSpacing: CGFloat
    let titleBottomSpacing: CGFloat
    let isBookmarked: Bool
    let overlayMaxWidth: CGFloat
    let onBack: () -> Void
    let onToggleBookmark: () -> Void
    let onOpenBookDetail: (() -> Void)?

    @ObservedObject private var settings = GlobalSettings.shared

    private var palette: ReaderClassicChromePalette {
        ReaderClassicChromePalette(theme: theme, settings: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(DSFont.fixed(size: 17, weight: .medium))
                            .foregroundColor(palette.topIcon)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)   // 名稱在按鈕上（見 §7.1）
                    }
                    // Identifier moved off the Image with its accessibility: the UI test
                    // queries `app.buttons["reader_back_button"]`, so it has to live on the
                    // element that stays visible to accessibility.
                    .accessibilityIdentifier("reader_back_button")
                    .accessibilityLabel(localized("退出閱讀"))

                    if onOpenBookDetail != nil {
                        Color.clear
                            .frame(width: 36, height: 36)
                    }
                    
                    if titleVisible {
                        Text(chapterTitle)
                            .font(DSFont.fixed(size: titleSize, weight: .medium))
                            .foregroundColor(palette.topIcon)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    
                    Button {
                        onToggleBookmark()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(DSFont.fixed(size: 17, weight: .medium))
                            .foregroundColor(isBookmarked ? .orange : palette.topIcon)
                            .scaleEffect(isBookmarked ? 1.15 : 1.0)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                    }
                    .animation(.easeInOut(duration: 0.15), value: isBookmarked)
                    .accessibilityLabel(localized("書籤"))
                    .accessibilityValue(localized(isBookmarked ? "已加入" : "未加入"))

                    if let onOpenBookDetail {
                        Button {
                            onOpenBookDetail()
                        } label: {
                            Image(systemName: "ellipsis")
                                .rotationEffect(.degrees(90))
                                .font(DSFont.fixed(size: 17, weight: .medium))
                                .foregroundColor(palette.topIcon)
                                .frame(width: 36, height: 36)
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(localized("書籍詳情"))
                    }
                }
                .frame(maxWidth: overlayMaxWidth)
            }
            .padding(.horizontal, 12)
            .padding(.top, titleTopSpacing)
            .padding(.bottom, titleBottomSpacing)
            .background(palette.topFill)
            
            Divider().opacity(0.18)
            Spacer()
        }
    }
}
