import Foundation

/// A video's 線路 and episodes, read from its chapter list as legado-E, Sigma and MD3 read it:
/// a volume row (`isVolume`) starts a 線路, and the chapters under it are its episodes.
/// Episodes before the first volume, or a list with no volumes at all, are one 線路 with no name.
///
/// Positions are offsets into the chapter list, the index the audiobook fields
/// (`audioChapterIndex`) and the chapter cache already use.
struct VideoEpisodeGuide: Equatable, Sendable {
    struct Route: Equatable, Identifiable, Sendable {
        /// The route's place among the routes.
        let id: Int
        /// The volume row's title; nil for the unnamed route.
        let title: String?
        /// The episodes' chapter offsets, in order.
        let episodes: [Int]
    }

    let routes: [Route]

    init(chapters: [OnlineChapterRef]) {
        var routes: [Route] = []
        var title: String?
        var episodes: [Int] = []
        func close() {
            // A volume with nothing under it has nothing to play: our chapter fetch treats a
            // volume row as a separator, as the reader does.
            guard !episodes.isEmpty else { return }
            routes.append(Route(id: routes.count, title: title, episodes: episodes))
        }
        for (offset, chapter) in chapters.enumerated() {
            if chapter.isVolume {
                close()
                title = ReaderHTMLUtilities.displayText(fromHTMLFragment: chapter.title)
                episodes = []
            } else {
                episodes.append(offset)
            }
        }
        close()
        self.routes = routes
    }

    var firstEpisode: Int? { routes.first?.episodes.first }

    var isEmpty: Bool { routes.isEmpty }

    func route(containing chapterIndex: Int) -> Route? {
        routes.first { $0.episodes.contains(chapterIndex) }
    }

    /// The episode's number within its route, from 1.
    func episodeNumber(of chapterIndex: Int) -> Int? {
        route(containing: chapterIndex)?.episodes.firstIndex(of: chapterIndex).map { $0 + 1 }
    }

    /// The next episode, going on into the next route's first when a route ends (MD3 and the
    /// original fork; maintainer, 2026-11-01). Nil after the last episode of the last route.
    func episode(after chapterIndex: Int) -> Int? {
        guard let route = route(containing: chapterIndex),
              let position = route.episodes.firstIndex(of: chapterIndex) else { return nil }
        if position + 1 < route.episodes.count { return route.episodes[position + 1] }
        return routes.dropFirst(route.id + 1).first?.episodes.first
    }

    /// The previous episode, going back into the previous route's last.
    func episode(before chapterIndex: Int) -> Int? {
        guard let route = route(containing: chapterIndex),
              let position = route.episodes.firstIndex(of: chapterIndex) else { return nil }
        if position > 0 { return route.episodes[position - 1] }
        return routes.prefix(route.id).last?.episodes.last
    }

    /// Where playback opens: the saved episode when it still is one, else the first.
    func resumeEpisode(saved chapterIndex: Int) -> Int? {
        route(containing: chapterIndex) != nil ? chapterIndex : firstEpisode
    }
}
