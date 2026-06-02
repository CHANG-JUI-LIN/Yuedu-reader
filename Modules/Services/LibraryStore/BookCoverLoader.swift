import UIKit

/// Loads and caches remote book covers, applying the headers many book-source
/// CDNs require (browser `User-Agent` + `Referer`) — `AsyncImage` sends neither,
/// which is why hotlink-protected source covers came back blank.
///
/// Also used at add-to-shelf time to persist a cover to disk (`downloadAndSave`).
enum BookCoverLoader {

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 250
        return c
    }()

    /// Headers for a cover request: browser UA + Referer (the source's base URL),
    /// with the source's own header rule layered on top (it may override the UA).
    static func headers(sourceBaseURL: String?, sourceHeaders: [String: String]) -> [String: String] {
        var result: [String: String] = ["User-Agent": defaultUserAgent]
        if let base = sourceBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            result["Referer"] = base
        }
        for (key, value) in sourceHeaders { result[key] = value }
        return result
    }

    static func cachedImage(for urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    /// Fetch a cover image, honoring the in-memory cache and the supplied headers.
    static func loadImage(urlString: String, headers: [String: String]) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        if let cached = cache.object(forKey: trimmed as NSString) { return cached }

        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = UIImage(data: data) else { return nil }

        cache.setObject(image, forKey: trimmed as NSString)
        return image
    }

    /// Download a cover and save it as JPEG under Documents; returns the saved
    /// filename (to store in `ReadingBook.coverImagePath`) or nil on failure.
    static func downloadAndSave(
        urlString: String,
        headers: [String: String],
        filename: String
    ) async -> String? {
        guard let image = await loadImage(urlString: urlString, headers: headers),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        do {
            try jpeg.write(to: fileURL)
            return filename
        } catch {
            return nil
        }
    }
}
