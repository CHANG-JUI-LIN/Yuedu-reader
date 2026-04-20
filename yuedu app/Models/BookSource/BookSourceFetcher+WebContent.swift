import Foundation

// MARK: - 無書源網頁抓取（瀏覽器轉碼書使用）

extension BookSourceFetcher {

    /// 抓取任意 URL 的正文，不依賴書源規則（對齊 Legado BackstageWebView 動態提取）
    /// 優先用 App 端直接抓取 + SwiftSoup 啟發式（文本密度）→ 失敗才回退 WebView
    /// 會自動跟隨「下一頁」連結，合併多頁以補足章節內容。
    func fetchWebContent(
        url: String,
        referer: String? = nil,
        onFirstPageReady: ((String) -> Void)? = nil
    ) async throws -> String {
        guard let pageURL = URL(string: url) else { throw FetchError.invalidURL(url) }

        // 策略一：URLSession 直接抓取 + 本地解析（On-Device Parsing）
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

        // 策略二：回退 WebView（反爬/JS 站點）
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
