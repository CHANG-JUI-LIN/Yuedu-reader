import CoreGraphics
import Foundation

/// An `<iframe>` whose `src` is a web page — an embedded player page, a map — rather than a
/// media file. The page draws it as a card; a tap loads the page into a live web view at the
/// card's position (`ReaderWebEmbedManager`), the same "tap to start, stays in place" contract
/// as inline video (user's request, 2026-10-10: a video in an iframe plays inline too).
///
/// An iframe whose `src` *is* a media file never becomes one of these: the converter turns it
/// into a `<video>` and it plays through the inline video player.
///
/// A book source can also hand over a page it built itself, as a `data:text/html` `src`
/// (起点读书qm's 彩蛋 videos with their 弹幕, user's choice 2026-10-10, after qimo_yuedu's
/// player page). Such a page loads as the address in the `Referer` its source declared on the
/// src (`,{"headers":{"Referer":…}}`), so what it requests — the 彩蛋 MP4, which its CDN refuses
/// without that Referer — is requested from that address (`inlinePage`). It shows live as soon
/// as it is on screen, cover and 弹幕 included, without waiting for a tap
/// (`InlineLiveContent.showsWithoutTap`, user's choice the same day).
public struct ReaderWebEmbed: Equatable, Sendable {
    /// The page to load: an `http`/`https` URL, or a `data:text/html` page the source built.
    public let src: String
    /// The iframe's own `title`, if it gave one — what VoiceOver reads for the card.
    public let title: String?
    /// The chapter the iframe sits in; sent as the page's `Referer`, which embed players check.
    public let referer: String?
    /// height / width from the iframe's `width`/`height` attributes; nil means 16:9.
    public let aspectRatio: CGFloat?

    public init(src: String, title: String?, referer: String?, aspectRatio: CGFloat? = nil) {
        self.src = src
        self.title = title
        self.referer = referer
        self.aspectRatio = aspectRatio
    }

    /// Identity for the live view and its manager. One page loaded once per `src`.
    var key: String { src }

    /// A page the book source built (`data:text/html`) rather than a web address. Checked on
    /// every scroll step, so it reads only the scheme; `inlinePage` decodes the page.
    var isSourceBuiltPage: Bool { Self.isSourceBuiltPage(src) }

    static func isSourceBuiltPage(_ src: String) -> Bool {
        src.prefix(14).lowercased() == "data:text/html"
    }

    /// The host shown on the card, so the reader can tell a player from an advert before tapping.
    /// A page the source built shows the address it loads as; empty when it declared none.
    var host: String {
        if let page = inlinePage { return page.baseURL?.host ?? "" }
        let url = OnlineImageRequestOptions.decode(src).src
        return URL(string: url)?.host ?? url
    }

    /// A page the source built (`data:text/html`): its HTML, and the address it loads as — the
    /// `Referer` declared on the src, else the chapter's own URL when that is a web address.
    /// nil for an ordinary web address, and for a `data:` page that does not decode.
    var inlinePage: (html: String, baseURL: URL?)? {
        let decoded = OnlineImageRequestOptions.decode(src)
        guard decoded.src.lowercased().hasPrefix("data:text/html"),
              let comma = decoded.src.firstIndex(of: ",")
        else { return nil }
        let header = decoded.src[..<comma].lowercased()
        let body = String(decoded.src[decoded.src.index(after: comma)...])
        let html: String?
        if header.hasSuffix(";base64") {
            html = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            html = body.removingPercentEncoding
        }
        guard let html else { return nil }
        let declared = decoded.headers.first { $0.key.caseInsensitiveCompare("Referer") == .orderedSame }?.value
        let base = [declared, referer]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        return (html, base)
    }

    /// File extensions that mean the `src` is the media itself, not a page that plays it.
    static let directMediaExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "m3u8"]

    /// True when `src` points straight at a playable video file.
    static func isDirectMedia(_ src: String) -> Bool {
        let path = URL(string: OnlineImageRequestOptions.decode(src).src)?.path.lowercased() ?? ""
        guard let dot = path.lastIndex(of: ".") else { return false }
        return directMediaExtensions.contains(String(path[path.index(after: dot)...]))
    }

    /// True for a `src` a web view can load as an embed: a web address, or a page the source
    /// built (`data:text/html`).
    static func isEmbeddablePage(_ src: String) -> Bool {
        let lower = src.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("data:text/html")
    }
}
