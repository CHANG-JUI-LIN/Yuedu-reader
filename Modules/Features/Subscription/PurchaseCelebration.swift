import SwiftUI

// MARK: - Confetti

/// One throw of confetti: pieces that start above the top edge, fall with a sway and a
/// flutter, and fade out on the way down. Pure data — where a piece is at any moment is
/// a function of time — so the motion is testable without drawing it.
struct ConfettiBurst: Equatable {
    struct Piece: Equatable {
        /// Where it starts across the width, 0...1.
        let x: Double
        /// Seconds into the burst before it appears.
        let delay: Double
        /// Seconds from above the top edge to below the bottom one.
        let fall: Double
        /// Side-to-side drift in points, and drifts per second.
        let sway: Double
        let swayRate: Double
        /// Turns per second in the plane; negative turns the other way.
        let spin: Double
        /// Flips per second around its long axis — the paper catching the light.
        let flutter: Double
        let width: Double
        let height: Double
        /// Index into `DSColor.celebration`.
        let color: Int
    }

    /// A piece's place at one moment.
    struct Frame: Equatable {
        let center: CGPoint
        let angle: Angle
        /// -1...1: how much of its face shows mid-flip.
        let flutter: Double
        let opacity: Double
    }

    // Tuned by eye on an iPhone: a quick shower, over in about two seconds.
    static let delayRange = 0.0...0.35
    static let fallRange = 1.4...2.0
    static let swayRange = 8.0...24.0
    static let swayRateRange = 0.5...1.3
    static let spinRange = -1.5...1.5
    static let flutterRange = 1.0...3.0
    static let widthRange = 6.0...9.0
    static let heightRange = 10.0...15.0
    /// Fraction of its fall after which a piece starts fading out.
    static let fadeStart = 0.75

    let pieces: [Piece]

    /// `seed` makes a burst replayable; the page passes a fresh one each time.
    init(count: Int, colors: Int, seed: UInt64) {
        var random = SplitMix64(seed: seed)
        pieces = (0..<count).map { _ in
            Piece(
                x: Double.random(in: 0...1, using: &random),
                delay: Double.random(in: Self.delayRange, using: &random),
                fall: Double.random(in: Self.fallRange, using: &random),
                sway: Double.random(in: Self.swayRange, using: &random),
                swayRate: Double.random(in: Self.swayRateRange, using: &random),
                spin: Double.random(in: Self.spinRange, using: &random),
                flutter: Double.random(in: Self.flutterRange, using: &random),
                width: Double.random(in: Self.widthRange, using: &random),
                height: Double.random(in: Self.heightRange, using: &random),
                color: Int.random(in: 0..<max(colors, 1), using: &random)
            )
        }
    }

    /// When the last piece has fallen out of view.
    var duration: TimeInterval {
        pieces.map { $0.delay + $0.fall }.max() ?? 0
    }

    /// Where `piece` is `time` seconds into the burst on a canvas of `size`: nil before it
    /// appears and once it has fallen.
    func frame(of piece: Piece, at time: TimeInterval, in size: CGSize) -> Frame? {
        let elapsed = time - piece.delay
        guard elapsed >= 0, elapsed <= piece.fall else { return nil }
        let progress = elapsed / piece.fall
        // Centre travels from one piece-length above the top to one below the bottom,
        // so a piece never pops into or out of view.
        let margin = max(piece.width, piece.height)
        let y = -margin + (Double(size.height) + 2 * margin) * progress
        let x = piece.x * Double(size.width) + piece.sway * sin(2 * .pi * piece.swayRate * elapsed)
        let opacity = progress <= Self.fadeStart ? 1 : max(0, (1 - progress) / (1 - Self.fadeStart))
        return Frame(
            center: CGPoint(x: x, y: y),
            angle: .radians(2 * .pi * piece.spin * elapsed),
            flutter: cos(2 * .pi * piece.flutter * elapsed),
            opacity: opacity
        )
    }
}

/// Frames from `start` to `end`, then none: a one-off animation's timeline stops by
/// itself instead of redrawing an empty canvas for as long as the page stays open.
struct FiniteTimelineSchedule: TimelineSchedule {
    let start: Date
    let end: Date
    let interval: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        // Low-frequency mode (Always On, a scene in the background): only the last frame.
        guard mode == .normal, interval > 0 else { return [end] }
        var dates: [Date] = []
        var date = max(start, startDate)
        while date < end {
            dates.append(date)
            date += interval
        }
        dates.append(end)
        return dates
    }
}

/// Draws one `ConfettiBurst` from `start` until its last piece is gone. Decorative and
/// never in the way: VoiceOver skips it and touches go through it.
struct ConfettiView: View {
    let burst: ConfettiBurst
    let start: Date

    var body: some View {
        TimelineView(FiniteTimelineSchedule(
            start: start,
            end: start.addingTimeInterval(burst.duration),
            interval: DSAnimation.celebrationFrameInterval
        )) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSince(start)
                let palette = DSColor.celebration
                for piece in burst.pieces {
                    guard let frame = burst.frame(of: piece, at: time, in: size) else { continue }
                    var pieceCanvas = canvas
                    pieceCanvas.opacity = frame.opacity
                    pieceCanvas.translateBy(x: frame.center.x, y: frame.center.y)
                    pieceCanvas.rotate(by: frame.angle)
                    pieceCanvas.scaleBy(x: frame.flutter, y: 1)
                    let rect = CGRect(
                        x: -piece.width / 2,
                        y: -piece.height / 2,
                        width: piece.width,
                        height: piece.height
                    )
                    pieceCanvas.fill(Path(rect), with: .color(palette[piece.color % palette.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - App icon

/// The app's own icon heading the member page — Pro is this app, not a badge. When Pro
/// has just unlocked it pops in and sends two rings out in its own shape; otherwise it
/// is simply there. Under Reduce Motion it only fades in.
struct PaywallAppIcon: View {
    /// Pro unlocked a moment ago.
    let celebrates: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasPopped = false

    private var moves: Bool { celebrates && !reduceMotion }

    private var outline: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: DSLayout.paywallAppIconSize * DSLayout.appIconCornerRatio,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            if moves {
                ForEach(0..<2, id: \.self) { ring in
                    outline
                        .stroke(DSColor.accent.opacity(0.5), lineWidth: 2)
                        .frame(width: DSLayout.paywallAppIconSize, height: DSLayout.paywallAppIconSize)
                        .scaleEffect(hasPopped ? 1.8 : 1)
                        .opacity(hasPopped ? 0 : 1)
                        .animation(
                            DSAnimation.celebrationRing.delay(Double(ring) * DSAnimation.celebrationRingStagger),
                            value: hasPopped
                        )
                }
            }
            AppIconImage(size: DSLayout.paywallAppIconSize)
                .shadow(color: DSColor.appIconShadow, radius: DSLayout.appIconShadowRadius, y: DSLayout.appIconShadowY)
                .scaleEffect(moves && !hasPopped ? 0.3 : 1)
                .opacity(celebrates && !hasPopped ? 0 : 1)
                .animation(moves ? DSAnimation.celebrationPop : DSAnimation.standard, value: hasPopped)
        }
        .onAppear { hasPopped = true }
        .accessibilityHidden(true)
    }
}

#Preview("Unlock celebration") {
    ZStack {
        PaywallAppIcon(celebrates: true)
        ConfettiView(
            burst: ConfettiBurst(count: DSLayout.celebrationConfettiCount, colors: DSColor.celebration.count, seed: 7),
            start: .now
        )
        .ignoresSafeArea()
    }
}
