import Foundation

/// Times what a listener hears between two paragraphs: from one segment's audio ending to the
/// next segment's audio starting, inside one narration unit (a chapter boundary is the host's
/// wait, logged by `enterWaitingForNextUnit`).
///
/// Each boundary logs `⏱ tts.gap <ms> engine=… index=… next=…` (FB-23). `next` says how the
/// following segment reached the speaker:
/// - `queued`   already handed to the player / synthesizer behind the one playing (no gap)
/// - `cached`   downloaded, but loaded at the boundary (not queueable: format or decode)
/// - `inflight` its download was still running when the paragraph ended
/// - `failed`   its preload had failed, so it was requested again only now
/// - `miss`     never requested before the boundary
/// - `spoken`   system voice, started only after the previous utterance finished
@MainActor
struct TTSParagraphGapTrace {
    struct Gap: Equatable {
        let index: Int
        let ms: Double
        let next: String
    }

    let engine: String
    private var ended: (index: Int, at: TimeInterval)?
    /// This unit's boundaries, so tests can read them; cleared with every new unit.
    private(set) var gaps: [Gap] = []

    init(engine: String) {
        self.engine = engine
    }

    mutating func reset() {
        ended = nil
        gaps.removeAll()
    }

    /// Segment `index` stopped producing audio at `time` (the system's own timestamp when the
    /// callback carries one off the main thread).
    mutating func segmentEnded(_ index: Int, at time: TimeInterval = SourcePerfTrace.now) {
        ended = (index, time)
    }

    /// Segment `index` started producing audio. Only a start that directly follows the end of
    /// `index - 1` is a paragraph boundary; seeks, resumes and skips are not.
    mutating func segmentStarted(_ index: Int, next: String, at time: TimeInterval = SourcePerfTrace.now) {
        defer { ended = nil }
        guard let ended, ended.index + 1 == index else { return }
        let ms = max(0, (time - ended.at) * 1000)
        gaps.append(Gap(index: index, ms: ms, next: next))
        // `record` measures up to now; shift the start so the line carries the start's own
        // timestamp, which the system voice captures off the main thread.
        SourcePerfTrace.record(
            "tts.gap",
            "engine=\(engine) index=\(index) next=\(next)",
            since: SourcePerfTrace.now - ms / 1000,
            thresholdMs: 0,
            mainThreadStallBreadcrumb: false
        )
    }

    /// Playback left the segment some other way (seek, skip, pause, stop).
    mutating func cancel() {
        ended = nil
    }
}
