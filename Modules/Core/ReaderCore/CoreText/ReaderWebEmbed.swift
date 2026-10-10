import CoreGraphics
import Foundation

/// An `<iframe>` whose `src` is a web page — an embedded player page, a map — rather than a
/// media file. The page draws it as a card; a tap loads the page into a live web view at the
/// card's position (`ReaderWebEmbedManager`), the same "tap to start, stays in place" contract
/// as inline video (user's request, 2026-10-10: a video in an iframe plays inline too).
///
/// An iframe whose `src` *is* a media file never becomes one of these: the converter turns it
/// into a `<video>` and it plays through the inline video player.
public struct ReaderWebEmbed: Equatable, Sendable {
    /// The page to load (`http`/`https` only).
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

    /// The host shown on the card, so the reader can tell a player from an advert before tapping.
    var host: String { URL(string: src)?.host ?? src }

    /// File extensions that mean the `src` is the media itself, not a page that plays it.
    static let directMediaExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "m3u8"]

    /// True when `src` points straight at a playable video file.
    static func isDirectMedia(_ src: String) -> Bool {
        let path = URL(string: OnlineImageRequestOptions.decode(src).src)?.path.lowercased() ?? ""
        guard let dot = path.lastIndex(of: ".") else { return false }
        return directMediaExtensions.contains(String(path[path.index(after: dot)...]))
    }

    /// True for a `src` a web view can load as an embed.
    static func isEmbeddablePage(_ src: String) -> Bool {
        let lower = src.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}
