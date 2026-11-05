import SwiftUI
import UIKit

/// A `UISlider` whose scrub lasts exactly as long as a finger tracks it, and whose VoiceOver
/// adjustment is a step the caller chooses: the reader's 閱讀進度, 朗讀進度 and the audiobook
/// player's 播放進度.
///
/// A SwiftUI `Slider` cannot do this: it reports every `valueChanged` that arrives with no finger
/// on it as a new editing session — `onEditingChanged(true)` and the setter — and never closes it
/// (iOS 26.5 simulator, 2026-11-02). Two such events reach a slider:
/// - iOS 26's slider sends one last `valueChanged` after `touchUpInside`, once the thumb settles.
///   When the release has already moved the bound value — the reader to the chapter's place,
///   narration to the paragraph's — the settled value differs, and the scrub reopens at the
///   release position: the preview and the slider's value stay there and are never applied.
/// - VoiceOver's swipe up / down is `setValue(_:animated:)` plus a lone `valueChanged`
///   (`UISliderAccessibility _accessibilityBumpValue:`), so it too opened a scrub that nothing
///   applied.
///
/// Here the scrub follows `isTracking`, UIKit's own record of the finger: it begins on
/// `touchDown`, follows `valueChanged` while tracking, is committed on `touchUpInside` /
/// `touchUpOutside` and dropped on `touchCancel`. A `valueChanged` with no finger on the slider
/// is no scrub; the thumb is put back at `value`.
struct ScrubSlider: UIViewRepresentable {
    /// Where the thumb sits while no finger is on it.
    var value: Double
    var bounds: ClosedRange<Double> = 0...1
    var tint: Color
    /// The unplayed part of the track; the system's when nil.
    var trackTint: Color? = nil
    /// A media timeline: no thumb, a track that swells under the finger and moves by as much
    /// as the finger does wherever it lands (UIKit's `.thumbless`, iOS 26). Before iOS 26 a
    /// small dot stands in for the thumb.
    var isThumbless = false
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
        let coordinator = context.coordinator
        slider.addAction(UIAction { [unowned slider] _ in coordinator.parent.onScrub(Double(slider.value)) },
                         for: .touchDown)
        slider.addAction(UIAction { [unowned slider] _ in coordinator.valueChanged(slider) }, for: .valueChanged)
        slider.addAction(UIAction { [unowned slider] _ in coordinator.parent.onCommit(Double(slider.value)) },
                         for: [.touchUpInside, .touchUpOutside])
        slider.addAction(UIAction { _ in coordinator.parent.onScrub(nil) }, for: .touchCancel)
        if isThumbless { Self.makeThumbless(slider, dot: UIColor(tint)) }
        return slider
    }

    /// `.thumbless` where UIKit has it; a small dot in the tint before iOS 26.
    static func makeThumbless(_ slider: UISlider, dot color: UIColor) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            slider.sliderStyle = .thumbless
            return
        }
        #endif
        let side = DSLayout.scrubSliderLegacyThumbSide
        let dot = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        slider.setThumbImage(dot, for: .normal)
        slider.setThumbImage(dot, for: .highlighted)
    }

    func updateUIView(_ slider: AdjustableSlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        // `.disabled(_:)` reaches a representable only through the environment.
        slider.isEnabled = context.environment.isEnabled
        slider.minimumTrackTintColor = UIColor(tint)
        if let trackTint { slider.maximumTrackTintColor = UIColor(trackTint) }
        slider.onIncrement = onIncrement
        slider.onDecrement = onDecrement
        // Never under the finger: the scrub is what the finger says.
        if !slider.isTracking, slider.value != Float(value) {
            slider.value = Float(value)
        }
    }

    @MainActor
    final class Coordinator {
        var parent: ScrubSlider

        init(_ parent: ScrubSlider) { self.parent = parent }

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

        override func accessibilityIncrement() {
            guard isEnabled else { return }
            onIncrement?()
        }

        override func accessibilityDecrement() {
            guard isEnabled else { return }
            onDecrement?()
        }
    }
}

#Preview("Scrub Slider") {
    @Previewable @State var progress = 0.4
    @Previewable @State var scrub: Double?

    VStack(spacing: DSSpacing.md) {
        Text(String(format: "%.0f%%", (scrub ?? progress) * 100))
            .font(DSFont.subheadline.monospacedDigit())
        ScrubSlider(
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
