import Foundation
import Testing
@testable import yuedu_app

/// The app root's now-playing bar (2026-11-05): when it shows, what it holds, and what its long
/// press offers — Apple Books' menu for its audiobook bar, mapped onto what Yuedu has.
@Suite("Now-playing bar")
@MainActor
struct NowPlayingPopupTests {

    private func book(
        isAudiobook: Bool = true,
        isShelved: Bool = true,
        isFinished: Bool = false,
        shareURL: URL? = URL(string: "https://example.com/book")
    ) -> NowPlayingBarBook {
        NowPlayingBarBook(
            id: UUID(), title: "傲慢與偏見", isAudiobook: isAudiobook,
            isShelved: isShelved, isFinished: isFinished, shareURL: shareURL
        )
    }

    // MARK: Menu

    @Test("a shelf book's menu is Apple Books', in its order")
    func shelfBookMenu() {
        #expect(book().routes == [
            .share, .addToGroup, .stop, .markFinished, .workDetail, .removeFromShelf,
        ])
    }

    @Test("an audiobook played without being shelved offers 加入書架 and nothing that needs the shelf")
    func transientAudiobookMenu() {
        #expect(book(isShelved: false).routes == [.share, .stop, .addToShelf])
    }

    @Test("narration of a book off the shelf can only be shared or stopped")
    func transientNarrationMenu() {
        #expect(book(isAudiobook: false, isShelved: false).routes == [.share, .stop])
        #expect(book(isAudiobook: false, isShelved: false, shareURL: nil).routes == [.stop])
    }

    @Test("a finished book is not offered 標記為已讀完 again")
    func finishedBookMenu() {
        #expect(!book(isFinished: true).routes.contains(.markFinished))
    }

    @Test("the menu's rows share the audiobook player's names; 停止播放 keeps the bar's own")
    func rowNames() {
        #expect(NowPlayingBarRoute.addToShelf.title == AudiobookMoreRoute.addToShelf.title)
        #expect(NowPlayingBarRoute.removeFromShelf.title == AudiobookMoreRoute.removeFromShelf.title)
        #expect(NowPlayingBarRoute.stop.title == localized("停止播放"))
        #expect(NowPlayingBarRoute.stop.systemImage == "xmark.circle")
    }

    // MARK: Visibility

    private func presented(
        audiobookLoaded: Bool = false,
        narrationOutlivesReader: Bool = false,
        readerHostsPlayer: Bool = false,
        tabBarHidden: Bool = false,
        isPlayerOpen: Bool = false
    ) -> Bool {
        NowPlayingPopup.isBarPresented(
            audiobookLoaded: audiobookLoaded, narrationOutlivesReader: narrationOutlivesReader,
            readerHostsPlayer: readerHostsPlayer, tabBarHidden: tabBarHidden, isPlayerOpen: isPlayerOpen
        )
    }

    @Test("the bar shows an audiobook, or narration whose book was closed")
    func showsWhatPlaysOn() {
        #expect(presented(audiobookLoaded: true))
        #expect(presented(narrationOutlivesReader: true))
        #expect(!presented())
    }

    @Test("the bar steps aside for a reader's capsule, and goes with the tab bar")
    func stepsAside() {
        #expect(!presented(audiobookLoaded: true, readerHostsPlayer: true))
        #expect(!presented(audiobookLoaded: true, tabBarHidden: true))
    }

    @Test("the open player keeps its bar, to fold back into — even under a page that hides the tab bar")
    func openPlayerKeepsItsBar() {
        #expect(presented(audiobookLoaded: true, tabBarHidden: true, isPlayerOpen: true))
        // Nothing to fold into once the audiobook has gone.
        #expect(!presented(tabBarHidden: true, isPlayerOpen: true))
    }

    // MARK: The bar's buttons

    @Test("from iOS 26 the bar is Apple Books': 加入書架 while off the shelf, and ⏸")
    func appleBooksButtons() {
        #expect(NowPlayingPopup.barButtons(usesAppleBooksLayout: true, showsAddToShelf: true)
            == [.addToShelf, .playPause])
        #expect(NowPlayingPopup.barButtons(usesAppleBooksLayout: true, showsAddToShelf: false)
            == [.playPause])
    }

    @Test("before iOS 26 the bar is Apple Music's: ▶︎ and ⏭")
    func appleMusicButtons() {
        #expect(NowPlayingPopup.barButtons(usesAppleBooksLayout: false, showsAddToShelf: true)
            == [.playPause, .nextChapter])
    }

    // MARK: Tapping the bar

    @Test("narration's bar reopens its book and says so; an audiobook's opens its player")
    func openHint() {
        var narration = NowPlayingBarState()
        narration.source = .tts
        narration.narrationOutlivesReader = true
        #expect(narration.reopensNarratedBook)
        #expect(narration.openHint == localized("打開這本書到正在朗讀的地方"))

        var audiobook = NowPlayingBarState()
        audiobook.source = .audiobook
        audiobook.audiobookLoaded = true
        #expect(!audiobook.reopensNarratedBook)
        #expect(audiobook.openHint == localized("打開播放控制面板"))
    }
}
