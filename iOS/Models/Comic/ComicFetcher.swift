import Combine
import Foundation
import SwiftSoup

@MainActor
final class ComicFetcher: ObservableObject {
    @Published var imageUrls: [String] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    func fetchImages(chapterUrl: String, source: BookSource) async {
        isLoading = true
        error = nil
        imageUrls = []

        do {
            let html = try await fetchHTML(urlString: chapterUrl, source: source)
            let urls = await extractImageUrls(from: html, baseUrl: chapterUrl, source: source)
            imageUrls = urls
            if urls.isEmpty {
                error = "未找到圖片"
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Private helpers

    private func fetchHTML(urlString: String, source: BookSource) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let headers = parseHeaders(source.header)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
        }
        let (data, response) = try await URLSession.shared.data(for: request)

        // Respect server-declared charset; default to UTF-8
        var encoding: String.Encoding = .utf8
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            let lower = contentType.lowercased()
            if lower.contains("gb2312") || lower.contains("gbk") || lower.contains("gb18030") {
                let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            }
        }
        return String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private func extractImageUrls(from html: String, baseUrl: String, source: BookSource) async -> [String] {
        let rule = source.ruleContent.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Run CSS/SwiftSoup work off the main thread to avoid blocking UI
        let rawResult = await Task.detached(priority: .userInitiated) {
            rule.isEmpty ? "" : Self.applyContentRule(rule: rule, html: html, baseUrl: baseUrl)
        }.value

        // Strategy 1: result is a JSON array of URL strings
        if !rawResult.isEmpty,
           let data = rawResult.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            let urls = arr.filter { $0.lowercased().hasPrefix("http") }
            if !urls.isEmpty { return urls }
        }

        // Strategy 2: result is newline-separated URL strings
        if !rawResult.isEmpty {
            let lines = rawResult
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.lowercased().hasPrefix("http") }
            if !lines.isEmpty { return lines }
        }

        // Strategy 3: Fall back to SwiftSoup img src scan of the raw HTML page
        return await Task.detached(priority: .userInitiated) {
            guard let doc = try? SwiftSoup.parse(html) else { return [] }
            let imgs = (try? doc.select("img")) ?? Elements()
            return imgs.compactMap { img -> String? in
                let dataSrc = (try? img.attr("data-src")) ?? ""
                let src = (try? img.attr("src")) ?? ""
                let candidate = dataSrc.isEmpty ? src : dataSrc
                return candidate.lowercased().hasPrefix("http") ? candidate : nil
            }
        }.value
    }

    /// Applies a simple Legado-style CSS selector rule (e.g. `"img@src"` or `"div.page img@data-src"`)
    /// and returns newline-joined extracted values.
    private nonisolated static func applyContentRule(rule: String, html: String, baseUrl: String) -> String {
        guard let document = try? SwiftSoup.parse(html, baseUrl) else { return "" }

        // Split on "@" to separate selector from attribute name
        let parts = rule.components(separatedBy: "@")
        let selector = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let attribute = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : "src"

        guard !selector.isEmpty,
              let elements = try? document.select(selector),
              !elements.isEmpty() else { return "" }

        return elements.compactMap { el -> String? in
            let value: String
            if attribute == "text" || attribute == "TEXT" {
                value = (try? el.text()) ?? ""
            } else {
                // Prefer data-{attr} (lazy-loading) over the direct attribute
                let lazy = (try? el.attr("data-\(attribute)")) ?? ""
                let direct = (try? el.attr(attribute)) ?? ""
                value = lazy.isEmpty ? direct : lazy
            }
            return value.isEmpty ? nil : value
        }.joined(separator: "\n")
    }

    private func parseHeaders(_ headerStr: String) -> [String: String] {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return json
        }
        // Fallback: "Key: Value" per line
        var result: [String: String] = [:]
        trimmed.components(separatedBy: "\n").forEach { line in
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}
