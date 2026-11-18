import Foundation
import SwiftSoup

struct EPUBBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let session = try await PublicationSession.open(sourceURL: url)
        let title = session.bookTitle
        let author = session.author.isEmpty ? "Unknown Author" : session.author

        var chapters: [String] = []
        chapters.reserveCapacity(session.chapters.count)

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
        }

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
