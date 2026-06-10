import Foundation

enum ReaderTOCChapterMapper {
    static func chapters(from tocEntries: [EPUBTocEntry], session: PublicationSession) -> [BookChapter] {
        let spineIndexByHref: [String: Int] = Dictionary(
            session.chapters.map { ($0.href, $0.index) },
            uniquingKeysWith: { first, _ in first }
        )
        let cfiResolver = EPUBCFIResolver(
            spineReferences: session.opfSpineReferences,
            manifestItemsByID: session.opfManifestItemsByID
        )

        var seenTitles: Set<String> = []
        return tocEntries.compactMap { entry -> BookChapter? in
            let (hrefWithoutFragment, entryFragment) = splitHref(entry.href)
            let cfi = entryFragment.flatMap(EPUBCFIResolver.parse) ?? EPUBCFIResolver.parse(entry.href)
            let resolvedIndex = cfi.flatMap {
                cfiResolver.resolveSpineIndex($0, chapters: session.chapters)
            } ?? resolveHrefIndex(hrefWithoutFragment, in: spineIndexByHref)
            ?? 0

            let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedTitle.isEmpty { return nil }

            let fragment = cfi == nil
                ? entryFragment
                : cfiFragment(from: entry.href, entryFragment: entryFragment)
            let dedupeKey = "\(resolvedIndex):\(fragment ?? ""):\(normalizedTitle)"
            if seenTitles.contains(dedupeKey) { return nil }
            seenTitles.insert(dedupeKey)

            let resolvedHref = cfi == nil
                ? hrefWithoutFragment
                : session.chapters.first(where: { $0.index == resolvedIndex })?.href ?? hrefWithoutFragment

            return BookChapter(
                index: resolvedIndex,
                title: entry.title,
                content: "",
                href: resolvedHref,
                level: entry.level,
                fragment: fragment
            )
        }
    }

    private static func splitHref(_ href: String) -> (hrefWithoutFragment: String, fragment: String?) {
        guard let hashIndex = href.firstIndex(of: "#") else {
            return (href, nil)
        }
        let hrefWithoutFragment = String(href[..<hashIndex])
        let fragment = String(href[href.index(after: hashIndex)...])
        return (hrefWithoutFragment, fragment.isEmpty ? nil : fragment)
    }

    private static func resolveHrefIndex(_ href: String, in spineIndexByHref: [String: Int]) -> Int? {
        spineIndexByHref[href]
            ?? spineIndexByHref.first(where: {
                href.hasSuffix($0.key) || $0.key.hasSuffix(href)
            })?.value
    }

    private static func cfiFragment(from href: String, entryFragment: String?) -> String? {
        if let entryFragment, EPUBCFIResolver.parse(entryFragment) != nil {
            return entryFragment
        }
        guard let range = href.range(of: "epubcfi(") else {
            return entryFragment
        }
        return String(href[range.lowerBound...])
    }
}
