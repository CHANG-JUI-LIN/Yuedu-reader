import Foundation

enum ReaderHTMLUtilities {
    static func paragraphs(fromPlainText text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"[ \t\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let explicitParagraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard explicitParagraphs.count <= 1,
              let onlyParagraph = explicitParagraphs.first,
              onlyParagraph.count >= 420 else {
            return explicitParagraphs
        }

        return sentenceChunks(from: onlyParagraph)
    }

    static func normalizedChapterHTML(
        title: String,
        paragraphs: [String],
        language: String = "zh-Hant"
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedTitle = escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading =
            trimmedTitle.isEmpty
            ? ""
            : "<h1>\(escapeHTML(trimmedTitle))</h1>\n"
        let body = paragraphs.enumerated()
            .map { _, paragraph in
                "<p>\(escapeHTML(paragraph))</p>"
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escapedTitle)</title>
        </head>
        <body>
        <article id="reader-content">
        \(heading)\(body)
        </article>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }

    private static func sentenceChunks(from text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let strongBreaks = Set("。！？!?；;")
        let weakBreaks = Set("，,、")

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
        }

        for character in text {
            current.append(character)
            if strongBreaks.contains(character), current.count >= 180 {
                flush()
            } else if weakBreaks.contains(character), current.count >= 260 {
                flush()
            } else if current.count >= 360 {
                flush()
            }
        }

        flush()
        return chunks.isEmpty ? [text] : chunks
    }
}
