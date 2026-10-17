import Testing
import Foundation
@testable import yuedu_app

/// 書架 pushes the reader inside its tab, under the app root's `.global` mini-player, and the
/// reader draws an audiobook in its own `.reader` one: with both drawing, a background
/// audiobook showed as two stacked capsules over the page.
@MainActor
struct NowPlayingHubPlacementTests {

    @Test func audiobookShowsInOnePlacementOnly() {
        // A reader on screen: the reader's capsule shows the audiobook, the root's steps aside.
        #expect(NowPlayingHub.showsMiniPlayer(
            inReader: true, readerTTSVisible: false, audiobookLoaded: true, readerHostsPlayer: true
        ))
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: true, readerHostsPlayer: true
        ))
        // No reader: the root's capsule shows it.
        #expect(NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: true, readerHostsPlayer: false
        ))
        // Nothing loaded: neither.
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: false, readerHostsPlayer: false
        ))
    }

    @Test func overlappingReadersKeepTheHostUntilTheLastLeaves() {
        let hub = NowPlayingHub()
        let first = UUID()
        let second = UUID()
        hub.setReaderOverlayVisible(true, owner: first)
        #expect(hub.readerHostsPlayer)

        // The next reader appears before the first one's onDisappear arrives.
        hub.setReaderOverlayVisible(true, owner: second)
        hub.setReaderOverlayVisible(false, owner: first)
        #expect(hub.readerHostsPlayer)

        hub.setReaderOverlayVisible(false, owner: second)
        #expect(!hub.readerHostsPlayer)
    }
}
