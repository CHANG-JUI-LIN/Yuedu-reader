import Foundation

struct TXTBookMetadata: Equatable, Sendable {
    let title: String
    let author: String?
}

enum TXTMetadataProbe {
    static let maximumSampleBytes = 128 * 1024
    static let maximumMetadataCharacters = 3_000

    static func probe(url: URL, fallbackTitle: String) throws -> TXTBookMetadata {
        let prefix = try TXTFileReader.readPrefix(
            url: url,
            maxByteCount: maximumSampleBytes
        )
        return infer(from: prefix, fallbackTitle: fallbackTitle)
    }

    static func infer(from prefix: String, fallbackTitle: String) -> TXTBookMetadata {
        let sample = String(prefix.prefix(maximumMetadataCharacters))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let fallback = cleaned(fallbackTitle, maximumLength: 120) ?? fallbackTitle

        let explicitTitle = firstCapture(
            in: sample,
            patterns: [
                #"(?im)^\s*(?:書名|书名|作品名|作品名稱|作品名称|Title)\s*[：:﹕]\s*(.{1,80}?)\s*$"#
            ],
            maximumLength: 80
        )
        let explicitAuthor = firstCapture(
            in: sample,
            patterns: [
                #"(?im)^\s*(?:作者|著者|著)\s*[：:﹕]\s*([^\n，,。！？]{1,40}?)\s*$"#,
                #"(?im)^\s*Author\s*[：:]\s*([^\n,.;!?]{1,60}?)\s*$"#,
                #"(?im)^\s*Written\s+by\s*[：:]?\s*([^\n,.;!?]{1,60}?)\s*$"#
            ],
            maximumLength: 60
        )

        let standaloneCredit = standaloneAuthorCredit(in: sample)
        let inferredTitle = explicitTitle
            ?? standaloneCredit.flatMap { titleBeforeAuthorCredit(lines: $0.lines, authorLineIndex: $0.index) }
        let inferredAuthor = explicitAuthor ?? standaloneCredit?.author

        return TXTBookMetadata(
            title: inferredTitle ?? fallback,
            author: inferredAuthor
        )
    }

    private static func firstCapture(
        in text: String,
        patterns: [String],
        maximumLength: Int
    ) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text),
                  let candidate = cleaned(String(text[captureRange]), maximumLength: maximumLength)
            else { continue }
            return candidate
        }
        return nil
    }

    private static func standaloneAuthorCredit(
        in text: String
    ) -> (author: String, lines: [String], index: Int)? {
        let lines = text.components(separatedBy: "\n")
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*([^\n，,。！？：:]{1,30}?)\s+著\s*$"#
        ) else { return nil }

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: line),
                  let author = cleaned(String(line[captureRange]), maximumLength: 30)
            else { continue }
            return (author, lines, index)
        }
        return nil
    }

    private static func titleBeforeAuthorCredit(lines: [String], authorLineIndex: Int) -> String? {
        guard authorLineIndex > 0 else { return nil }
        for line in lines[..<authorLineIndex].reversed() {
            guard let candidate = cleaned(line, maximumLength: 60) else { continue }
            if candidate.range(
                of: #"^(?:第.{0,20}[章卷回部]|Chapter\s+\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                continue
            }
            if candidate.range(of: #"[。！？!?]$"#, options: .regularExpression) != nil {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func cleaned(_ raw: String, maximumLength: Int) -> String? {
        let wrappers = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "《》〈〉「」『』\"'“”‘’")
        )
        let value = raw.trimmingCharacters(in: wrappers)
        guard !value.isEmpty, value.count <= maximumLength else { return nil }
        return value
    }
}
