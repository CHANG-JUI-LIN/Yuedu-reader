import SwiftUI
import UIKit

// MARK: - 自動閱讀

extension ReaderView {

    /// What the paged host draws on top: which page is being revealed, and how far.
    ///
    /// `nil` in 捲動 mode as well as when the mode is off — there is no curtain
    /// there, the content itself moves.
    var autoReadReveal: (nextPage: Int, progress: Double)? {
        guard autoReader.isActive, !effectiveScrollMode else { return nil }
        return (nextPage: currentPage + 1, progress: autoReader.progress)
    }

    /// Hands the controller the two ways it can move the reader.
    func bindAutoRead() {
        autoReader.usesContinuousScroll = { effectiveScrollMode }
        autoReader.onAdvancePage = { advanceAutoReadPage() }
        // Captures the handle, not the reader: the handle is a reference the
        // scroll host keeps pointed at the live collection view.
        let handle = autoScrollHandle
        autoReader.onScrollByFraction = { fraction in
            guard let height = handle.viewportHeight?(), height > 0 else { return true }
            return handle.scrollBy?(height * CGFloat(fraction)) ?? false
        }
    }

    /// Entering the mode: legado stops 朗讀 first, keeps the screen awake, and
    /// collapses every other surface so the page can be watched turning itself.
    func enterAutoRead() {
        if ttsCoordinator.isPlaying {
            ttsCoordinator.stop()
        }
        autoReader.enter()
        showAutoReadPanel = false
        showQuickThemePanel = false
        showBars = false
        applyAutoReadIdleTimer()
    }

    func exitAutoRead() {
        autoReader.exit()
        showAutoReadPanel = false
        applyAutoReadIdleTimer()
    }

    /// 自動閱讀 keeps the screen on for as long as it runs (legado sets
    /// `screenTimeOut = -1`). The idle timer has another owner — `TTSCoordinator`
    /// holds it while 朗讀 is playing — so leaving the mode hands it back rather
    /// than switching it off blind.
    func applyAutoReadIdleTimer() {
        if autoReader.isActive {
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIApplication.shared.isIdleTimerDisabled =
                ttsCoordinator.isPlaying && settings.ttsKeepsScreenAwake
        }
    }

    /// The reading menu covers the page, so the curtain holds rather than running
    /// on behind it. `resume` restarts the clock, so the paused seconds are not
    /// credited to the reveal.
    func applyAutoReadMenuPause(barsVisible: Bool) {
        guard autoReader.isActive else { return }
        if barsVisible || showAutoReadPanel {
            autoReader.pause()
        } else {
            autoReader.resume()
        }
    }
}
