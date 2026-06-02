import Foundation
import SwiftSoup

struct EPUBBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let parseStartUptime = ProcessInfo.processInfo.systemUptime
        func parseTrace(_ message: String) {
            let line = "[ImportTrace][EPUBBookParser] \(message)"
            print(line)
            NSLog("%@", line)
        }
        parseTrace("begin file=\(url.lastPathComponent)")
        let openStart = ProcessInfo.processInfo.systemUptime
        let session = try await PublicationSession.open(sourceURL: url)
        parseTrace(
            "stage=openPublication done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - openStart) * 1000)) chapters=\(session.chapters.count)"
        )
        let title = session.bookTitle
        let author = session.author.isEmpty ? "Unknown Author" : session.author

        var chapters: [String] = []
        chapters.reserveCapacity(session.chapters.count)

        let chapterParseStart = ProcessInfo.processInfo.systemUptime
        for descriptor in session.chapters {
            let html = try await session.chapterHTML(at: descriptor.index)
            let paragraphs = extractParagraphs(fromHTML: html)
            let chapterTitle = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let chapterBody = paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let segment: String
            if chapterTitle.isEmpty {
                segment = chapterBody
            } else if chapterBody.isEmpty {
                segment = chapterTitle
            } else {
                segment = chapterTitle + "\n" + chapterBody
            }
            if !segment.isEmpty {
                chapters.append(segment)
            }
            if descriptor.index == 0 || descriptor.index == session.chapters.count - 1 || descriptor.index % 200 == 0 {
                parseTrace(
                    "stage=parseChapters progress=\(descriptor.index + 1)/\(session.chapters.count)"
                )
            }
        }
        parseTrace(
            "stage=parseChapters done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - chapterParseStart) * 1000)) keptChapters=\(chapters.count)"
        )
        parseTrace(
            "done totalElapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - parseStartUptime) * 1000))"
        )

        return ParsedBookDocument(
            title: title,
            author: author,
            chapters: chapters
        )
    }

    private func extractParagraphs(fromHTML html: String) -> [String] {
        guard let document = try? SwiftSoup.parse(html) else {
            return fallbackParagraphs(from: html)
        }

        _ = try? document.select("script,style,noscript,iframe").remove()
        if let body = document.body() {
            let paragraphNodes = (try? body.select("p,li,blockquote,pre").array()) ?? []
            let fromNodes = paragraphNodes
                .compactMap { try? $0.text() }
                .map {
                    $0.filter { ch in
                        if ch == "\n" || ch == "\r" || ch == "\t" { return true }
                        return ch.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                    }
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !fromNodes.isEmpty {
                return fromNodes
            }

            let bodyText = ((try? body.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyText.isEmpty {
                return fallbackParagraphs(from: bodyText)
            }
        }

        return ["Loading chapter..."]
    }

    private func fallbackParagraphs(from text: String) -> [String] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.isEmpty ? ["Loading chapter..."] : lines
    }
}
