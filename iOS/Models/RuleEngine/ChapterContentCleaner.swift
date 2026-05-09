import Foundation

struct ChapterContentCleaner {
    static func cleanChapterContent(_ text: String, htmlToText: (String) -> String) -> String {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return raw }

        let removePatterns: [(String, String)] = [
            (#"本章未完，請點擊下一頁繼續閱讀"#, ""),
            (#"本章未完，请点击下一页继续阅读"#, ""),
            (#"請記住本書首發域名：[^\s]+\.(com|net|org|cn|cc|cx|pro)"#, ""),
            (#"请记住本书首发域名：[^\s]+\.(com|net|org|cn|cc|cx|pro)"#, ""),
            (#"請記住本站域名[^\n]*"#, ""),
            (#"请记住本站域名[^\n]*"#, ""),
        ]
        for (pattern, replacement) in removePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                raw = regex.stringByReplacingMatches(
                    in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: replacement
                )
            }
        }

        raw = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if raw.contains("<") {
            raw = htmlToText(raw)
        }

        var lines = raw.components(separatedBy: .newlines)
        let adPatterns: [String] = [
            #"請記住本站域名|请记住本站|記住本站|本站域名"#,
            #"支持正版閱讀|支援正版閱讀|請支持正版|請到.*訂閱本書"#,
            #"最新章節請到|防盜章節"#,
            #"一秒記住|一秒记住|一秒钟记住"#,
            #"chaptererror|chapter\s*error"#,
            #"最新網址|最新网址"#,
            #"^\s*https?://\S+\s*$"#,
            #"^[\s\u{3000}\.\-_\*]{0,5}$"#,
            #"^(上一章|下一章|上一頁|下一页|返回目錄|返回目录)\s*$"#,
        ]
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            for pattern in adPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                    regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
                {
                    return false
                }
            }
            return true
        }

        if let regex = try? NSRegularExpression(pattern: #"^(.{5,}?)\s{1,8}\1$"#) {
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 10 else { return line }
                if let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                    match.numberOfRanges > 1,
                    let range = Range(match.range(at: 1), in: trimmed)
                {
                    return String(trimmed[range])
                }
                return line
            }
        }

        let dateRegex = try? NSRegularExpression(pattern: #"^\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?$"#)
        let chapTitleRegex = try? NSRegularExpression(
            pattern: #"^第\s*[\d零一二三四五六七八九十百千萬万]+\s*[章回卷節节篇部]"#
        )
        var dropCount = 0
        for line in lines.prefix(15) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                dropCount += 1
                continue
            }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if dateRegex?.firstMatch(in: trimmed, range: range) != nil {
                dropCount += 1
                continue
            }
            if trimmed.hasPrefix("作者") || trimmed.hasPrefix("作 者") {
                dropCount += 1
                continue
            }
            if trimmed.count < 60, chapTitleRegex?.firstMatch(in: trimmed, range: range) != nil {
                dropCount += 1
                continue
            }
            break
        }
        if dropCount > 0 {
            lines = Array(lines.dropFirst(dropCount))
        }

        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if trimmed.count < 60 && trimmed.components(separatedBy: ">").count >= 3 { return false }
            if trimmed.count < 30 && trimmed.contains("收藏")
                && (trimmed.contains("目录") || trimmed.contains("目錄") || trimmed.contains("设置") || trimmed.contains("設置"))
            {
                return false
            }
            return true
        }

        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = result.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed != previous || trimmed.isEmpty {
                result.append(line)
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
