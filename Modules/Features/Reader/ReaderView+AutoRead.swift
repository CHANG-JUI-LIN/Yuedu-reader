import SwiftUI
import UIKit

// MARK: - 自動閱讀

extension ReaderView {

    /// Which page the paged host is revealing over the current one.
    ///
    /// `nil` in 捲動 mode as well as when the mode is off — there is no curtain
    /// there, the content itself moves. How far the curtain has travelled is
    /// deliberately not here: that changes every frame and goes straight to the
    /// layer through `autoReadRevealHandle`.
    var autoReadRevealPage: Int? {
        guard autoReader.isActive, !effectiveScrollMode else { return nil }
        return currentPage + 1
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
        let reveal = autoReadRevealHandle
        autoReader.onProgressChanged = { progress in
            reveal.setProgress?(progress)
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

    /// Whether something is over the page that makes watching it turn pointless.
    ///
    /// `showAutoReadPanel` is deliberately **not** on this list. legado counts its
    /// own auto-read dialog as a `bottomDialog`, which trips `onMenuShow` →
    /// `autoPager.pause()` — but that dialog is the only door into the mode's
    /// controls, so holding the reveal behind it reads as "tapping this killed my
    /// 自動閱讀", which is how it was reported here. The panel is a strip along the
    /// bottom; the page above it is still being read, so the reveal keeps moving.
    var autoReadIsCoveredBySurface: Bool {
        showBars || showTOC || showSettings || showQuickThemePanel
    }

    /// The curtain holds while a surface covers the page. `resume` restarts the
    /// clock rather than catching up, so the covered seconds are not credited to
    /// the reveal.
    func applyAutoReadPause() {
        guard autoReader.isActive else { return }
        if autoReadIsCoveredBySurface {
            autoReader.pause()
        } else {
            autoReader.resume()
        }
    }

    /// The colours 自動閱讀's pill and panel paint with.
    ///
    /// They float at the bottom of the page in every interface, standing where the
    /// bottom bar stands, so they take that bar's slots — 自定義 reaches them the
    /// same way it reaches the bar itself. Apple Books has no chrome palette
    /// (`ReaderChromeInterface.init` returns nil for it) and paints its own controls
    /// with the design-system default, so the pill follows it there instead of
    /// inventing a third look. This is the only place that pair is resolved.
    var autoReadChrome: (fill: Color, tint: Color, accent: Color) {
        guard let interface = ReaderChromeInterface(settings.appearanceReaderInterface) else {
            return (DSColor.surface, DSColor.textPrimary, readerTheme.accentColor)
        }
        let palette = ReaderChromePalette(
            interface: interface,
            theme: readerTheme,
            settings: settings
        )
        return (palette.bottomFill, palette.bottomIcon, palette.bottomAccent)
    }

    /// Stage one of the two taps the middle of the page now has to serve: put the
    /// mode's own panel away, and stop there. Only once nothing of 自動閱讀 is
    /// expanded does a tap in the middle mean "show the reading menu".
    ///
    /// legado needs no staging because it has no pill — `showActionMenu` opens its
    /// auto-read dialog *instead of* the reading menu while the mode runs, and the
    /// dialog dismisses on an outside tap. Ours leaves a collapsed pill on screen,
    /// so one tap has two jobs and they take turns.
    @discardableResult
    func consumeTapForAutoReadPanel() -> Bool {
        guard autoReader.isActive, showAutoReadPanel else { return false }
        withAnimation(DSAnimation.standard) { showAutoReadPanel = false }
        return true
    }
}
