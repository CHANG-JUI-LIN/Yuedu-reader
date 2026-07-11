import SwiftUI
import UIKit
import CryptoKit

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
                    .font(DSFont.fixed(size: size * 0.48, weight: .semibold))
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

    // On-disk persistence so favicons survive app relaunch.
    private let directory: URL
    private let resolvedMapURL: URL
    private let missingMapURL: URL
    private var resolvedMap: [String: String] // sourceKey: winning favicon URL string
    private var missingMap: [String: Double] // sourceKey: epoch seconds when marked as having no favicon

    // Sources with no favicon are re-checked after this interval, so a transient
    // network failure doesn't permanently suppress an icon.
    private let missingRetryInterval: TimeInterval = 7 * 24 * 60 * 60

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("RSSFavicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        resolvedMapURL = dir.appendingPathComponent("resolved-urls.json")
        missingMapURL = dir.appendingPathComponent("missing-favicons.json")
        if let data = try? Data(contentsOf: resolvedMapURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            resolvedMap = map
        } else {
            resolvedMap = [:]
        }
        if let data = try? Data(contentsOf: missingMapURL),
           let map = try? JSONDecoder().decode([String: Double].self, from: data) {
            missingMap = map
        } else {
            missingMap = [:]
        }
    }

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
        if let markedAt = missingMap[sourceKey],
           Date().timeIntervalSince1970 - markedAt < missingRetryInterval {
            return nil
        }

        // Fast path: a previous run already resolved which URL wins for this source,
        // so skip the homepage HTML fetch in candidateURLs entirely.
        if let resolved = resolvedMap[sourceKey] {
            if let image = loadFromMemoryOrDisk(urlKey: resolved) {
                imageCache[sourceKey] = image
                return image
            }
            if let url = URL(string: resolved), let image = await downloadImage(from: url) {
                store(image, urlKey: resolved, sourceKey: sourceKey)
                return image
            }
            resolvedMap[sourceKey] = nil // stale; fall through and re-resolve
            persistResolvedMap()
        }

        let candidates = await RSSFaviconResolver.candidateURLs(for: source)
        for url in candidates {
            let urlKey = url.absoluteString
            if let image = loadFromMemoryOrDisk(urlKey: urlKey) {
                store(image, urlKey: urlKey, sourceKey: sourceKey)
                return image
            }

            guard let image = await downloadImage(from: url) else {
                continue
            }

            store(image, urlKey: urlKey, sourceKey: sourceKey)
            return image
        }

        missingMap[sourceKey] = Date().timeIntervalSince1970
        persistMissingMap()
        return nil
    }

    private func store(_ image: UIImage, urlKey: String, sourceKey: String) {
        imageCache[urlKey] = image
        imageCache[sourceKey] = image
        if missingMap[sourceKey] != nil {
            missingMap[sourceKey] = nil
            persistMissingMap()
        }
        if resolvedMap[sourceKey] != urlKey {
            resolvedMap[sourceKey] = urlKey
            persistResolvedMap()
        }
    }

    private func loadFromMemoryOrDisk(urlKey: String) -> UIImage? {
        if let cached = imageCache[urlKey] {
            return cached
        }
        let fileURL = directory.appendingPathComponent(diskKey(for: urlKey))
        guard let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) else {
            return nil
        }
        imageCache[urlKey] = image
        return image
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
            guard let image = UIImage(data: data) else {
                return nil
            }
            try? data.write(to: directory.appendingPathComponent(diskKey(for: url.absoluteString)))
            return image
        } catch {
            return nil
        }
    }

    private func diskKey(for urlString: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(urlString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistResolvedMap() {
        guard let data = try? JSONEncoder().encode(resolvedMap) else { return }
        try? data.write(to: resolvedMapURL)
    }

    private func persistMissingMap() {
        guard let data = try? JSONEncoder().encode(missingMap) else { return }
        try? data.write(to: missingMapURL)
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
