import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - The player page's pieces
//
// Apple Books' audiobook player, as the maintainer recorded it (2026-11-05): a scrolling title,
// a speed popover whose presets give way to a ruler when swiped, a sleep menu with a count-down
// wheel for 自訂, the system's volume and AirPlay. `AudiobookReaderView` puts them together.

// MARK: Background

/// The page's ground: the cover's colour from the top, its foot's colour at the bottom, each
/// darkened until white on it reads as it does in Apple Books' recording.
struct AudiobookPlayerPalette: Equatable {
    var top: CoverTint.RGB
    var bottom: CoverTint.RGB

    init(cover: UIImage?) {
        let whole = cover.flatMap { CoverTint.average(of: $0) } ?? CoverTint.placeholder
        let foot = cover.flatMap { CoverTint.average(of: $0, bottomFraction: 0.5) } ?? whole
        let contrast = DSLayout.audiobookPlayerBackgroundContrast
        top = CoverTint.background(for: whole, minimumContrast: contrast)
        bottom = CoverTint.background(for: foot, minimumContrast: contrast)
            .scaled(by: DSLayout.audiobookPlayerBackgroundFootShade)
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: Popovers

extension View {
    /// The player's popovers (倍速, 自訂睡眠) in the cover's tone, as the page behind them is:
    /// glass tinted with it from iOS 26, the tone itself before. Dark, like the page, whose tone
    /// is darkened for its white type (`CoverTint.background`). The system's own popover glass
    /// took the app's light appearance and came out milky white over the player (on device,
    /// 2026-11-05); dark alone turned it grey whatever the cover.
    func audiobookPlayerPopover(palette: AudiobookPlayerPalette) -> some View {
        presentationCompactAdaptation(.popover)
            .presentationBackground { AudiobookPopoverBackground(tone: palette.top) }
            .preferredColorScheme(.dark)
    }
}

private struct AudiobookPopoverBackground: View {
    let tone: CoverTint.RGB

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular.tint(tone.color.opacity(DSLayout.audiobookPlayerPopoverTint)), in: .rect)
        } else {
            tone.color
        }
        #else
        tone.color
        #endif
    }
}

// MARK: Scrolling title

/// One line that scrolls sideways when it is wider than its room, as Apple Books' title does:
/// it rests at its start, then runs off to the leading side while the next copy follows. It
/// stays inside its room, the page's margin left clear: it fades out at the trailing end, and
/// at the leading end only while it moves, so the first letter is whole at rest. With Reduce
/// Motion it stays put and is cut short instead.
struct AudiobookMarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date()

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    line(in: proxy.size.width)
                }
            }
            .background(alignment: .leading) {
                Text(text)
                    .font(font)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onChange(of: text) { _, _ in startDate = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func line(in width: CGFloat) -> some View {
        if reduceMotion || textWidth <= width {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        } else {
            TimelineView(.animation) { timeline in
                let offset = offset(at: timeline.date)
                HStack(spacing: DSLayout.audiobookPlayerMarqueeGap) {
                    Text(text)
                    Text(text)
                }
                .font(font)
                .foregroundStyle(color)
                .fixedSize()
                .offset(x: offset)
                .frame(width: width, alignment: .leading)
                .mask(fade(width: width, leading: leadingFade(at: offset)))
            }
        }
    }

    /// How far the text has moved at `date`: it rests, then runs one copy's width plus the gap.
    private func offset(at date: Date) -> CGFloat {
        let cycle = textWidth + DSLayout.audiobookPlayerMarqueeGap
        let travel = Double(cycle / DSLayout.audiobookPlayerMarqueeSpeed)
        let period = DSLayout.audiobookPlayerMarqueePause + travel
        let elapsed = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: period)
        let moving = elapsed - DSLayout.audiobookPlayerMarqueePause
        return moving <= 0 ? 0 : -CGFloat(moving) * DSLayout.audiobookPlayerMarqueeSpeed
    }

    /// How much the leading end fades at `offset`: none at rest, fully once the text has moved
    /// the fade's width, and none again as the next copy settles where the first rested.
    private func leadingFade(at offset: CGFloat) -> Double {
        let cycle = textWidth + DSLayout.audiobookPlayerMarqueeGap
        let fromRest = min(-offset, cycle + offset)
        return Double(min(1, max(0, fromRest / DSLayout.audiobookPlayerMarqueeFade)))
    }

    private func fade(width: CGFloat, leading: Double) -> some View {
        let edge = min(0.5, DSLayout.audiobookPlayerMarqueeFade / max(width, 1))
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(1 - leading), location: 0),
                .init(color: .black, location: edge),
                .init(color: .black, location: 1 - edge),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: Placing by fractions of the width

/// A row whose items sit centred at set fractions of its width, as Apple Books' transport and
/// bottom rows do, whatever each item's own width.
struct AudiobookFractionalRow: Layout {
    let centers: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where centers.indices.contains(index) {
            subview.place(
                at: CGPoint(x: bounds.minX + bounds.width * centers[index], y: bounds.midY),
                anchor: .center,
                proposal: .unspecified
            )
        }
    }
}

// MARK: Speed

/// 「1倍」's popover. Six presets to tap; a swipe across them turns them into a ruler of every
/// tenth from 0.5× to 3×, which follows the finger as a dial does — drawn leftwards, faster.
struct AudiobookSpeedPicker: View {
    let rate: Float
    let onChange: (Float) -> Void

    @State private var showsRuler = false
    /// The tick the swipe started on, and where the finger was then.
    @State private var dragStart: (tick: Int, x: CGFloat)?
    /// A tick under the finger for every tenth it crosses and every preset tapped, played the
    /// moment the speed changes rather than when the player has published it back.
    @State private var haptics = UISelectionFeedbackGenerator()

    private var tick: Int { AudiobookPlaybackRate.tick(of: rate) }

    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            Group {
                if showsRuler {
                    ruler
                } else {
                    presets
                }
            }
            .frame(height: DSLayout.audiobookSpeedSelectedPresetSide + DSSpacing.sm)

            Text(localized(showsRuler ? "調整播放速度" : "滑動以顯示更多速度"))
                .font(DSFont.fixed(size: DSLayout.audiobookSpeedCaptionFontSize))
                .foregroundStyle(DSColor.audiobookPlayerSecondary)
                // The ruler's every tenth, a swipe up or down away: VoiceOver cannot swipe
                // across the presets to reach it.
                .accessibilityElement()
                .accessibilityLabel(localized("調整播放速度"))
                .accessibilityValue(AudiobookPlaybackRate.label(rate))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: choose(AudiobookPlaybackRate.rate(atTick: tick + 1))
                    case .decrement: choose(AudiobookPlaybackRate.rate(atTick: tick - 1))
                    @unknown default: break
                    }
                }
        }
        .padding(.vertical, DSSpacing.md)
        .frame(width: DSLayout.audiobookSpeedPopoverWidth)
        .contentShape(Rectangle())
        // Alongside the presets' buttons, not under them: as a plain `gesture` a swipe that
        // started on a preset went to its button, so only the caption below turned the ruler
        // on. The ruler replaces the presets as the swipe starts, which ends their buttons'
        // touches without a tap.
        .simultaneousGesture(
            DragGesture(minimumDistance: DSLayout.audiobookSpeedRulerDragThreshold)
                .onChanged(dragChanged)
                .onEnded { _ in dragStart = nil }
        )
        .onAppear { haptics.prepare() }
        .animation(.snappy, value: showsRuler)
    }

    private func choose(_ next: Float) {
        guard next != AudiobookPlaybackRate.snapped(rate) else { return }
        haptics.selectionChanged()
        // Kept ready for the next tick: a cold Taptic Engine plays the first one late.
        haptics.prepare()
        onChange(next)
    }

    private var presets: some View {
        HStack(spacing: 0) {
            ForEach(AudiobookPlaybackRate.presets, id: \.self) { preset in
                let isSelected = AudiobookPlaybackRate.snapped(rate) == preset
                Button { choose(preset) } label: {
                    Text(isSelected ? AudiobookPlaybackRate.label(preset) : AudiobookPlaybackRate.number(preset))
                        .font(DSFont.fixed(
                            size: isSelected ? DSLayout.audiobookSpeedSelectedPresetFontSize : DSLayout.audiobookSpeedPresetFontSize,
                            weight: isSelected ? .semibold : .medium
                        ))
                        .foregroundStyle(isSelected ? DSColor.audiobookSpeedSelectedText : DSColor.audiobookPlayerPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(
                            width: isSelected ? DSLayout.audiobookSpeedSelectedPresetSide : DSLayout.audiobookSpeedPresetSide,
                            height: isSelected ? DSLayout.audiobookSpeedSelectedPresetSide : DSLayout.audiobookSpeedPresetSide
                        )
                        .background(
                            Circle().fill(isSelected ? DSColor.audiobookSpeedSelectedFill : DSColor.audiobookSpeedPresetFill)
                        )
                        .frame(width: DSLayout.audiobookSpeedPresetPitch, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AudiobookPlaybackRate.label(preset))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var ruler: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "tortoise.fill")
                .font(DSFont.fixed(size: DSLayout.audiobookSpeedAnimalIconSize))
                .foregroundStyle(DSColor.audiobookPlayerSecondary)
                .accessibilityHidden(true)
            Canvas { context, size in
                drawTicks(in: &context, size: size)
            }
            .accessibilityHidden(true)
            Image(systemName: "hare.fill")
                .font(DSFont.fixed(size: DSLayout.audiobookSpeedAnimalIconSize))
                .foregroundStyle(DSColor.audiobookPlayerSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DSSpacing.md)
    }

    /// Every tenth as a tick, the rate's at the centre: tallest and brightest, its neighbours
    /// a little less, the rest dimmer the further out they are.
    private func drawTicks(in context: inout GraphicsContext, size: CGSize) {
        let spacing = DSLayout.audiobookSpeedTickSpacing
        let half = size.width / 2
        let fadeWidth = max(half * 0.5, 1)
        for index in 0..<AudiobookPlaybackRate.tickCount {
            let distance = index - tick
            let x = half + CGFloat(distance) * spacing
            let fromEdge = half - abs(x - half)
            guard fromEdge > 0 else { continue }
            let height: CGFloat
            let width: CGFloat
            let strength: Double
            switch abs(distance) {
            case 0:
                height = DSLayout.audiobookSpeedCenterTickHeight
                width = DSLayout.audiobookSpeedCenterTickWidth
                strength = 1
            case 1:
                height = (DSLayout.audiobookSpeedCenterTickHeight + DSLayout.audiobookSpeedTickHeight) / 2
                width = DSLayout.audiobookSpeedTickWidth
                strength = DSLayout.audiobookSpeedNeighbourTickOpacity
            default:
                height = DSLayout.audiobookSpeedTickHeight
                width = DSLayout.audiobookSpeedTickWidth
                strength = DSLayout.audiobookSpeedTickOpacity
            }
            let fade = Double(min(1, fromEdge / fadeWidth))
            let rect = CGRect(x: x - width / 2, y: (size.height - height) / 2, width: width, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: width / 2),
                with: .color(DSColor.audiobookPlayerPrimary.opacity(strength * fade))
            )
        }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if dragStart == nil {
            dragStart = (tick, value.translation.width)
            showsRuler = true
        }
        guard let dragStart else { return }
        let steps = Int(((value.translation.width - dragStart.x) / DSLayout.audiobookSpeedTickSpacing).rounded())
        choose(AudiobookPlaybackRate.rate(atTick: dragStart.tick - steps))
    }
}

// MARK: Sleep timer

/// The sleep menu's rows, in Apple Books' order.
enum AudiobookSleepChoice: Hashable {
    case custom
    case endOfChapter
    case minutes(Int)
    case off

    static let menu: [AudiobookSleepChoice] = [
        .custom, .endOfChapter, .minutes(60), .minutes(45), .minutes(30), .minutes(15), .minutes(10), .minutes(5), .off,
    ]

    /// The row the timer that is set belongs to; minutes no row offers are 自訂's.
    init(_ option: AudiobookSleepOption) {
        switch option {
        case .off: self = .off
        case .endOfChapter: self = .endOfChapter
        case .minutes(let minutes):
            self = Self.menu.contains(.minutes(minutes)) ? .minutes(minutes) : .custom
        }
    }

    var title: String {
        switch self {
        case .custom: localized("自訂")
        case .endOfChapter: localized("當目前章節結束時")
        case .minutes(60): localized("1 小時")
        case .minutes(let minutes): String(format: localized("%d 分鐘"), minutes)
        case .off: localized("睡眠定時：關閉")
        }
    }

    /// What choosing the row sets; nil for 自訂, which asks how long first.
    var option: AudiobookSleepOption? {
        switch self {
        case .custom: nil
        case .endOfChapter: .endOfChapter
        case .minutes(let minutes): .minutes(minutes)
        case .off: .off
        }
    }
}

/// 自訂睡眠計時器: hours and minutes on the system's count-down wheel, then 完成.
struct AudiobookCustomSleepTimer: View {
    let onDone: (Int) -> Void

    @State private var duration: TimeInterval = 60

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            Text(localized("自訂睡眠計時器"))
                .font(DSFont.fixed(size: DSLayout.audiobookSleepTitleFontSize, weight: .semibold))
                .foregroundStyle(DSColor.audiobookPlayerPrimary)
                .accessibilityAddTraits(.isHeader)
            CountDownPicker(duration: $duration)
                .frame(height: DSLayout.audiobookSleepWheelHeight)
            Button {
                onDone(max(1, Int(duration / 60)))
            } label: {
                Text(localized("完成"))
                    .font(DSFont.fixed(size: DSLayout.audiobookSleepTitleFontSize, weight: .semibold))
                    .foregroundStyle(DSColor.audiobookPlayerPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
                    .background(Capsule().fill(DSColor.audiobookPlayerChip))
            }
            .buttonStyle(.plain)
        }
        .padding(DSSpacing.md)
        .frame(width: DSLayout.audiobookSleepPopoverWidth)
    }

    /// `UIDatePicker`'s `.countDownTimer`: the wheel Apple Books shows, its 小時 and 分鐘 in
    /// the system's words. SwiftUI's `DatePicker` has no count-down mode.
    private struct CountDownPicker: UIViewRepresentable {
        @Binding var duration: TimeInterval

        func makeUIView(context: Context) -> UIDatePicker {
            let picker = UIDatePicker()
            picker.datePickerMode = .countDownTimer
            picker.preferredDatePickerStyle = .wheels
            picker.countDownDuration = duration
            picker.addAction(UIAction { [weak picker] _ in
                guard let picker else { return }
                context.coordinator.duration.wrappedValue = picker.countDownDuration
            }, for: .valueChanged)
            return picker
        }

        func updateUIView(_ picker: UIDatePicker, context: Context) {
            context.coordinator.duration = $duration
        }

        func makeCoordinator() -> Coordinator { Coordinator(duration: $duration) }

        final class Coordinator {
            var duration: Binding<TimeInterval>
            init(duration: Binding<TimeInterval>) { self.duration = duration }
        }
    }
}

// MARK: Volume and AirPlay

/// The system volume, drawn as the timeline above it is: `MPVolumeView`, the only control that
/// sets the device's volume, with its slider made thumbless.
struct AudiobookVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> StyledVolumeView { StyledVolumeView() }

    func updateUIView(_ view: StyledVolumeView, context: Context) {}

    final class StyledVolumeView: MPVolumeView {
        private var isStyled = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // MPVolumeView builds its slider on first layout and offers no style of its own;
            // the slider is a public `UISlider` once found. Nothing found — a future system
            // that draws it differently, or the simulator, which has no volume to set — leaves
            // the system's look.
            guard let slider = subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
            if !isStyled {
                isStyled = true
                ScrubSlider.makeThumbless(slider, dot: UIColor(DSColor.audiobookPlayerTrackFill))
                slider.minimumTrackTintColor = UIColor(DSColor.audiobookPlayerTrackFill)
                slider.maximumTrackTintColor = UIColor(DSColor.audiobookPlayerTrack)
            }
            // MPVolumeView lays its slider from the top of its bounds, at the slider's own
            // height; the row centres this view on the speakers beside it, so the track sat
            // above their middle (on device, 2026-11-05). Every layout puts the track's middle on ours.
            let track = slider.convert(slider.trackRect(forBounds: slider.bounds), to: self)
            slider.frame.origin.y += bounds.midY - track.midY
        }
    }
}

/// AirPlay's own button, which shows the system's route list.
struct AudiobookRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(DSColor.audiobookPlayerControl)
        picker.activeTintColor = UIColor(DSColor.audiobookPlayerPrimary)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

// MARK: Times

enum AudiobookPlayerTime {
    /// 「−4:58」: the time left, as Apple Books writes it under the timeline.
    static func remaining(_ time: TimeInterval, of duration: TimeInterval) -> String {
        "\u{2212}" + AudiobookReaderView.formatTime(max(0, duration - time))
    }

    /// The `+0:15` bubble: how far the skips since it appeared have moved, sign and all.
    static func skipped(_ seconds: TimeInterval) -> String {
        (seconds < 0 ? "\u{2212}" : "+") + AudiobookReaderView.formatTime(abs(seconds))
    }

    /// The sleep timer's count-down: minutes and seconds, hours when there are any.
    static func countdown(to date: Date, from now: Date) -> String {
        AudiobookReaderView.formatTime(max(0, date.timeIntervalSince(now).rounded(.up)))
    }

    /// The count-down as VoiceOver reads it: 「44 分鐘 59 秒」 in the system's words.
    static func spokenCountdown(to date: Date, from now: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now).rounded(.up)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

#if DEBUG
#Preview("倍速") {
    @Previewable @State var rate: Float = 1
    AudiobookSpeedPicker(rate: rate) { rate = $0 }
        .background(AudiobookPlayerPalette(cover: nil).gradient)
        .environment(\.colorScheme, .dark)
}

#Preview("自訂睡眠計時器") {
    AudiobookCustomSleepTimer { _ in }
        .background(AudiobookPlayerPalette(cover: nil).gradient)
        .environment(\.colorScheme, .dark)
}

#Preview("跑馬燈") {
    AudiobookMarqueeText(
        text: "Sunrise on the Reaping (The Hunger Games)",
        font: DSFont.fixed(size: 20, weight: .semibold),
        color: DSColor.audiobookPlayerPrimary
    )
    .padding(.horizontal, 32)
    .frame(width: 300)
    .background(AudiobookPlayerPalette(cover: nil).gradient)
}
#endif
