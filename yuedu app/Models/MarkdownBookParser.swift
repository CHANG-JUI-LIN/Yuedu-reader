import Foundation

struct MarkdownBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let markdown = try TXTFileReader.readTextFile(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let sections = splitSections(from: markdown)

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

    private func splitSections(from markdown: String) -> [(title: String, body: String)] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var sections: [(title: String, body: String)] = []
        var currentTitle = ""
        var currentBody: [String] = []

        func flushCurrent() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentTitle.isEmpty || !body.isEmpty {
                sections.append((title: currentTitle, body: body))
            }
            currentBody.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashCount = trimmed.prefix(while: { $0 == "#" }).count
                if hashCount > 0 && hashCount <= 3 {
                    flushCurrent()
                    currentTitle = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            currentBody.append(line)
        }

        flushCurrent()
        return sections
    }
}