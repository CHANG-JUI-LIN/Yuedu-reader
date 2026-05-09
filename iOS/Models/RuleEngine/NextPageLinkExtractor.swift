import Foundation

struct NextPageLinkExtractor {
    static func extractNextPageURL(
        html: String,
        currentURL: String,
        baseURL: String,
        resolveURL: (String, String) -> String
    ) -> String {
        guard let baseUrlObj = URL(string: baseURL.isEmpty ? currentURL : baseURL) else {
            return ""
        }

        let linkRelNext = #"<link[^>]+rel=["']next["'][^>]+href=["']([^"']+)["']"#
        let linkHrefFirst = #"<link[^>]+href=["']([^"']+)["'][^>]+rel=["']next["']"#
        for pattern in [linkRelNext, linkHrefFirst] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: html)
            {
                let href = String(html[range]).trimmingCharacters(in: .whitespaces)
                if !href.isEmpty, !href.hasPrefix("javascript:") {
                    return resolveURL(href, baseUrlObj.absoluteString)
                }
            }
        }

        let hrefPattern =
            #"<a\s[^>]*href=["']([^"']+)["'][^>]*>[^<]*?(?:下一[頁页]|下一页|Next\s*Page|next\s*page)[^<]*</a>"#
        if let regex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: html)
        {
            let href = String(html[range]).trimmingCharacters(in: .whitespaces)
            if !href.isEmpty, !href.hasPrefix("javascript:") {
                return resolveURL(href, baseUrlObj.absoluteString)
            }
        }

        if let cur = URL(string: currentURL),
            let comp = URLComponents(url: cur, resolvingAgainstBaseURL: false),
            let queryItems = comp.queryItems
        {
            let pageParam = queryItems.first {
                $0.name.lowercased() == "page" || $0.name == "p" || $0.name == "index"
            }
            if let param = pageParam, let num = Int(param.value ?? ""), num >= 1 {
                let nextNum = String(num + 1)
                let pattern = "href=[\"']([^\"']*[?&](?:page|p|index)=" + nextNum + "[^\"']*)[\"']"
                if let regex = try? NSRegularExpression(pattern: pattern),
                    let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                    match.numberOfRanges > 1,
                    let range = Range(match.range(at: 1), in: html)
                {
                    let href = String(html[range]).trimmingCharacters(in: .whitespaces)
                    if !href.isEmpty {
                        return resolveURL(href, baseUrlObj.absoluteString)
                    }
                }
            }
        }

        return ""
    }
}
