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
            inReader: true, readerTTSVisible: false, audiobookLoaded: true,
            narrationOutlivesReader: false, readerHostsPlayer: true
        ))
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: true,
            narrationOutlivesReader: false, readerHostsPlayer: true
        ))
        // No reader: the root's capsule shows it.
        #expect(NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: true,
            narrationOutlivesReader: false, readerHostsPlayer: false
        ))
        // Nothing loaded: neither.
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: false,
            narrationOutlivesReader: false, readerHostsPlayer: false
        ))
    }

    /// Feedback #83: closing a book mid-narration kept the narration playing and took its
    /// capsule away, leaving nothing on the shelf to pause or stop it with.
    @Test func narrationPastItsReaderShowsAtTheRootOnly() {
        // The book closed, no reader on screen: the root's capsule shows the narration.
        #expect(NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: false,
            narrationOutlivesReader: true, readerHostsPlayer: false
        ))
        // Another book opened: its reader shows the narration, the root's steps aside.
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: true, audiobookLoaded: false,
            narrationOutlivesReader: true, readerHostsPlayer: true
        ))
        #expect(NowPlayingHub.showsMiniPlayer(
            inReader: true, readerTTSVisible: true, audiobookLoaded: false,
            narrationOutlivesReader: true, readerHostsPlayer: true
        ))
        // The narrating reader is still open, only covered by a page it pushed: the root does
        // not show it, since tapping the root's capsule would reopen the book over that reader.
        #expect(!NowPlayingHub.showsMiniPlayer(
            inReader: false, readerTTSVisible: false, audiobookLoaded: false,
            narrationOutlivesReader: false, readerHostsPlayer: false
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

    /// A closed reader that was not narrating has nothing to keep: its narrator is cut loose
    /// from the reader so neither keeps the other alive.
    @Test func closedReaderWithoutNarrationIsNotHeld() {
        let hub = NowPlayingHub()
        let coordinator = TTSCoordinator()
        coordinator.onNextNarrationUnit = { .finished }
        coordinator.onStop = {}
        coordinator.onWillResume = {}
        coordinator.onNextTrackRequested = { true }
        coordinator.onPreviousTrackRequested = { true }

        hub.holdNarrationPastReader(coordinator)

        #expect(!hub.holdsNarrationPastReader)
        #expect(coordinator.onNextNarrationUnit == nil)
        #expect(coordinator.onStop == nil)
        #expect(coordinator.onWillResume == nil)
        #expect(coordinator.onNextTrackRequested == nil)
        #expect(coordinator.onPreviousTrackRequested == nil)
    }

    /// Only a narration held past its reader is taken over, and only by a reader of its book.
    @Test func nothingHeldIsNothingToAdopt() {
        let hub = NowPlayingHub()
        #expect(hub.narrationToTakeOver(forBook: UUID()) == nil)

        let coordinator = TTSCoordinator()
        coordinator.narrationBookID = UUID()
        // Stopped: handed over, not held.
        hub.holdNarrationPastReader(coordinator)
        #expect(!hub.holdsNarrationPastReader)
        #expect(hub.narrationToTakeOver(forBook: coordinator.narrationBookID!) == nil)
    }
}
