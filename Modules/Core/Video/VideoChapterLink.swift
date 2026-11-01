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
    /// The source's player page handed its player nothing to play.
    case noVideoOnPage

    var errorDescription: String? {
        switch self {
        case .dashManifest: localized("這一集是 DASH 串流，iOS 無法播放")
        case .notALink: localized("這一集沒有可播放的影片連結")
        case .noVideoOnPage: localized("這一集的播放頁沒有找到影片")
        }
    }
}

/// Reads a video chapter's content as legado's `VideoPlay` does: the whole content is the
/// episode's link, handed to `AnalyzeUrl`, so it may carry `,{"headers":…}` options. A link
/// wrapped in the content pipeline's markup still counts; a link inside prose does not —
/// that prose is a source's message (「【刷新正文】播放 ✅直链: …」), and the browser it opened
/// is the source's answer, not a stream for us to guess at.
enum DirectChapterVideoResolver {
    enum Link: Equatable {
        case stream(URLRequest)
        /// A link with legado's `webView` option: a page that plays the episode, not a stream.
        case page(URLRequest)
    }

    static func link(from content: String) throws -> Link {
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
        let analyzed = AnalyzeUrl(ruleUrl: text)
        let request = analyzed.toURLRequest() ?? URLRequest(url: url)
        if analyzed.useWebView { return .page(request) }
        if url.pathExtension.lowercased() == "mpd" { throw VideoChapterLinkError.dashManifest }
        return .stream(request)
    }

    /// A page the content script opened for the episode (`java.startBrowser`), as the episode's
    /// content: its link with legado's `webView` option, which is how a legado link says "show
    /// this in a browser". The page's own options stay when they are JSON.
    static func pageContent(_ page: String) -> String {
        let link = DirectChapterAudioResolver.stripLegadoOptions(from: page)
        var options: [String: Any] = [:]
        let given = page.dropFirst(link.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if given.hasPrefix(",") {
            do {
                let object = try JSONSerialization.jsonObject(with: Data(given.dropFirst().utf8))
                options = object as? [String: Any] ?? [:]
            } catch {
                AppLogger.parse("⟐ video episode page options are not JSON; loading the page without them",
                                context: ["options": String(given.prefix(160))])
            }
        }
        options["webView"] = true
        do {
            let data = try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys, .withoutEscapingSlashes])
            return link + "," + String(decoding: data, as: UTF8.self)
        } catch {
            AppLogger.parse("⟐ video episode page options not re-encoded; loading the page without them",
                            context: ["error": error.localizedDescription])
            return link + #",{"webView":true}"#
        }
    }

    /// A request for a stream rather than for a page or an API: a playlist or a video file by
    /// its extension, or a CDN link that names a video type in its query (`mime_type=video_mp4`).
    /// A DASH manifest counts, so that it is reported as one.
    static func isVideoRequest(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if videoExtensions.contains(url.pathExtension.lowercased()) { return true }
        return url.query?.range(of: "mime_type=video", options: .caseInsensitive) != nil
    }

    private static let videoExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "mpd"]

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
    /// The episode being played. Its content script runs as the one legado-E's player runs:
    /// with `book.durChapterIndex` on this episode, and with what it hands to
    /// `java.openVideoPlayer` or `java.startBrowser` as the episode (`isVideoEpisode`).
    static func stream(
        for book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore
    ) async throws -> VideoStream {
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: book, chapterIndex: chapterIndex, priority: priority, store: store, isVideoEpisode: true
        )
        let link = try DirectChapterVideoResolver.link(from: package.content)
        let sourceHeaders = await OnlineChapterMedia.sourceHeaders(for: book)
        switch link {
        case .stream(let request):
            guard let url = request.url else {
                throw VideoChapterLinkError.notALink(preview: String(package.content.prefix(160)))
            }
            let headers = sourceHeaders.merging(request.allHTTPHeaderFields ?? [:]) { _, requestValue in requestValue }
            return VideoStream(url: url, headers: headers)
        case .page(let page):
            return try await stream(playedBy: page, sourceHeaders: sourceHeaders)
        }
    }

    /// A player page loads past this only when it is not going to play (the site is down, or
    /// the page waits for a tap); a page picks its stream within moments of loading.
    private static let pageSniffTimeout: TimeInterval = 15

    /// The stream a source's player page plays, played by the app's own player instead: for a
    /// 短剧 a page is all 大灰狼, 七猫-OE, 番茄四合一 and 书山 give (`java.startBrowser`), and
    /// the page itself is never shown (maintainer, 2026-11-01: 「開網頁太抽象了」).
    private static func stream(playedBy page: URLRequest, sourceHeaders: [String: String]) async throws -> VideoStream {
        let headers = sourceHeaders.merging(page.allHTTPHeaderFields ?? [:]) { _, pageValue in pageValue }
        guard let pageURL = page.url else { throw VideoChapterLinkError.noVideoOnPage }
        // The page handed over may be the video file itself.
        if DirectChapterVideoResolver.isVideoRequest(pageURL) {
            if pageURL.pathExtension.lowercased() == "mpd" { throw VideoChapterLinkError.dashManifest }
            return VideoStream(url: pageURL, headers: headers)
        }
        let userAgent = headers.first { $0.key.lowercased() == "user-agent" }?.value
        var request = page
        for (field, value) in headers where field.lowercased() != "user-agent" {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let video = await SourcePerfTrace.spanAsync("video.pageSniff", pageURL.host() ?? "") {
            await LegadoHeadlessWebView.sniffVideo(
                page: request, userAgent: userAgent, timeout: pageSniffTimeout,
                isVideoRequest: DirectChapterVideoResolver.isVideoRequest
            )
        }
        guard let video else {
            AppLogger.info("[Video] no video found on the episode's page: \(pageURL.absoluteString.prefix(160))", level: .error)
            throw VideoChapterLinkError.noVideoOnPage
        }
        if video.pathExtension.lowercased() == "mpd" { throw VideoChapterLinkError.dashManifest }
        // Fetched as the page's own player fetches it: from the page, as that browser.
        var streamHeaders = ["Referer": pageURL.absoluteString]
        if let userAgent { streamHeaders["User-Agent"] = userAgent }
        return VideoStream(url: video, headers: streamHeaders)
    }

    /// Forgets the episode's resolved link, as the audiobook player does once when a link
    /// fails to play: links are mostly time-signed, so a failure usually means it expired
    /// while it sat in the cache.
    static func discardResolvedLink(for book: ReadingBook, chapterIndex: Int, store: BookStore) {
        OnlineChapterMedia.discardResolvedChapter(of: book, chapterIndex: chapterIndex, store: store)
    }
}

extension LegadoJSBridge.VideoEpisodeHandover {
    /// The episode's content: the stream the script handed over, else its page.
    var episodeContent: String? {
        if let stream { return stream }
        return page.map(DirectChapterVideoResolver.pageContent)
    }
}
