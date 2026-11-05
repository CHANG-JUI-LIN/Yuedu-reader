import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

/// The audiobook player page in Apple Books' layout (2026-11-05): its speeds, its sleep menu,
/// and the times written under the timeline.
@Suite("Audiobook player page")
@MainActor
struct AudiobookPlayerPageTests {

    // MARK: Speed

    @Test("a speed is always one of the ruler's tenths, from 0.5 to 3")
    func speedsSnapToTheRuler() {
        #expect(AudiobookPlaybackRate.snapped(1.26) == 1.3)
        #expect(AudiobookPlaybackRate.snapped(0.2) == 0.5)
        #expect(AudiobookPlaybackRate.snapped(3.4) == 3.0)
        #expect(AudiobookPlaybackRate.tickCount == 26)
        for tick in 0..<AudiobookPlaybackRate.tickCount {
            let rate = AudiobookPlaybackRate.rate(atTick: tick)
            #expect(AudiobookPlaybackRate.tick(of: rate) == tick)
        }
        // Past either end the ruler stops at its last tick.
        #expect(AudiobookPlaybackRate.rate(atTick: -3) == 0.5)
        #expect(AudiobookPlaybackRate.rate(atTick: 99) == 3.0)
    }

    @Test("every preset is on the ruler")
    func presetsAreTicks() {
        for preset in AudiobookPlaybackRate.presets {
            #expect(AudiobookPlaybackRate.snapped(preset) == preset)
        }
    }

    @Test("whole speeds are written without a decimal, as 「1倍」")
    func speedNumbers() {
        #expect(AudiobookPlaybackRate.number(1) == "1")
        #expect(AudiobookPlaybackRate.number(2) == "2")
        #expect(AudiobookPlaybackRate.number(1.3) == "1.3")
        #expect(AudiobookPlaybackRate.number(0.8) == "0.8")
        #expect(AudiobookPlaybackRate.label(1.5) == String(format: localized("%@倍"), "1.5"))
    }

    /// AVFoundation's default pitch algorithm stops at 2×; the ruler goes to 3×.
    @Test("chapters are played with a pitch algorithm that reaches 3×")
    func playerItemsReachThreeTimes() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        #expect(AudiobookPlayer.playerItem(for: asset).audioTimePitchAlgorithm == .timeDomain)
    }

    // MARK: Sleep

    @Test("the sleep menu is Apple Books' rows, in its order")
    func sleepMenuOrder() {
        #expect(AudiobookSleepChoice.menu == [
            .custom, .endOfChapter, .minutes(60), .minutes(45), .minutes(30),
            .minutes(15), .minutes(10), .minutes(5), .off,
        ])
        #expect(AudiobookSleepChoice.custom.option == nil)
        #expect(AudiobookSleepChoice.minutes(45).option == .minutes(45))
        #expect(AudiobookSleepChoice.off.option == .off)
    }

    @Test("a timer the menu does not list is checked as 自訂")
    func customMinutesAreCustom() {
        #expect(AudiobookSleepChoice(.minutes(30)) == .minutes(30))
        #expect(AudiobookSleepChoice(.minutes(23)) == .custom)
        #expect(AudiobookSleepChoice(.endOfChapter) == .endOfChapter)
        #expect(AudiobookSleepChoice(.off) == .off)
    }

    // MARK: Times

    @Test("the times under the timeline are Apple Books'")
    func timelineTimes() {
        #expect(AudiobookPlayerTime.remaining(100, of: 600) == "\u{2212}8:20")
        #expect(AudiobookPlayerTime.remaining(700, of: 600) == "\u{2212}0:00")
        #expect(AudiobookPlayerTime.skipped(15) == "+0:15")
        #expect(AudiobookPlayerTime.skipped(45) == "+0:45")
        #expect(AudiobookPlayerTime.skipped(-30) == "\u{2212}0:30")
        let now = Date()
        #expect(AudiobookPlayerTime.countdown(to: now.addingTimeInterval(45 * 60), from: now) == "45:00")
        #expect(AudiobookPlayerTime.countdown(to: now.addingTimeInterval(3_725), from: now) == "1:02:05")
        #expect(AudiobookPlayerTime.countdown(to: now.addingTimeInterval(-10), from: now) == "0:00")
    }
}

/// The sleep count-down sets the shared player's timer, so it runs in the serialized suite that
/// already owns that player rather than beside it.
extension AudiobookChapterTransitionTests {
    @Test("a minutes timer publishes when it fires; any other choice clears it")
    func sleepFireDateFollowsTheTimer() throws {
        let player = AudiobookPlayer.shared
        defer { player.setSleepOption(.off) }
        let before = Date()
        player.setSleepOption(.minutes(30))
        let fireDate = try #require(player.sleepFireDate)
        #expect(abs(fireDate.timeIntervalSince(before) - 30 * 60) < 5)

        player.setSleepOption(.endOfChapter)
        #expect(player.sleepFireDate == nil)

        player.setSleepOption(.minutes(5))
        #expect(player.sleepFireDate != nil)
        player.setSleepOption(.off)
        #expect(player.sleepFireDate == nil)
    }
}
