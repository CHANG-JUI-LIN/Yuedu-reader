import SwiftUI

/// Full-screen vertical-scroll comic/manga reader.
/// Presented for book sources with `bookSourceType == 2`.
struct ComicChapterReaderView: View {
    let chapter: OnlineChapterRef
    let source: BookSource

    @StateObject private var fetcher = ComicFetcher()
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showControls: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if fetcher.isLoading {
                loadingView
            } else if let errorMsg = fetcher.error {
                errorView(errorMsg)
            } else {
                contentScrollView
            }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .task {
            await fetcher.fetchImages(chapterUrl: chapter.url, source: source)
        }
    }

    // MARK: - Image scroll view

    private var contentScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(Array(fetcher.imageUrls.enumerated()), id: \.offset) { _, url in
                    AsyncImage(url: URL(string: url)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 100)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray)
                                )
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 200)
                                .overlay(ProgressView())
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .onTapGesture {
            withAnimation(DSAnimation.fast) {
                showControls.toggle()
            }
        }
    }

    // MARK: - Controls overlay (top + bottom bars)

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: back button + chapter title
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.sm) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                    }
                    Text(chapter.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
            }
            .background(.ultraThinMaterial)

            Spacer()

            // Bottom bar: page count
            VStack(spacing: 0) {
                Text(localized("共 \(fetcher.imageUrls.count) 頁"))
                    .font(DSFont.caption)
                    .foregroundColor(.white)
                    .padding(.vertical, DSSpacing.sm)
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - State views

    private var loadingView: some View {
        VStack(spacing: DSSpacing.md) {
            ProgressView()
                .tint(.white)
            Text(localized("載入中..."))
                .foregroundColor(.white)
                .font(DSFont.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DSSpacing.lg) {
            Text(message)
                .foregroundColor(.white)
                .font(DSFont.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(localized("重試")) {
                Task {
                    await fetcher.fetchImages(chapterUrl: chapter.url, source: source)
                }
            }
            .foregroundColor(DSColor.accent)
            .font(DSFont.bodyBold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
