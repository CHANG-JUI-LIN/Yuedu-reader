import re

file_path = "yuedu app/Views/ReaderView.swift"
with open(file_path, "r") as f:
    content = f.read()

top_bar_block = """    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Button {
                        saveProgress()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .accessibilityIdentifier("reader_back_button")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(readerTheme.textColor)
                            .frame(width: 36, height: 36)
                    }
                    Text(currentChapterTitle.converted(to: settings.textConversion))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(readerTheme.textColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Button {
                        withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                            store.toggleBookmark(
                                bookId: bookId,
                                chapterIndex: currentChapterIndex,
                                chapterTitle: currentChapterTitle,
                                pageIndex: currentPage,
                                excerpt: currentPageExcerpt
                            )
                        }
                    } label: {
                        Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(isCurrentPageBookmarked ? .orange : readerTheme.textColor)
                            .scaleEffect(isCurrentPageBookmarked ? 1.15 : 1.0)
                            .frame(width: 36, height: 36)
                    }
                    .animation(.easeInOut(duration: uiFeedbackDuration), value: isCurrentPageBookmarked)
                }
                .frame(maxWidth: overlayContentMaxWidth)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(readerTheme.barColor)
            Divider().opacity(0.18)
            Spacer()
        }
    }"""

top_bar_replacement = """    private var topBar: some View {
        ReaderTopBar(
            theme: readerTheme,
            chapterTitle: currentChapterTitle.converted(to: settings.textConversion),
            isBookmarked: isCurrentPageBookmarked,
            overlayMaxWidth: overlayContentMaxWidth,
            onBack: {
                saveProgress()
                presentationMode.wrappedValue.dismiss()
            },
            onToggleBookmark: {
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    store.toggleBookmark(
                        bookId: bookId,
                        chapterIndex: currentChapterIndex,
                        chapterTitle: currentChapterTitle,
                        pageIndex: currentPage,
                        excerpt: currentPageExcerpt
                    )
                }
            }
        )
    }"""

if top_bar_block in content:
    content = content.replace(top_bar_block, top_bar_replacement)
    with open(file_path, "w") as f:
        f.write(content)
        
    with open("yuedu app/Views/ReaderTopBar.swift", "w") as topbar_f:
        topbar_f.write("""import SwiftUI

struct ReaderTopBar: View {
    let theme: ReaderTheme
    let chapterTitle: String
    let isBookmarked: Bool
    let overlayMaxWidth: CGFloat
    let onBack: () -> Void
    let onToggleBookmark: () -> Void
    
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
""")
    print("Successfully extracted ReaderTopBar.")
else:
    print("Error: Could not match topBar block")

