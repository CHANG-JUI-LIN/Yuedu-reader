import Foundation

// Unified library 5f: 作品詳情, the page every Explore card opens first, as Emby's posters open
// the item's page (Phase 5 plan, decision 27). It shows the work and lists the versions this
// device knows of it; reading starts from the page.

/// The item a card stood for, frozen when it was tapped (CLAUDE.md, "Freeze data at search
/// navigation boundaries"): the page never re-reads the row it came from.
struct WorkDetailRoute: Hashable, Sendable {
    let record: SourceRecord
    let summary: WorkSummary
    let opening: ItemOpening

    init(record: SourceRecord, summary: WorkSummary, opening: ItemOpening) {
        self.record = record
        self.summary = summary
        self.opening = opening
    }

    init?(_ entry: CollectionEntry) {
        guard case .item(let record, let summary, let opening) = entry else { return nil }
        self.init(record: record, summary: summary, opening: opening)
    }

    /// A store book, as the store's own rows make its item.
    init(_ book: PublicLibraryBook) {
        switch book {
        case .gutenberg(let book): self.init(.bundledGutenberg(book))!
        case .aozora(let work, let index): self.init(.aozora(work, index: index))!
        }
    }

    /// The node the work index knows the version by: a copy by its own key.
    var nodeKey: SourceItemKey { record.copyKey ?? record.key }

    /// Whether this version can be read at all. A Gutenberg book of a bundled list carries no
    /// formats until its catalog entry is read, so it counts; an OPDS entry or a WebDAV file
    /// with no format the app reads is the one kind that has only its data (design §6).
    var isReadable: Bool {
        switch opening {
        case .copy, .gutenberg, .aozora, .onlineBook: true
        case .opdsEntry, .webDAVFile: record.acquisitions.contains { $0 != .viewOnly }
        }
    }
}

extension CollectionEntry {
    /// An Aozora work as `AozoraProvider` lists it.
    static func aozora(_ work: AozoraWork, index: AozoraCatalogIndex) -> CollectionEntry {
        let authors = work.credits.compactMap { index.personsByID[$0.person]?.name }
        return .item(SourceRecord.derived(from: work),
                     WorkSummary(title: work.title, authors: authors, cover: .generated(seed: work.title),
                                 blurb: nil, language: "ja", contentKind: .text),
                     .aozora(work))
    }
}

enum WorkVersions {
    /// The versions 作品詳情 lists, each once, by its node key:
    /// 1. the copies on the shelf, the one opened most recently first;
    /// 2. the item tapped;
    /// 3. the other members of its work in the index (shelf copies and WebDAV files), in the
    ///    index's order.
    ///
    /// - Parameters:
    ///   - copies: the copies `CopyLookup` finds for the tapped item, and the tapped copy.
    ///   - members: the members of the works those belong to.
    static func merge(tapped: WorkDetailRoute, copies: [(WorkDetailRoute, Date?)],
                      members: [WorkDetailRoute]) -> [WorkDetailRoute] {
        var seen = Set<SourceItemKey>()
        var versions: [WorkDetailRoute] = []
        func add(_ version: WorkDetailRoute) {
            if seen.insert(version.nodeKey).inserted { versions.append(version) }
        }
        let opened = copies.enumerated().sorted { lhs, rhs in
            switch (lhs.element.1, rhs.element.1) {
            case let (l?, r?) where l != r: l > r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.offset < rhs.offset
            }
        }
        opened.forEach { add($0.element.0) }
        add(tapped)
        members.forEach(add)
        return versions
    }

    /// The version 作品詳情's main button acts on: the first readable one.
    static func primary(in versions: [WorkDetailRoute]) -> WorkDetailRoute? {
        versions.first(where: \.isReadable)
    }
}
