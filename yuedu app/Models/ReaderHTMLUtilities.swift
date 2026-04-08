import Foundation

enum ReaderHTMLUtilities {
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
}
