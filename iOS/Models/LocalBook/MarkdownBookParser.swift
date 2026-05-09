import Foundation

struct MarkdownSection: Equatable {
    let headingLevel: Int?
    let title: String
    let body: String
}

enum MarkdownSectionParser {
    static func sections(from markdown: String, fallbackTitle: String) -> [MarkdownSection] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var sections: [MarkdownSection] = []
        var currentTitle = ""
        var currentHeadingLevel: Int? = nil
        var currentBody: [String] = []

        func flushCurrent() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentTitle.isEmpty || !body.isEmpty {
                let resolvedTitle = currentTitle.isEmpty
                    ? (sections.isEmpty ? fallbackTitle : "未命名章節")
                    : currentTitle
                sections.append(
                    MarkdownSection(
                        headingLevel: currentHeadingLevel,
                        title: resolvedTitle,
                        body: body
                    )
                )
            }
            currentTitle = ""
            currentHeadingLevel = nil
            currentBody.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashCount = trimmed.prefix(while: { $0 == "#" }).count
                if hashCount > 0 && hashCount <= 3 {
                    flushCurrent()
                    currentTitle = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    currentHeadingLevel = hashCount
                    continue
                }
            }
            currentBody.append(line)
        }

        flushCurrent()

        if sections.isEmpty {
            return [
                MarkdownSection(
                    headingLevel: nil,
                    title: fallbackTitle,
                    body: markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        }

        return sections
    }
}

struct MarkdownBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let markdown = try TXTFileReader.readTextFile(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let sections = MarkdownSectionParser.sections(from: markdown, fallbackTitle: fallbackTitle)

        let title = sections.first?.title ?? fallbackTitle
        let chapters = sections.map { section -> String in
            let trimmedTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.isEmpty { return trimmedBody }
            if trimmedBody.isEmpty { return trimmedTitle }
            return trimmedTitle + "\n" + trimmedBody
        }.filter { !$0.isEmpty }

        return ParsedBookDocument(
            title: title,
            author: "未知作者",
            chapters: chapters.isEmpty ? [markdown] : chapters
        )
    }
}