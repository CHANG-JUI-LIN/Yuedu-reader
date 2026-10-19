import Foundation

// MARK: - Comic page image decode
//
// Some comic sources serve their pages encrypted or cut into shuffled strips, and ship a
// `ruleContent.imageDecode` script that turns the downloaded bytes back into the picture
// (Legado `ImageUtils.decode(src, bytes, isCover = false, source, book)`, which its manga
// reader runs on every page). Without it the reader shows the bytes as they came: hard
// horizontal cuts mid-panel, strips of one panel over another's speech box.

/// One reader's `imageDecode` rule, shared by every page it builds
/// (`MangaChapterParser.pages(from:headers:localDir:imageDecoder:)`). Nil for a source without
/// the rule, which is nearly all of them, so their pages load exactly as before.
final class FixedPageImageDecoder: Equatable, Sendable {
    let source: BookSource
    let ruleJs: String

    init?(source: BookSource) {
        let rule = source.ruleContent.imageDecode
        guard !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.source = source
        self.ruleJs = rule
    }

    /// Part of every decoded page's image-cache key: a decoded image must never be found
    /// under a raw image's key or another source's, and an edited rule is a new key — the
    /// same identity `BookSourceSession.session(for:)` keys its bridge on.
    var cacheKeyPrefix: String {
        "imageDecode|\(source.bookSourceUrl)#\(source.lastUpdateTime)|"
    }

    /// Runs the rule over `data` through the source's one shared bridge, on its host
    /// (`SourceImageDecoder` → `BookSourceSession.session(for:)`). Nil when the rule returned
    /// no bytes.
    func decode(_ data: Data, src: String) async -> Data? {
        // Bytes cross into JS one number each and back the same way, so a megabyte
        // slice is a real cost; the span shows it per page.
        await SourcePerfTrace.spanAsync("comic.imageDecode", "bytes=\(data.count)") {
            await SourceImageDecoder.decode(data, src: src, ruleJs: ruleJs, source: source)
        }
    }

    static func == (lhs: FixedPageImageDecoder, rhs: FixedPageImageDecoder) -> Bool {
        lhs === rhs || (lhs.cacheKeyPrefix == rhs.cacheKeyPrefix && lhs.ruleJs == rhs.ruleJs)
    }
}
