import Foundation

struct EPUBManifestReference: Equatable, Sendable {
    let id: String
    let href: String
    let mediaType: String?
}

struct EPUBSpineReference: Equatable, Sendable {
    let index: Int
    let idref: String
    let itemrefID: String?
    let href: String
    let linear: Bool
}

struct EPUBCFI: Equatable, Sendable {
    struct Component: Equatable, Sendable {
        let step: Int
        let idAssertion: String?
        let textOffset: Int?
    }

    let spineStep: Int
    let spineIDAssertion: String?
    let documentSteps: [Component]
    let textOffset: Int?
}

struct EPUBCFIResolver: Sendable {
    let spineReferences: [EPUBSpineReference]
    let manifestItemsByID: [String: EPUBManifestReference]

    static func parse(_ rawValue: String) -> EPUBCFI? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: "epubcfi(", options: [.caseInsensitive]) else {
            return nil
        }
        var body = String(trimmed[start.upperBound...])
        if let close = body.lastIndex(of: ")") {
            body = String(body[..<close])
        }
        let sections = body.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
        guard let spinePart = sections.first else { return nil }

        let spineComponents = parseComponents(String(spinePart))
        guard let spineComponent = spineComponents.last else { return nil }
        let documentComponents = sections.count > 1 ? parseComponents(String(sections[1])) : []
        let textOffset = documentComponents.reversed().compactMap(\.textOffset).first

        return EPUBCFI(
            spineStep: spineComponent.step,
            spineIDAssertion: spineComponent.idAssertion,
            documentSteps: documentComponents,
            textOffset: textOffset
        )
    }

    func resolveSpineIndex(_ cfi: EPUBCFI, chapters: [PublicationChapterDescriptor]) -> Int? {
        if let assertion = cfi.spineIDAssertion,
           let spine = spineReferences.first(where: { $0.itemrefID == assertion || $0.idref == assertion }) {
            return chapterIndex(for: spine.href, chapters: chapters)
        }

        let derivedSpineIndex = cfi.spineStep / 2 - 1
        if let spine = spineReferences.first(where: { $0.index == derivedSpineIndex }),
           let index = chapterIndex(for: spine.href, chapters: chapters) {
            return index
        }

        guard chapters.indices.contains(derivedSpineIndex) else { return nil }
        return chapters[derivedSpineIndex].index
    }

    func resolveCharOffset(
        _ cfi: EPUBCFI,
        anchorOffsets: [String: Int],
        contentLength: Int
    ) -> Int {
        let clampedLength = max(0, contentLength)
        for component in cfi.documentSteps.reversed() {
            guard let id = component.idAssertion,
                  let base = anchorOffsets[id]
            else { continue }
            let offset = cfi.textOffset ?? 0
            return min(max(0, base + offset), clampedLength)
        }
        return min(max(0, cfi.textOffset ?? 0), clampedLength)
    }

    private func chapterIndex(for href: String, chapters: [PublicationChapterDescriptor]) -> Int? {
        let normalizedHref = Self.normalizedPath(href)
        if let exact = chapters.first(where: { Self.normalizedPath($0.href) == normalizedHref }) {
            return exact.index
        }
        return chapters.first {
            let chapterHref = Self.normalizedPath($0.href)
            return normalizedHref.hasSuffix(chapterHref) || chapterHref.hasSuffix(normalizedHref)
        }?.index
    }

    private static func parseComponents(_ path: String) -> [EPUBCFI.Component] {
        path.split(separator: "/", omittingEmptySubsequences: true).compactMap { rawComponent in
            parseComponent(String(rawComponent))
        }
    }

    private static func parseComponent(_ rawComponent: String) -> EPUBCFI.Component? {
        let pattern = #"^(\d+)(?:\[([^\]]*)\])?(?::(\d+)(?:\[.*\])?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsComponent = rawComponent as NSString
        let range = NSRange(location: 0, length: nsComponent.length)
        guard let match = regex.firstMatch(in: rawComponent, range: range),
              match.numberOfRanges >= 2,
              let step = Int(nsComponent.substring(with: match.range(at: 1)))
        else { return nil }

        let idAssertion: String?
        if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
            let value = nsComponent.substring(with: match.range(at: 2))
            idAssertion = value.isEmpty ? nil : value
        } else {
            idAssertion = nil
        }

        let textOffset: Int?
        if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound {
            textOffset = Int(nsComponent.substring(with: match.range(at: 3)))
        } else {
            textOffset = nil
        }

        return EPUBCFI.Component(step: step, idAssertion: idAssertion, textOffset: textOffset)
    }

    static func normalizedPath(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        if let url = URL(string: noFragment), url.scheme != nil {
            return url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        }
        return noFragment.hasPrefix("/") ? String(noFragment.dropFirst()) : noFragment
    }
}
