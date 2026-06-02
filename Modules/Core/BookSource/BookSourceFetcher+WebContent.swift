import Foundation

// MARK: - Web Content Fetching Without Book Source (for browser-imported books)

extension BookSourceFetcher {

    /// Fetch page body content for any URL, without relying on book source rules (aligns with Legado BackstageWebView dynamic extraction).
    /// Prefers native HTTP fetch + SwiftSoup heuristics (text density), falling back to WebView on failure.
    /// Automatically follows "next page" links and merges multiple pages to complete chapter content.
    func fetchWebContent(
        url: String,
        referer: String? = nil,
        onFirstPageReady: ((String) -> Void)? = nil
    ) async throws -> String {
        guard let pageURL = URL(string: url) else { throw FetchError.invalidURL(url) }

        // Strategy 1: URLSession direct fetch + local parsing (On-Device Parsing)
        let base = referer ?? pageURL.absoluteString
        var fullContent = ""
        var currentURL = url
        var pageCount = 0
        let maxPages = 10

        repeat {
            guard let thisURL = URL(string: currentURL) else { break }
            let html: String
            do {
                html = try await fetchHTML(
                    url: thisURL,
                    method: "GET",
                    body: nil,
                    headers: referer != nil ? ["Referer": referer!] : [:],
                    baseURL: base,
                    allowInteractiveChallengeOn503: false
                )
            } catch {
                break
            }

            let pageContent = await ChapterFetcher.shared.extractWebContentSinglePage(
                html: html, pageURL: currentURL)
            let trimmedPageContent = pageContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if pageCount == 0, !trimmedPageContent.isEmpty {
                onFirstPageReady?(ChapterFetcher.shared.cleanChapterContent(trimmedPageContent))
            }
            if fullContent.isEmpty {
                fullContent = pageContent
            } else {
                if trimmedPageContent.count > 50 {
                    fullContent += "\n\n" + trimmedPageContent
                }
            }

            pageCount += 1
            guard pageCount < maxPages else { break }
            currentURL = WebNovelParser.extractNextPageURL(
                html: html,
                currentURL: currentURL
            )
        } while !currentURL.isEmpty

        let cleanedDirect = ChapterFetcher.shared.cleanChapterContent(fullContent)
        if !cleanedDirect.isEmpty {
            return cleanedDirect
        }

        // Strategy 2: fallback to WebView (anti-crawler/JS sites)
        do {
            let headers = referer != nil ? ["Referer": referer!] : [String: String]()
            let text = try await WebViewFetcher.shared.fetchWebContentViaJS(
                url: pageURL,
                headers: headers,
                timeout: 20,
                jsWait: 1.5
            )
            if !text.isEmpty {
                let cleaned = ChapterFetcher.shared.cleanChapterContent(text)
                return cleaned.isEmpty ? text : cleaned
            }
        } catch {
        }

        throw FetchError.emptyContent
    }
}
