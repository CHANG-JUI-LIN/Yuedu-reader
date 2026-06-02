import SwiftUI

/// Remote book cover with the headers source CDNs need, falling back to the
/// app's title-card placeholder when there's no cover (or it fails to load).
///
/// Fills whatever frame the caller gives it (`scaledToFill`, clipped). Apply the
/// frame + `clipShape` outside:
/// ```swift
/// BookCoverImage(onlineBook: book)
///     .frame(width: 104, height: 138)
///     .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
/// ```
struct BookCoverImage: View {
    let coverURL: String
    let title: String
    var sourceBaseURL: String?
    var sourceHeaders: [String: String]

    @State private var image: UIImage?

    init(
        coverURL: String,
        title: String,
        sourceBaseURL: String? = nil,
        sourceHeaders: [String: String] = [:]
    ) {
        self.coverURL = coverURL
        self.title = title
        self.sourceBaseURL = sourceBaseURL
        self.sourceHeaders = sourceHeaders
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                TitleCardPlaceholder(title: title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: coverURL) { await load() }
    }

    private func load() async {
        if let cached = BookCoverLoader.cachedImage(for: coverURL) {
            await MainActor.run { image = cached }
            return
        }
        await MainActor.run { image = nil }  // avoid showing a reused cell's old cover
        let headers = BookCoverLoader.headers(sourceBaseURL: sourceBaseURL, sourceHeaders: sourceHeaders)
        let loaded = await BookCoverLoader.loadImage(urlString: coverURL, headers: headers)
        await MainActor.run { image = loaded }
    }
}

extension BookCoverImage {
    /// Convenience for online/discover books — resolves the source's base URL and
    /// header rule from `BookSourceStore` so covers carry the right Referer/UA.
    @MainActor
    init(onlineBook: OnlineBook) {
        let source = BookSourceStore.shared.sources.first { $0.id == onlineBook.sourceId }
        self.init(
            coverURL: onlineBook.coverUrl,
            title: onlineBook.name,
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
    }
}

/// The shared no-cover placeholder: title text on a neutral card, matching the
/// bookshelf. Used wherever a cover is missing.
struct TitleCardPlaceholder: View {
    let title: String

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .padding(8)
            }
    }
}

#Preview {
    HStack(spacing: 16) {
        BookCoverImage(coverURL: "", title: "劍燭大荒")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        TitleCardPlaceholder(title: "宿命之環")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }
    .padding()
}
