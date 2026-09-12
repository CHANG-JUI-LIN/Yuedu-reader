import Foundation
import CoreGraphics
import YueduCoreText

enum ResolvedLink: Equatable {
    /// Leaves the book — handed to the system browser.
    case external(URL)
    /// Somewhere in this publication. `fragment` is the anchor id, nil when the
    /// link targets the chapter as a whole.
    case internalTarget(spineIndex: Int, fragment: String?)
    /// A link this publication cannot satisfy (a path matching no spine item, a
    /// scheme the reader does not handle). NEVER silently rewritten into "the
    /// current chapter" — that produced a jump to the top of whatever the reader
    /// happened to be showing.
    case unresolvable(String)
}

/// One href → destination resolver for the whole engine. Same-spine anchors,
/// cross-spine anchors, backlinks and external URLs all come through here;
/// there is no second navigation path for footnotes.
///
/// MainActor because relative-path resolution reuses `EPUBStyleResolver`, which
/// is MainActor-isolated. Deliberately reused rather than reimplemented: a
/// second `../` normalizer is a second answer to "which chapter is this".
@MainActor
struct LinkResolver {

    /// Spine-ordered source hrefs. Index alignment matters — entry `i` is spine
    /// `i`, and nil means that spine has no source href.
    let chapterHrefs: [String?]

    init(chapterHrefs: [String?]) {
        self.chapterHrefs = chapterHrefs
    }

    func resolve(href rawHref: String, fromSpine spineIndex: Int) -> ResolvedLink {
        let href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else { return .unresolvable(rawHref) }

        // Scheme-qualified: only http(s) is opened. Any other scheme
        // (`mailto:`, `tel:`, custom) is reported unresolvable rather than
        // handed to the system — a reader should not open arbitrary schemes
        // because a book asked it to.
        if let scheme = schemePrefix(of: href) {
            guard scheme == "http" || scheme == "https", let url = URL(string: href) else {
                return .unresolvable(rawHref)
            }
            return .external(url)
        }

        var path = href
        var fragment: String?
        if let hash = href.firstIndex(of: "#") {
            path = String(href[..<hash])
            let raw = String(href[href.index(after: hash)...])
            fragment = raw.isEmpty ? nil : raw
        }

        // Same-document anchor (`#note1`) — including a bare `#`.
        if path.isEmpty {
            return .internalTarget(spineIndex: spineIndex, fragment: fragment)
        }

        let currentHref = chapterHrefs.indices.contains(spineIndex)
            ? (chapterHrefs[spineIndex] ?? "")
            : ""
        let resolved = EPUBStyleResolver.resolveImageHref(path, chapterHref: currentHref)
        guard let target = spine(matching: resolved) else {
            return .unresolvable(rawHref)
        }
        return .internalTarget(spineIndex: target, fragment: fragment)
    }

    /// The spine whose source href equals `path`.
    ///
    /// Percent-encoding is the one normalization applied: a manifest commonly
    /// stores `Text/第一章.xhtml` while the link in the markup writes it
    /// percent-encoded (or the reverse). Both forms are compared — this is
    /// normalization of the same string, not a fuzzy/basename match, which would
    /// happily resolve two different chapters to the same spine.
    private func spine(matching path: String) -> Int? {
        if let exact = spineWithHref(path) { return exact }
        if let decoded = path.removingPercentEncoding, decoded != path,
           let index = spineWithHref(decoded) {
            return index
        }
        if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           encoded != path, let index = spineWithHref(encoded) {
            return index
        }
        return nil
    }

    private func spineWithHref(_ path: String) -> Int? {
        for (index, href) in chapterHrefs.enumerated() where href == path {
            return index
        }
        return nil
    }

    /// The URL scheme of `href`, lowercased, or nil when it has none.
    /// Hand-rolled rather than `URL(string:).scheme` because a relative EPUB
    /// path with a colon in a directory name must not read as a scheme, and
    /// `URL(string:)` fails outright on some authored hrefs (raw spaces).
    private func schemePrefix(of href: String) -> String? {
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let candidate = href[href.startIndex..<colon]
        guard !candidate.isEmpty,
              let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        // A scheme must be followed by `//`, `/` or a non-path opaque body; the
        // discriminator that matters here is that a relative path never contains
        // a colon before its first slash.
        if let slash = href.firstIndex(of: "/"), slash < colon { return nil }
        return candidate.lowercased()
    }
}
