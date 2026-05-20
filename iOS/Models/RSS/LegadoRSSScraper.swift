import Foundation
import SwiftSoup

enum LegadoRSSScraper {
    struct ScrapedItem {
        let title: String
        let link: String
        let pubDate: Date?
        let description: String
        let contentHTML: String
        let author: String?
        let imageURL: String?
    }

    static func scrape(source: RSSSource) async throws -> [RSSItem] {
        guard let listRule = LegadoRuleParser.parseListRule(source.ruleArticles ?? "") else {
            throw ScraperError.invalidRule("ruleArticles")
        }

        let html = try await fetchHTML(url: source.url, headerJSON: source.header)
        let document = try SwiftSoup.parse(html, source.url)
        let articleElements = try document.select(listRule.cssSelector).array()

        guard !articleElements.isEmpty else {
            throw ScraperError.noArticlesFound
        }

        let titleRule = source.ruleTitle.flatMap { LegadoRuleParser.parseExtractRule($0) }
        let linkRule = source.ruleLink.flatMap { LegadoRuleParser.parseExtractRule($0) }
        let descRule = source.ruleDescription.flatMap { LegadoRuleParser.parseExtractRule($0) }
        let contentRule = source.ruleContent.flatMap { LegadoRuleParser.parseExtractRule($0) }
        let dateRule = source.rulePubDate.flatMap { LegadoRuleParser.parseExtractRule($0) }
        let imageRule = source.ruleImage.flatMap { LegadoRuleParser.parseExtractRule($0) }

        let baseURL = source.url
        let items: [RSSItem] = articleElements.compactMap { element in
            guard let title = extractText(from: element, rule: titleRule),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let link = extractAttrOrText(from: element, rule: linkRule, attr: "href"),
                  !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let resolvedLink = resolveURL(link, relativeTo: baseURL) ?? link
            let description = descRule.flatMap { extractText(from: element, rule: $0) } ?? ""
            let contentHTML = contentRule.flatMap { extractHTML(from: element, rule: $0) } ?? ""
            let pubDate = dateRule.flatMap { extractText(from: element, rule: $0) }.flatMap { parseDate($0) }
            let author: String? = nil
            let imageURL = imageRule.flatMap { extractText(from: element, rule: $0) }

            let finalDescription: String
            var finalContentHTML: String
            if !contentHTML.isEmpty {
                finalContentHTML = contentHTML
                finalDescription = description.isEmpty ? RSSContentSanitizer.summary(from: contentHTML) : description
            } else if !description.isEmpty {
                finalContentHTML = description
                finalDescription = RSSContentSanitizer.summary(from: description)
            } else {
                finalContentHTML = ""
                finalDescription = ""
            }

            if let imgURL = imageURL, !imgURL.isEmpty {
                let imgTag = "<img src=\"\(imgURL)\" style=\"max-width:100%;height:auto;margin-bottom:1em;\" />"
                finalContentHTML = imgTag + finalContentHTML
            }

            return RSSItem(
                id: resolvedLink,
                title: RSSContentSanitizer.cleanText(title),
                link: resolvedLink,
                pubDate: pubDate,
                description: finalDescription,
                contentHTML: finalContentHTML,
                author: author,
                imageURL: imageURL,
                sourceId: source.id
            )
        }

        return items
    }

    // MARK: - Private

    private static func extractText(from element: Element, rule: LegadoRule?) -> String? {
        guard let rule, let extractAttr = rule.extractAttribute else { return try? element.text() }
        do {
            let els = try element.select(rule.cssSelector).array()
            guard let first = els.first else { return nil }
            switch extractAttr {
            case "text": return try first.text()
            case "html": return try first.html()
            case "ownText": return first.ownText()
            default: return try first.attr(extractAttr)
            }
        } catch {
            return nil
        }
    }

    private static func extractAttrOrText(from element: Element, rule: LegadoRule?, attr defaultAttr: String) -> String? {
        guard let rule else {
            return (try? element.attr(defaultAttr)) ?? (try? element.text())
        }
        guard let extractAttr = rule.extractAttribute else { return (try? element.attr(defaultAttr)) ?? (try? element.text()) }
        do {
            let els = try element.select(rule.cssSelector).array()
            guard let first = els.first else { return nil }
            switch extractAttr {
            case "text": return try first.text()
            case "html": return try first.html()
            default: return try first.attr(extractAttr)
            }
        } catch {
            return nil
        }
    }

    private static func extractHTML(from element: Element, rule: LegadoRule?) -> String? {
        guard let rule else { return try? element.html() }
        guard let extractAttr = rule.extractAttribute else { return try? element.html() }
        do {
            let els = try element.select(rule.cssSelector).array()
            guard let first = els.first else { return nil }
            switch extractAttr {
            case "html", "all": return try first.html()
            case "text": return try first.text()
            case "ownText": return first.ownText()
            default: return try first.html()
            }
        } catch {
            return nil
        }
    }

    private static func fetchHTML(url: String, headerJSON: String?) async throws -> String {
        guard let requestURL = URL(string: url)?.upgradedToHTTPS() else {
            throw ScraperError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let headerJSON, let headerData = headerJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headerData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (Linux; Android 8.1.0; zh-CN) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/78.0.3904.108 Mobile Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ScraperError.httpError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ScraperError.encodingError
        }
        return html
    }

    private static func resolveURL(_ link: String, relativeTo baseURL: String) -> String? {
        guard let base = URL(string: baseURL) else { return nil }
        if let url = URL(string: link), url.scheme != nil {
            return url.absoluteString
        }
        return URL(string: link, relativeTo: base)?.absoluteURL.absoluteString
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
            "dd/MM/yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return nil
    }
}

enum ScraperError: LocalizedError {
    case invalidURL
    case invalidRule(String)
    case httpError
    case encodingError
    case noArticlesFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return localized("RSS URL 無效")
        case .invalidRule(let name):
            return String(format: localized("規則 %@ 格式無效"), name)
        case .httpError:
            return localized("HTTP 請求失敗")
        case .encodingError:
            return localized("網頁編碼錯誤")
        case .noArticlesFound:
            return localized("沒有找到文章")
        }
    }
}
