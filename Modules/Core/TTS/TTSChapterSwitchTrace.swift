import Foundation
import UIKit

/// Instrumentation for 「在播放器裡連按下一章，切五六章就卡死、機器發燙」 — reproducible every
/// time with VoiceOver on, and possibly the same thing as 「鎖屏聽不了書」.
///
/// One tap runs a whole pipeline: pull the chapter's text, drag the reader to it (a CoreText
/// re-layout plus a page-controller swap, even though the reader is hidden behind the player
/// sheet), request the chapter, prefetch the one after it, restart the speech engine. Nothing
/// coalesces rapid taps, so six taps plausibly leave six pipelines racing — and with VoiceOver
/// running, every page-controller appearance also posts `.screenChanged`
/// (`CoreTextPageView.viewDidAppear`), which makes VoiceOver rebuild the screen's entire
/// accessibility tree.
///
/// That is a hypothesis, and this project measures before it optimizes. `span` records what
/// actually happens — per-stage milliseconds, how many switches were already running when this
/// one began, the gap since the previous tap, and whether VoiceOver is on — so one reproduction
/// names the expensive stage instead of inviting a patch built on a guess.
///
/// `overlapping > 0` on its own confirms the pile-up; the stage timings then say which part of
/// it is worth fixing. Delete this once the cause is fixed and a regression test covers it.
@MainActor
enum TTSChapterSwitchTrace {

    /// Switches begun but not finished. Anything above one means taps are overlapping, which is
    /// what the report is really describing.
    private static var inFlight = 0
    /// When the previous switch began, so the log carries the user's tapping cadence.
    private static var lastBegan: Date?

    /// Runs one chapter switch under measurement. `step` marks the end of a stage; the label is
    /// whatever the caller just finished doing.
    ///
    /// The body is non-escaping on purpose: it writes the reader's `@State` and must stay
    /// synchronous, so nothing here may defer or dispatch it.
    static func span(target: Int, _ body: (_ step: (String) -> Void) -> Void) {
        let started = Date()
        let gapMs = lastBegan.map { Int(started.timeIntervalSince($0) * 1000) } ?? -1
        lastBegan = started
        inFlight += 1
        let overlapping = inFlight - 1
        defer { inFlight = max(0, inFlight - 1) }

        var lastMark = started
        var stages: [String] = []

        body { stage in
            let now = Date()
            stages.append("\(stage)=\(Int(now.timeIntervalSince(lastMark) * 1000))")
            lastMark = now
        }

        let totalMs = Int(Date().timeIntervalSince(started) * 1000)
        let voiceOver = UIAccessibility.isVoiceOverRunning
        AppLogger.error(
            "[TTS] ⟐ ttsSwitch",
            context: [
                "target": target,
                "totalMs": totalMs,
                "stages": stages.joined(separator: " "),
                "overlapping": overlapping,
                "sincePreviousMs": gapMs,
                "voiceOver": voiceOver
            ],
            // A pile-up is the defect being hunted, so it outranks the ordinary breadcrumb and
            // survives any severity filtering on the way to the export.
            level: overlapping > 0 ? .warning : .notice
        )
    }
}
