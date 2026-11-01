import Foundation

/// An episode's stream and the headers its CDN wants (`HeaderedMediaAsset`).
struct VideoStream: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
}

enum VideoChapterLinkError: LocalizedError, Equatable {
    /// legado-E and Sigma write a DASH manifest (text starting `<MPD`) to a file for ExoPlayer;
    /// AVFoundation cannot play DASH at all.
    case dashManifest
    /// The content is not one link: a source written for a legado without a player returns
    /// prose and opens a browser itself (`java.startBrowser`), or a parse page.
    case notALink(preview: String)

    var errorDescription: String? {
        switch self {
        case .dashManifest: localized("這一集是 DASH 串流，iOS 無法播放")
        case .notALink: localized("這一集沒有可播放的影片連結")
        }
    }
}

/// Reads a video chapter's content as legado's `VideoPlay` does: the whole content is the
/// episode's link, handed to `AnalyzeUrl`, so it may carry `,{"headers":…}` options. A link
/// wrapped in the content pipeline's markup still counts; a link inside prose does not —
/// that prose is a source's message (「【刷新正文】播放 ✅直链: …」), and the browser it opened
/// is the source's answer, not a stream for us to guess at.
enum DirectChapterVideoResolver {
    static func request(from content: String) throws -> URLRequest {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.range(of: "<MPD", options: .caseInsensitive) != nil {
            throw VideoChapterLinkError.dashManifest
        }
        let text = unwrapped(trimmed)
        let link = DirectChapterAudioResolver.stripLegadoOptions(from: text)
        guard isOnlyLink(link, in: text), let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw VideoChapterLinkError.notALink(preview: String(trimmed.prefix(160)))
        }
        if url.pathExtension.lowercased() == "mpd" { throw VideoChapterLinkError.dashManifest }
        return AnalyzeUrl(ruleUrl: text).toURLRequest() ?? URLRequest(url: url)
    }

    /// The text inside the content pipeline's markup. A bare link is left exactly as it is: a
    /// general entity decoder would read a query's `&lang=` or `&copy=` as an entity.
    private static func unwrapped(_ content: String) -> String {
        guard content.contains("<") else { return content }
        return content
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The link is the whole text, save for legado's `,{…}` options after it.
    private static func isOnlyLink(_ link: String, in text: String) -> Bool {
        guard !link.isEmpty, link.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let options = text.dropFirst(link.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return options.isEmpty || (options.hasPrefix(",") && options.hasSuffix("}"))
    }
}

/// An episode's stream, through the chapter cache every online chapter goes through: the
/// cached content is the episode's resolved link (legado `BookChapter.resourceUrl`), as an
/// audiobook chapter's is (`OnlineChapterAudioProvider`).
@MainActor
enum VideoChapterLinks {
    static func stream(
        for book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore
    ) async throws -> VideoStream {
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: book, chapterIndex: chapterIndex, priority: priority, store: store
        )
        let request = try DirectChapterVideoResolver.request(from: package.content)
        guard let url = request.url else {
            throw VideoChapterLinkError.notALink(preview: String(package.content.prefix(160)))
        }
        let headers = await OnlineChapterMedia.sourceHeaders(for: book)
            .merging(request.allHTTPHeaderFields ?? [:]) { _, requestValue in requestValue }
        return VideoStream(url: url, headers: headers)
    }

    /// Forgets the episode's resolved link, as the audiobook player does once when a link
    /// fails to play: links are mostly time-signed, so a failure usually means it expired
    /// while it sat in the cache.
    static func discardResolvedLink(for book: ReadingBook, chapterIndex: Int, store: BookStore) {
        OnlineChapterMedia.discardResolvedChapter(of: book, chapterIndex: chapterIndex, store: store)
    }
}
