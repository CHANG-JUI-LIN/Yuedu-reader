import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Auto Read Controller

/// 自動閱讀 — a mode, not a transport.
///
/// Modelled on legado's `AutoPager` (`legado-E/.../page/AutoPager.kt`), which all
/// three forks implement identically. Two things about it are easy to get wrong,
/// and the previous version got both:
///
/// 1. **It is not a page turn on a timer.** In 翻頁 mode the next page is laid over
///    the current one and revealed top-to-bottom by a moving clip line; the page
///    turn itself happens instantly, unanimated, when the reveal reaches the
///    bottom. The reader's chosen 仿真／覆蓋／滑動 animation is deliberately
///    bypassed. In 捲動 mode there is no reveal — the content scrolls
///    continuously.
/// 2. **Speed is seconds per page, not a multiplier.** `viewportHeight /
///    secondsPerPage` is the velocity, and it is the same number in both modes.
///
/// Driven by `CADisplayLink` rather than a `Timer`, because the reveal advances
/// every frame rather than once per page.
@MainActor
final class AutoReadController: NSObject, ObservableObject {

    /// legado's slider: 1–120 seconds for one page, default 10. Bigger is slower.
    static let secondsPerPageRange: ClosedRange<Double> = 1...120
    static let defaultSecondsPerPage: Double = 10

    private static let defaultsKey = "yd_auto_read_seconds_per_page"
    /// The old 0.5×–5× multiplier. Read once, converted, then left alone — a
    /// stored `2.0` is ambiguous between the two scales, so the new value needs a
    /// key of its own rather than a reinterpretation of the old one.
    private static let legacyMultiplierDefaultsKey = "yd_auto_read_speed"
    /// What 1× used to mean.
    private static let legacyBaseInterval: Double = 4.0

    @Published private(set) var isActive = false
    /// Held, not stopped: the menu is open, or a gesture is in flight. legado
    /// pauses on exactly these and resumes without losing the reveal's position.
    @Published private(set) var isPaused = false
    /// Survives leaving the reader.
    @Published private(set) var secondsPerPage: Double
    /// How far the next page has been revealed, 0…1. Only meaningful in 翻頁 mode.
    @Published private(set) var progress: Double = 0

    /// Advance one page, unanimated. `false` means there was no next page, which
    /// ends the mode — legado's `fillPage(NEXT)` returning false.
    var onAdvancePage: (() -> Bool)?
    /// 捲動 mode: move the content down by this fraction of one viewport.
    /// `false` means the end of the book.
    var onScrollByFraction: ((Double) -> Bool)?
    /// Asked every frame, because the reader can switch modes underneath us.
    var usesContinuousScroll: () -> Bool = { false }

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    var secondsText: String { Self.secondsText(secondsPerPage) }

    override init() {
        secondsPerPage = Self.loadPersistedSecondsPerPage()
        super.init()
    }

    // MARK: - Mode

    func enter() {
        guard !isActive else { return }
        isActive = true
        isPaused = false
        progress = 0
        startDisplayLink()
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        progress = 0
        stopDisplayLink()
    }

    func toggleMode() {
        if isActive { exit() } else { enter() }
    }

    /// Leaves the mode without the caller having to know whether it was on.
    func stopForReaderExit() {
        isActive = false
        isPaused = false
        progress = 0
        stopDisplayLink()
    }

    // MARK: - Pause

    /// Holds the reveal where it is. Paused time is not credited to progress:
    /// `resume` restarts the clock rather than catching up.
    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        lastTimestamp = nil
        displayLink?.isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        lastTimestamp = nil
        displayLink?.isPaused = false
    }

    /// A manual page turn or a chapter change invalidates the reveal — the page
    /// underneath is no longer the one being revealed over.
    func resetReveal() {
        progress = 0
        lastTimestamp = nil
    }

    // MARK: - Speed

    func setSecondsPerPage(_ newValue: Double) {
        let clamped = Self.clampedSecondsPerPage(newValue)
        guard clamped != secondsPerPage else { return }
        secondsPerPage = clamped
        UserDefaults.standard.set(clamped, forKey: Self.defaultsKey)
    }

    nonisolated static func clampedSecondsPerPage(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSecondsPerPage }
        return min(max(value.rounded(), secondsPerPageRange.lowerBound), secondsPerPageRange.upperBound)
    }

    /// "10s" — the readout legado's dialog shows next to the slider.
    nonisolated static func secondsText(_ value: Double) -> String {
        String(format: "%.0fs", clampedSecondsPerPage(value))
    }

    /// "約每 10 秒翻一頁"
    var intervalDescription: String {
        String(
            format: localized("AutoRead.Format.Interval"),
            String(format: "%.0f", secondsPerPage)
        )
    }

    private static func loadPersistedSecondsPerPage() -> Double {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: defaultsKey) as? Double {
            return clampedSecondsPerPage(stored)
        }
        if let legacyMultiplier = defaults.object(forKey: legacyMultiplierDefaultsKey) as? Double,
           legacyMultiplier.isFinite,
           legacyMultiplier > 0 {
            let converted = clampedSecondsPerPage(legacyBaseInterval / legacyMultiplier)
            defaults.set(converted, forKey: defaultsKey)
            return converted
        }
        return defaultSecondsPerPage
    }

    // MARK: - Frame driver

    private func startDisplayLink() {
        stopDisplayLink()
        lastTimestamp = nil
        let link = DisplayLinkProxy.displayLink(
            target: self,
            selector: #selector(handleDisplayLink(_:))
        )
        // .common so the reveal keeps moving while a gesture is tracking.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        guard isActive, !isPaused else { return }
        guard let previous = lastTimestamp else {
            lastTimestamp = link.timestamp
            return
        }
        lastTimestamp = link.timestamp

        let elapsed = link.timestamp - previous
        guard elapsed > 0, elapsed.isFinite else { return }
        let fraction = Self.fraction(ofPageIn: elapsed, secondsPerPage: secondsPerPage)

        if usesContinuousScroll() {
            // No reveal here — the content itself moves, exactly as legado hands
            // the pager to `ContentTextView` only in scroll mode.
            if onScrollByFraction?(fraction) == false { exit() }
            return
        }

        let advance = Self.advance(progress: progress, by: fraction)
        progress = advance.progress
        for _ in 0..<advance.pageTurns {
            guard onAdvancePage?() == true else {
                exit()
                return
            }
        }
    }

    // MARK: - Frame arithmetic (pure, so it can be tested without a display link)

    /// legado's `height / readTime * elapsedTime`, expressed as a fraction of one
    /// page rather than in pixels — the pixels differ between the two modes but
    /// the fraction does not.
    nonisolated static func fraction(
        ofPageIn elapsed: TimeInterval,
        secondsPerPage: Double
    ) -> Double {
        elapsed / max(secondsPerPageRange.lowerBound, secondsPerPage)
    }

    struct Advance: Equatable {
        var progress: Double
        var pageTurns: Int
    }

    /// Subtracts a whole page rather than resetting to zero.
    ///
    /// legado-E zeroes here and so loses the overshoot — up to one frame of drift
    /// on every page. Its own KMP port subtracts instead; that is the version
    /// worth copying.
    nonisolated static func advance(progress: Double, by fraction: Double) -> Advance {
        guard fraction.isFinite, fraction > 0 else {
            return Advance(progress: progress, pageTurns: 0)
        }
        var value = progress + fraction
        var turns = 0
        while value >= 1 {
            value -= 1
            turns += 1
        }
        return Advance(progress: value, pageTurns: turns)
    }

    deinit {
        displayLink?.invalidate()
    }
}
