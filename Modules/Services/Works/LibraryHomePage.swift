import CryptoKit
import Foundation

// 範圍's public library as a home of its own (Phase 5 plan, decision 35 as revised by the
// maintainer, 2026-10-12): the home's sections and layouts, filled with what the library
// offers and titled by it — 青空文庫's 新上架作品 as a row of covers and its indexes as chips,
// Gutenberg's shelves and bundled lists. Before, 範圍 filtered the reader's home, where 青空文庫
// served only 最新; then it showed the library's own store page, a list, which was not the
// home's presentation.
//
// The page is made, never saved: it is not a 首頁配置 and is not edited.

enum LibraryHomePage {
    /// The library's sections; nil for a connection or a book source, whose own page 範圍 shows.
    /// - Parameter languages: the reader's languages, for Gutenberg's language shelves.
    static func page(for key: SourceInstanceKey, languages: [String]) -> HomePage? {
        let bindings: [HomeSectionBinding]
        switch key.type {
        case .aozora:
            bindings = HomeSectionBinding.aozora
        case .gutenberg:
            bindings = GutenbergShelf.shelves(languages: languages).map { .gutenbergShelf(id: $0.id) }
                + HomeSectionBinding.gutenbergCollections
        case .opds, .calibre, .webDAV, .bookSource, .library, .bibliographic:
            return nil
        }
        // The library's own content only: a shelf copy opened from 繼續閱讀 still shows only itself
        // (see the Phase 5 plan, "a library item's copy folds into the item": not covered).
        return HomePage(sections: bindings.map { HomeSection(id: sectionID(key, $0), layout: .row, binding: $0) })
    }

    /// The same for the same library and binding: a row's id is its section's, and a new one on
    /// every build would load every row again.
    private static func sectionID(_ key: SourceInstanceKey, _ binding: HomeSectionBinding) -> UUID {
        // A binding's description names its case and values: `aozoraIndex(kind: "authors")`.
        let name = "\(key.type.rawValue)\u{1F}\(key.id)\u{1F}\(String(describing: binding))"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
