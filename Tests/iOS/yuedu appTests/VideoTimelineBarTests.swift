import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// FB-175: the video player's 播放進度 timeline seeks where the finger is lifted.
///
/// On the iOS 27.2 simulator the SwiftUI `Slider` it used opened one editing session on the first
/// drag and never closed it: every later drag only moved the bound value, `onEditingChanged(false)`
/// never came, so nothing ever sought — the time under the thumb stayed on the finger's while the
/// picture went on playing from where it was (the user's 8:51 episode, dragged to 4:19, kept
/// playing its opening titles). These replay the slider's control events as UIKit sends them.
@Suite("Video timeline bar", .serialized)
@MainActor
struct VideoTimelineBarTests {
    private final class Player {
        var scrubs: [Double?] = []
        var seeks: [Double] = []
        var skips: [Double] = []
    }

    private func bar(_ player: Player) -> VideoTimelineBar {
        VideoTimelineBar(
            shown: 60, end: 531, range: 0...531,
            onScrub: { player.scrubs.append($0) },
            onSeek: { player.seeks.append($0) },
            onSkip: { player.skips.append($0) }
        )
    }

    private func withSlider(_ player: Player, body: (UISlider) async throws -> Void) async throws {
        try await withAccessibleSlider(in: bar(player)) { slider, _ in
            #expect(slider.accessibilityLabel == localized("播放進度"))
            try await body(slider)
        }
    }

    @Test("lifting the finger seeks to where it was lifted")
    func releaseSeeks() async throws {
        let player = Player()
        try await withSlider(player) { slider in
            slider.sendActions(for: .touchDown)
            slider.setValue(259, animated: false)
            slider.sendActions(for: .touchUpInside)
            #expect(player.seeks == [259])
        }
    }

    @Test("a valueChanged with no finger on the slider neither scrubs nor seeks")
    func valueChangedWithoutTouchIsNoScrub() async throws {
        let player = Player()
        try await withSlider(player) { slider in
            slider.setValue(400, animated: false)
            slider.sendActions(for: .valueChanged)
            #expect(player.scrubs.compactMap { $0 }.isEmpty)
            #expect(player.seeks.isEmpty)
            #expect(slider.value == 60)
        }
    }

    @Test("VoiceOver's swipe up and down skip ten seconds")
    func voiceOverSkips() async throws {
        let player = Player()
        try await withSlider(player) { slider in
            slider.accessibilityIncrement()
            slider.accessibilityDecrement()
            #expect(player.skips == [VideoPan.jumpSeconds, -VideoPan.jumpSeconds])
            #expect(player.seeks.isEmpty)
        }
    }
}
