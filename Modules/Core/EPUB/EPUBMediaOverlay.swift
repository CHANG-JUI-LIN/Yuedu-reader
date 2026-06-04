import Foundation

public enum EPUBMediaKind: String, Codable, Equatable, Sendable {
    case audio
    case video
}

public struct EPUBMediaAttachment: Codable, Equatable, Sendable {
    let kind: EPUBMediaKind
    let sourceHref: String
    let mediaType: String?
    let title: String?
    let posterHref: String?

    init(
        kind: EPUBMediaKind,
        sourceHref: String,
        mediaType: String? = nil,
        title: String? = nil,
        posterHref: String? = nil
    ) {
        self.kind = kind
        self.sourceHref = sourceHref
        self.mediaType = mediaType
        self.title = title
        self.posterHref = posterHref
    }
}

struct EPUBMediaOverlayFragment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let textHref: String?
    let textFragmentID: String?
    let audioHref: String
    let clipBegin: TimeInterval?
    let clipEnd: TimeInterval?

    var duration: TimeInterval? {
        guard let clipBegin, let clipEnd, clipEnd > clipBegin else { return nil }
        return clipEnd - clipBegin
    }
}

struct EPUBMediaOverlay: Codable, Equatable, Sendable {
    let chapterHref: String
    let smilHref: String
    let fragments: [EPUBMediaOverlayFragment]

    var firstAudioHref: String? {
        fragments.first?.audioHref
    }

    var duration: TimeInterval? {
        let values = fragments.compactMap(\.clipEnd)
        return values.max()
    }
}

enum EPUBClockValueParser {
    static func seconds(from raw: String?) -> TimeInterval? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if value.lowercased().hasPrefix("npt=") {
            value = String(value.dropFirst(4))
        }
        let lower = value.lowercased()
        if lower.hasSuffix("ms"), let number = Double(lower.dropLast(2)) {
            return number / 1000
        }
        if lower.hasSuffix("min"), let number = Double(lower.dropLast(3)) {
            return number * 60
        }
        if lower.hasSuffix("s"), let number = Double(lower.dropLast()) {
            return number
        }
        if lower.contains(":") {
            let parts = lower.split(separator: ":").compactMap(Double.init)
            guard !parts.isEmpty, parts.count <= 3 else { return nil }
            if parts.count == 3 {
                return parts[0] * 3600 + parts[1] * 60 + parts[2]
            }
            if parts.count == 2 {
                return parts[0] * 60 + parts[1]
            }
        }
        return Double(lower)
    }
}

enum SMILMediaOverlayParser {
    static func parse(xml: String, smilHref: String, chapterHref: String) -> EPUBMediaOverlay {
        let fragments = parBlocks(in: xml).compactMap { block -> EPUBMediaOverlayFragment? in
            let parAttrs = attributes(in: block.openingTag)
            guard let audioTag = firstElement(named: "audio", in: block.body),
                  let audioSrc = attributes(in: audioTag)["src"],
                  !audioSrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let audioAttrs = attributes(in: audioTag)
            let textAttrs = firstElement(named: "text", in: block.body).map(attributes(in:)) ?? [:]
            let textSrc = textAttrs["src"]
            let splitText = splitFragmentHref(textSrc)
            let fallbackID = parAttrs["id"] ?? splitText.fragment ?? UUID().uuidString

            return EPUBMediaOverlayFragment(
                id: fallbackID,
                textHref: splitText.href,
                textFragmentID: splitText.fragment,
                audioHref: audioSrc,
                clipBegin: EPUBClockValueParser.seconds(from: audioAttrs["clipbegin"] ?? audioAttrs["clipBegin"]),
                clipEnd: EPUBClockValueParser.seconds(from: audioAttrs["clipend"] ?? audioAttrs["clipEnd"])
            )
        }

        return EPUBMediaOverlay(
            chapterHref: chapterHref,
            smilHref: smilHref,
            fragments: fragments
        )
    }

    private struct ParBlock {
        let openingTag: String
        let body: String
    }

    private static func parBlocks(in xml: String) -> [ParBlock] {
        let pattern = #"<par\b([^>]*)>([\s\S]*?)</par>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsXML = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            return ParBlock(
                openingTag: nsXML.substring(with: match.range(at: 1)),
                body: nsXML.substring(with: match.range(at: 2))
            )
        }
    }

    private static func firstElement(named name: String, in xml: String) -> String? {
        let pattern = #"<\#(name)\b([^>]*)/?>|<\#(name)\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsXML = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsXML.length)) else {
            return nil
        }
        let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return range.location == NSNotFound ? nil : nsXML.substring(with: range)
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(['"])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [:]
        }
        let nsTag = tag as NSString
        var attrs: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
            guard match.numberOfRanges > 3 else { continue }
            attrs[nsTag.substring(with: match.range(at: 1)).lowercased()] = nsTag.substring(with: match.range(at: 3))
        }
        return attrs
    }

    private static func splitFragmentHref(_ raw: String?) -> (href: String?, fragment: String?) {
        guard let raw else { return (nil, nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let href = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        return (href, fragment?.isEmpty == false ? fragment : nil)
    }
}
