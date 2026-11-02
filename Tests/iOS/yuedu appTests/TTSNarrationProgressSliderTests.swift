import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 語音朗讀's 朗讀進度 slider (`TTSNarrationProgressRow`) with no finger on it.
///
/// It was a SwiftUI `Slider` whose drag draft opened on `onEditingChanged(true)` and was applied
/// on `false`. A `valueChanged` with no finger — VoiceOver's swipe up / down, and the one iOS 26
/// sends as the thumb settles after a release that moved narration to a paragraph's place —
/// opened that draft for good: the thumb stopped following narration and nothing was sought.
@Suite("TTS narration progress slider", .serialized)
@MainActor
struct TTSNarrationProgressSliderTests {
    @MainActor @Observable
    final class Narration {
        var segment = 3
        var count = 11
        var canSeek = true
        var seeks: [Double] = []
    }

    private struct Panel: View {
        let narration: Narration

        var body: some View {
            TTSNarrationProgressRow(
                segmentIndex: narration.segment,
                segmentCount: narration.count,
                canSeek: narration.canSeek,
                paragraphText: "\(narration.segment + 1) / \(narration.count)",
                onSeek: { narration.seeks.append($0) }
            )
        }
    }

    private func withSlider(_ narration: Narration,
                            body: (UISlider, UIView) async throws -> Void) async throws {
        try await withAccessibleSlider(in: Panel(narration: narration)) { slider, host in
            #expect(slider.accessibilityLabel == localized("朗讀進度"))
            try await body(slider, host)
        }
    }

    @Test("a valueChanged with no finger neither seeks nor stops the thumb following narration")
    func valueChangedWithoutTouchIsNoScrub() async throws {
        let narration = Narration()
        try await withSlider(narration) { slider, host in
            #expect(slider.value == Float(0.3))
            slider.setValue(0.47, animated: false)
            slider.sendActions(for: .valueChanged)
            #expect(await eventually(host) { slider.value == Float(0.3) })
            #expect(narration.seeks.isEmpty)

            narration.segment = 4
            #expect(await eventually(host) { slider.value == Float(0.4) })
            #expect(slider.accessibilityValue == "5 / 11")
            #expect(narration.seeks.isEmpty)
        }
    }

    @Test("VoiceOver's swipe up and down move a paragraph")
    func voiceOverAdjustsByParagraph() async throws {
        let narration = Narration()
        try await withSlider(narration) { slider, _ in
            slider.accessibilityIncrement()
            #expect(narration.seeks == [0.4])
            slider.accessibilityDecrement()
            #expect(narration.seeks == [0.4, 0.2])
        }
    }

    @Test("VoiceOver's swipe goes nowhere past the first or the last paragraph")
    func voiceOverStopsAtTheEnds() async throws {
        let narration = Narration()
        narration.segment = 10
        try await withSlider(narration) { slider, host in
            slider.accessibilityIncrement()
            narration.segment = 0
            #expect(await eventually(host) { slider.value == 0 })
            slider.accessibilityDecrement()
            #expect(narration.seeks.isEmpty)
        }
    }

    @Test("before the chapter is split into paragraphs the slider is off, VoiceOver's swipe too")
    func disabledUntilSegmented() async throws {
        let narration = Narration()
        narration.canSeek = false
        try await withSlider(narration) { slider, host in
            #expect(await eventually(host) { !slider.isEnabled })
            slider.accessibilityIncrement()
            #expect(narration.seeks.isEmpty)
        }
    }

    @Test("lifting the finger seeks once, to where it was lifted")
    func releaseSeeksOnce() async throws {
        let narration = Narration()
        try await withSlider(narration) { slider, host in
            slider.sendActions(for: .touchDown)
            settle(host)
            slider.setValue(0.47, animated: false)
            slider.sendActions(for: .touchUpInside)
            #expect(narration.seeks.count == 1)
            #expect(abs((narration.seeks.first ?? 0) - 0.47) < 1e-6)
        }
    }
}
