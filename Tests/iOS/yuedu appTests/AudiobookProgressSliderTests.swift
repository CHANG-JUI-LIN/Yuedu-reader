import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The audiobook player's 播放進度 slider (`AudiobookProgressSection`) with no finger on it.
///
/// It was a SwiftUI `Slider` bound to a time the player's clock wrote into only while no drag
/// was on. A `valueChanged` with no finger — VoiceOver's swipe up / down, and the one iOS 26
/// sends as the thumb settles after a release the clock has moved on from — started a drag that
/// never ended: the bar stopped following playback for as long as the page was open, and nothing
/// was sought.
@Suite("Audiobook progress slider", .serialized)
@MainActor
struct AudiobookProgressSliderTests {
    @MainActor @Observable
    final class Player {
        var time: TimeInterval = 0
        var duration: TimeInterval = 600
        var chapter = 2
        var isEnabled = true
        var seeks: [Seek] = []
        var forwardSkips = 0
        var backwardSkips = 0
    }

    struct Seek: Equatable {
        let time: TimeInterval
        let chapter: Int?
    }

    /// The thumb sits at `time` on a timeline of `duration`.
    private func isAt(_ slider: UISlider, _ time: TimeInterval, of duration: TimeInterval = 600) -> Bool {
        abs(slider.fraction - time / duration) < 1e-4
    }

    private struct Page: View {
        let player: Player

        var body: some View {
            AudiobookProgressSection(
                currentTime: player.time,
                duration: player.duration,
                chapterIndex: player.chapter,
                onSeek: { player.seeks.append(Seek(time: $0, chapter: $1)) },
                onSkipBackward: { player.backwardSkips += 1 },
                onSkipForward: { player.forwardSkips += 1 }
            )
            .disabled(!player.isEnabled)
        }
    }

    @Test("the timeline is 播放進度, read as where it is of how long")
    func timelineReadsPosition() async throws {
        let player = Player()
        player.time = 100
        try await withAccessibleSlider(in: Page(player: player)) { slider, host in
            #expect(slider.accessibilityLabel == localized("播放進度"))
            let expected = String(format: localized("%1$@，共 %2$@"), "1:40", "10:00")
            #expect(await eventually(host) { slider.accessibilityValue == expected })
        }
    }

    @Test("the bar shows where playback is when the page opens")
    func showsTheCurrentTimeOnAppear() async throws {
        let player = Player()
        player.time = 100
        try await withAccessibleSlider(in: Page(player: player)) { slider, host in
            #expect(await eventually(host) { isAt(slider, 100) })
        }
    }

    @Test("a valueChanged with no finger neither seeks nor stops the bar following playback")
    func valueChangedWithoutTouchIsNoScrub() async throws {
        let player = Player()
        try await withAccessibleSlider(in: Page(player: player)) { slider, host in
            player.time = 100
            #expect(await eventually(host) { isAt(slider, 100) })

            slider.setFraction(0.5)
            slider.sendActions(for: .valueChanged)
            #expect(await eventually(host) { isAt(slider, 100) })
            #expect(player.seeks.isEmpty)

            player.time = 160
            #expect(await eventually(host) { isAt(slider, 160) })
            #expect(player.seeks.isEmpty)
        }
    }

    @Test("VoiceOver's swipe up and down skip 15 seconds, as the buttons beside it do")
    func voiceOverSkips() async throws {
        let player = Player()
        try await withAccessibleSlider(in: Page(player: player)) { slider, _ in
            slider.accessibilityIncrement()
            #expect(player.forwardSkips == 1)
            slider.accessibilityDecrement()
            #expect(player.backwardSkips == 1)
            #expect(player.seeks.isEmpty)
        }
    }

    @Test("while the chapter loads the slider is off, VoiceOver's swipe too")
    func disabledWhileLoading() async throws {
        let player = Player()
        player.isEnabled = false
        try await withAccessibleSlider(in: Page(player: player)) { slider, host in
            #expect(await eventually(host) { !slider.isEnabled })
            slider.accessibilityIncrement()
            #expect(player.forwardSkips == 0)
        }
    }

    @Test("lifting the finger seeks once, on the chapter the scrub began on")
    func releaseSeeksOnceOnTheScrubbedChapter() async throws {
        let player = Player()
        player.time = 100
        try await withAccessibleSlider(in: Page(player: player)) { slider, host in
            slider.sendActions(for: .touchDown)
            // The queue moves on to the next chapter, a longer one, under the finger.
            player.chapter = 3
            player.duration = 900
            #expect(await eventually(host) { slider.maximumValue == 900 })
            slider.setValue(300, animated: false)
            slider.sendActions(for: .touchUpInside)
            #expect(player.seeks == [Seek(time: 300, chapter: 2)])
        }
    }
}
