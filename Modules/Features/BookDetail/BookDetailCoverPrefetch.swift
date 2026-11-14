import SwiftUI

/// The covers of a row of 作品詳情 (作者其他作品, 同系列, 同題材, an author's page), fetched as soon
/// as the row has its works (maintainer, 2026-11-14: 「作者其他作品的封面不預載嗎」「要，先下載」):
/// the row is below the fold and draws its cards lazily, so without this a cover started loading
/// only when its card scrolled into view.
///
/// Through `BookCoverImage.fetchCover`, the cards' own path: the pipeline keeps one load per
/// address, so a card that appears meanwhile joins the load already in flight, and one that
/// appears later finds its cover in memory.
enum BookDetailCoverPrefetch {
    struct Cover: Hashable {
        let url: String
        let headers: [String: String]
        /// A connection's own session (an OPDS library's), which also keys its cache.
        let session: URLSession?
        /// A 來源配置's address, sent as the cover's Referer as its card sends it
        /// (`BookCoverLoader.headers`).
        var sourceBaseURL: String? = nil
    }

    /// Covers fetched ahead per row: a row shows a dozen works, an author's page a few screens.
    static let limit = 24
    /// Loads at a time, so a row of covers does not hold every connection to one site.
    static let concurrency = 4

    /// The remote covers of `cards`, each address once, in the cards' order. A shelf copy's
    /// cover and a file's are read from disk by their own views; a generated cover has no
    /// address.
    static func covers(of cards: [HomeCardContent], limit: Int = BookDetailCoverPrefetch.limit) -> [Cover] {
        var seen = Set<String>()
        var covers: [Cover] = []
        for card in cards {
            guard covers.count < limit else { break }
            guard case .reference(.remote(let url, let headers)?, let session) = card.cover else { continue }
            let address = url.absoluteString
            guard seen.insert(BookCoverLoader.cacheKey(for: address, session: session)).inserted else { continue }
            covers.append(Cover(url: address, headers: headers, session: session))
        }
        return covers
    }

    /// The covers of a 來源配置's 同題材 row, as `DiscoverCover` asks for them: the book's cover
    /// address as the source gave it, with the section's base address and headers. Each address
    /// once, in the row's order; a book with no cover address has none.
    static func covers(of section: DiscoverShowcaseSection, limit: Int = BookDetailCoverPrefetch.limit) -> [Cover] {
        var seen = Set<String>()
        var covers: [Cover] = []
        for display in section.books {
            guard covers.count < limit else { break }
            let address = display.book.coverUrl
            guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(address).inserted else { continue }
            covers.append(Cover(url: address, headers: section.coverHeaders, session: nil, sourceBaseURL: section.coverBaseURL))
        }
        return covers
    }

    @MainActor
    static func run(_ cards: [HomeCardContent]) async {
        await run(covers(of: cards))
    }

    /// Fetches `covers` into the cover pipeline, `concurrency` at a time. Nothing when
    /// 強制使用預設封面 is on: no card would show them. A cover that fails is the card's to
    /// report (its own load logs it); cancelling the task ends the rest.
    @MainActor
    static func run(_ covers: [Cover]) async {
        guard !GlobalSettings.shared.useDefaultCoverForAllBooks else { return }
        let covers = covers.filter { BookCoverLoader.cachedImage(for: $0.url, session: $0.session) == nil }
        guard !covers.isEmpty else { return }
        let started = SourcePerfTrace.now
        await withTaskGroup(of: Void.self) { group in
            var next = covers.makeIterator()
            func add() {
                guard let cover = next.next() else { return }
                group.addTask {
                    _ = await BookCoverImage.fetchCover(coverURL: cover.url, sourceBaseURL: cover.sourceBaseURL,
                                                        sourceHeaders: cover.headers, sourceID: nil, session: cover.session)
                }
            }
            for _ in 0..<concurrency { add() }
            for await _ in group {
                guard !Task.isCancelled else { break }
                add()
            }
        }
        SourcePerfTrace.record("works.detail.covers.prefetch", "covers=\(covers.count)", since: started, thresholdMs: 0)
    }
}

extension View {
    /// Fetches the remote covers of `cards` ahead of their cards (`BookDetailCoverPrefetch`),
    /// again when the cards change.
    func prefetchingCovers(of cards: [HomeCardContent]) -> some View {
        task(id: cards.map(\.id)) { await BookDetailCoverPrefetch.run(cards) }
    }

    /// Fetches the covers of a 來源配置's 同題材 row ahead of its cards, again when its books change.
    func prefetchingCovers(of section: DiscoverShowcaseSection) -> some View {
        task(id: section.books.map(\.id)) { await BookDetailCoverPrefetch.run(BookDetailCoverPrefetch.covers(of: section)) }
    }
}
