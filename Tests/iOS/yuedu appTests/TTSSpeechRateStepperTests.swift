import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 語音朗讀's 語速 stepper (`TTSSpeechRateRow`) as VoiceOver reads it.
///
/// A Stepper reads everything in its label into the name of both its buttons, and an
/// `.accessibilityLabel` on it is added to that name, not put in its place: each button read
/// 「語速、1.0×、語速, 增量」 and then 1.0× again as its value.
@Suite("TTS speech rate stepper", .serialized)
@MainActor
struct TTSSpeechRateStepperTests {
    @MainActor @Observable
    final class Rate {
        var value: Float = 0.5
        var text = "1.0×"
        var applied = 0
    }

    private struct Panel: View {
        let rate: Rate

        var body: some View {
            List {
                Section {
                    TTSSpeechRateRow(
                        rate: Binding(get: { rate.value }, set: { rate.value = $0 }),
                        bounds: 0.1...2.5,
                        step: 0.05,
                        rateText: rate.text,
                        onEditingEnded: { rate.applied += 1 }
                    )
                }
            }
        }
    }

    @Test("VoiceOver reads 語速 once, and the speed once, as its value")
    func readsTitleAndSpeedOnce() async throws {
        try await expectSpeechRateReadOnce(Panel(rate: Rate()), rateText: "1.0×")
    }

    @Test("a swipe up or down moves the speed a step, and applies it once")
    func swipeStepsAndAppliesOnce() async throws {
        let rate = Rate()
        try await withAccessibilityHost(in: Panel(rate: rate)) { host in
            var stepper: NSObject?
            #expect(await eventually(host) {
                stepper = accessibilityElements(in: host).first
                return stepper != nil
            })
            stepper?.accessibilityIncrement()
            #expect(await eventually(host) { abs(rate.value - 0.55) < 1e-6 })
            #expect(rate.applied == 1)
            stepper?.accessibilityDecrement()
            #expect(await eventually(host) { abs(rate.value - 0.5) < 1e-6 })
            #expect(rate.applied == 2)
        }
    }

    @Test("the value VoiceOver reads follows the speed")
    func valueFollowsTheSpeed() async throws {
        let rate = Rate()
        try await withAccessibilityHost(in: Panel(rate: rate)) { host in
            #expect(await eventually(host) {
                accessibilityElements(in: host).first?.accessibilityValue == "1.0×"
            })
            rate.value = 0.6
            rate.text = "1.2×"
            #expect(await eventually(host) {
                accessibilityElements(in: host).first?.accessibilityValue == "1.2×"
            })
        }
    }
}

/// Expects the 語速 stepper in `view` to be read as one adjustable element named 語速 alone and
/// valued at `rateText`.
@MainActor
func expectSpeechRateReadOnce(_ view: some View, rateText: String) async throws {
    let title = localized("語速")
    try await withAccessibilityHost(in: view) { host in
        var elements: [NSObject] = []
        // The stepper names its buttons a moment after they appear: iOS 17 first reads them
        // with UIKit's own 移除／加號.
        let named = await eventually(host) {
            elements = accessibilityElements(in: host)
            return !elements.isEmpty && elements.allSatisfy { ($0.accessibilityLabel ?? "").contains(title) }
        }
        let read = elements.map { "\($0.accessibilityLabel ?? "") | \($0.accessibilityValue ?? "")" }
        #expect(named, "read: \(read)")
        #expect(elements.count == 1, "read: \(read)")
        for element in elements {
            #expect(element.accessibilityTraits.contains(.adjustable), "read: \(read)")
            #expect(element.accessibilityLabel == title, "read: \(read)")
            #expect(element.accessibilityValue == rateText, "read: \(read)")
        }
    }
}
