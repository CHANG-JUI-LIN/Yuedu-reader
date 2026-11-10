import SwiftUI

/// A search's progress and its pause control in one, as the App Store draws a download:
/// a ring that fills as the sources answer, with a pause glyph inside. A tap pauses the
/// search and the glyph turns to play; another carries on with the sources not yet
/// asked. Beside it, how many sources have answered, and any that failed, timed out or
/// were skipped — 「18/27 · 失敗 4」.
///
/// The 搜索 page shows it at the end of its source-scope row while a search runs or is
/// paused, and takes it away when the search is done.
struct SearchProgressControl: View {
    let progress: SearchAggregator.SearchProgress
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            if progress.total > 0 {
                summary
            }
            Button(action: isPaused ? onResume : onPause) {
                SearchProgressRing(fraction: progress.fraction, isPaused: isPaused)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPaused ? localized("繼續搜索") : localized("暫停搜索"))
            .accessibilityValue(progress.total > 0 ? "\(progress.completed)/\(progress.total)" : "")
        }
    }

    private var summary: some View {
        var text = Text("\(progress.completed)/\(progress.total)")
        if progress.timedOut > 0 {
            text = text + Self.separator
                + Text(String(format: localized("超時 %d"), progress.timedOut))
                    .foregroundStyle(DSColor.warning)
        }
        if progress.failed > 0 {
            text = text + Self.separator
                + Text(String(format: localized("失敗 %d"), progress.failed))
                    .foregroundStyle(DSColor.destructive)
        }
        return text
            .font(DSFont.footnote)
            .monospacedDigit()
            .foregroundStyle(DSColor.textSecondary)
            .lineLimit(1)
    }

    private static let separator = Text(" · ")
}

/// The ring itself: a grey track, the answered share drawn over it in the accent colour,
/// and the glyph for what a tap does next.
private struct SearchProgressRing: View {
    let fraction: Double
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(DSColor.neutralControlFill, lineWidth: DSLayout.searchProgressRingLineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    DSColor.accent,
                    style: StrokeStyle(lineWidth: DSLayout.searchProgressRingLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(DSFont.fixed(size: DSLayout.searchProgressRingGlyphSize, weight: .bold))
                .foregroundStyle(DSColor.accent)
                .accessibilityHidden(true)
        }
        .frame(width: DSLayout.searchProgressRingSize, height: DSLayout.searchProgressRingSize)
        // The arc follows each answer smoothly; with Reduce Motion it steps.
        .animation(reduceMotion ? nil : DSAnimation.standard, value: fraction)
        .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

#Preview("搜索進度") {
    VStack(spacing: DSSpacing.lg) {
        SearchProgressControl(
            progress: SearchAggregator.SearchProgress(total: 27, completed: 18, failed: 4),
            isPaused: false,
            onPause: {},
            onResume: {}
        )
        SearchProgressControl(
            progress: SearchAggregator.SearchProgress(total: 27, completed: 9, timedOut: 2),
            isPaused: true,
            onPause: {},
            onResume: {}
        )
    }
    .padding()
}
