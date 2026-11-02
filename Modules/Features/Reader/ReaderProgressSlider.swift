import SwiftUI
import UIKit

/// The bottom bar's 閱讀進度 slider: a `UISlider` whose scrub lasts exactly as long as a finger
/// tracks it, and whose VoiceOver adjustment moves a chapter.
///
/// A SwiftUI `Slider` cannot do this: it reports every `valueChanged` that arrives with no finger
/// on it as a new editing session — `onEditingChanged(true)` and the setter — and never closes it
/// (iOS 26.5 simulator, 2026-11-02). Two such events reach this slider:
/// - iOS 26's slider sends one last `valueChanged` after `touchUpInside`, once the thumb settles.
///   The release had already moved the reader to the chapter and the slider to that chapter's
///   place, so the settled value differed, and the scrub reopened at the release position: the
///   preview and the slider's value stayed there and were never applied.
/// - VoiceOver's swipe up / down is `setValue(_:animated:)` plus a lone `valueChanged`
///   (`UISliderAccessibility _accessibilityBumpValue:`), so it too opened a scrub that nothing
///   applied.
///
/// Here the scrub follows `isTracking`, UIKit's own record of the finger: it begins on
/// `touchDown`, follows `valueChanged` while tracking, is committed on `touchUpInside` /
/// `touchUpOutside` and dropped on `touchCancel`. A `valueChanged` with no finger on the slider
/// is no scrub; the thumb is put back where the reader is.
struct ReaderProgressSlider: UIViewRepresentable {
    /// Where the thumb sits while no finger is on it, 0–1.
    var value: Double
    var tint: Color
    /// The value under the finger while it scrubs; nil once the scrub is cancelled.
    var onScrub: (Double?) -> Void
    /// The value the finger was lifted at.
    var onCommit: (Double) -> Void
    /// VoiceOver's swipe up / down; nil where there is nowhere to go.
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AdjustableSlider {
        let slider = AdjustableSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        let coordinator = context.coordinator
        slider.addAction(UIAction { [unowned slider] _ in coordinator.parent.onScrub(Double(slider.value)) },
                         for: .touchDown)
        slider.addAction(UIAction { [unowned slider] _ in coordinator.valueChanged(slider) }, for: .valueChanged)
        slider.addAction(UIAction { [unowned slider] _ in coordinator.parent.onCommit(Double(slider.value)) },
                         for: [.touchUpInside, .touchUpOutside])
        slider.addAction(UIAction { _ in coordinator.parent.onScrub(nil) }, for: .touchCancel)
        return slider
    }

    func updateUIView(_ slider: AdjustableSlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumTrackTintColor = UIColor(tint)
        slider.onIncrement = onIncrement
        slider.onDecrement = onDecrement
        // Never under the finger: the scrub is what the finger says.
        if !slider.isTracking, slider.value != Float(value) {
            slider.value = Float(value)
        }
    }

    @MainActor
    final class Coordinator {
        var parent: ReaderProgressSlider

        init(_ parent: ReaderProgressSlider) { self.parent = parent }

        func valueChanged(_ slider: UISlider) {
            if slider.isTracking {
                parent.onScrub(Double(slider.value))
            } else {
                slider.value = Float(parent.value)
            }
        }
    }

    /// Takes VoiceOver's adjustment from `UISliderAccessibility`, whose bump would send the lone
    /// `valueChanged` above.
    final class AdjustableSlider: UISlider {
        var onIncrement: (() -> Void)?
        var onDecrement: (() -> Void)?

        override func accessibilityIncrement() { onIncrement?() }
        override func accessibilityDecrement() { onDecrement?() }
    }
}

#Preview("Reader Progress Slider") {
    @Previewable @State var progress = 0.4
    @Previewable @State var scrub: Double?

    VStack(spacing: DSSpacing.md) {
        Text(String(format: "%.0f%%", (scrub ?? progress) * 100))
            .font(DSFont.subheadline.monospacedDigit())
        ReaderProgressSlider(
            value: scrub ?? progress,
            tint: DSColor.textPrimary,
            onScrub: { scrub = $0 },
            onCommit: { progress = $0; scrub = nil },
            onIncrement: { progress = min(1, progress + 0.25) },
            onDecrement: { progress = max(0, progress - 0.25) }
        )
        .accessibilityLabel(localized("閱讀進度"))
    }
    .padding(DSSpacing.lg)
}
