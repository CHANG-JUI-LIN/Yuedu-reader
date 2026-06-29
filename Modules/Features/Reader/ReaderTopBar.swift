import SwiftUI

struct ReaderTopBar: View {
    let theme: ReaderTheme
    let chapterTitle: String
    let isBookmarked: Bool
    let overlayMaxWidth: CGFloat
    let onBack: () -> Void
    let onToggleBookmark: () -> Void
    let onOpenBookDetail: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .accessibilityIdentifier("reader_back_button")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(theme.textColor)
                            .frame(width: 36, height: 36)
                    }

                    if onOpenBookDetail != nil {
                        Color.clear
                            .frame(width: 36, height: 36)
                    }
                    
                    Text(chapterTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.textColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    
                    Button {
                        onToggleBookmark()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(isBookmarked ? .orange : theme.textColor)
                            .scaleEffect(isBookmarked ? 1.15 : 1.0)
                            .frame(width: 36, height: 36)
                    }
                    // Wait, we need uiFeedbackDuration here, but since it's hardcoded externally often 0.15,
                    // we'll pass the animation from the parent block, so we just use normal animation here.
                    .animation(.easeInOut(duration: 0.15), value: isBookmarked)

                    if let onOpenBookDetail {
                        Button {
                            onOpenBookDetail()
                        } label: {
                            Image(systemName: "ellipsis")
                                .rotationEffect(.degrees(90))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(theme.textColor)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(localized("書籍詳情"))
                    }
                }
                .frame(maxWidth: overlayMaxWidth)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.barColor)
            
            Divider().opacity(0.18)
            Spacer()
        }
    }
}
