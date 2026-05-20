import SwiftUI
import UIKit

struct RSSFaviconView: View {
    let source: RSSSource
    var size: CGFloat = 28

    @State private var image: UIImage?
    @State private var loadKey = ""

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.18), style: .continuous))
        .task(id: faviconLoadKey) {
            await loadFavicon()
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: max(4, size * 0.18), style: .continuous)
            .fill(DSColor.accent.opacity(0.14))
            .overlay {
                Image(systemName: "newspaper")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundColor(DSColor.accent)
            }
    }

    private var faviconLoadKey: String {
        [
            source.id,
            source.url,
            source.homepageURL ?? "",
            source.displayFaviconURL ?? ""
        ].joined(separator: "|")
    }

    @MainActor
    private func loadFavicon() async {
        let key = faviconLoadKey
        guard loadKey != key else { return }
        loadKey = key
        image = nil
        image = await RSSFaviconImageLoader.shared.image(for: source)
    }
}

private actor RSSFaviconImageLoader {
    static let shared = RSSFaviconImageLoader()

    private var imageCache: [String: UIImage] = [:]
    private var missingCache = Set<String>()

    func image(for source: RSSSource) async -> UIImage? {
        let sourceKey = [
            source.id,
            source.url,
            source.homepageURL ?? "",
            source.displayFaviconURL ?? ""
        ].joined(separator: "|")

        if let cached = imageCache[sourceKey] {
            return cached
        }
        if missingCache.contains(sourceKey) {
            return nil
        }

        let candidates = await RSSFaviconResolver.candidateURLs(for: source)
        for url in candidates {
            let urlKey = url.absoluteString
            if let cached = imageCache[urlKey] {
                imageCache[sourceKey] = cached
                return cached
            }

            guard let image = await downloadImage(from: url) else {
                continue
            }

            imageCache[urlKey] = image
            imageCache[sourceKey] = image
            return image
        }

        missingCache.insert(sourceKey)
        return nil
    }

    private func downloadImage(from url: URL) async -> UIImage? {
        var request = URLRequest(url: url.upgradedToHTTPS())
        request.timeoutInterval = 10
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

#Preview {
    RSSFaviconView(source: RSSSource(
        name: "BBC",
        url: "https://feedx.net/rss/bbc.xml",
        homepageURL: "https://www.bbc.com",
        sortOrder: 0
    ))
    .padding()
}
