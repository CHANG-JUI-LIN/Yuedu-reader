import Foundation

/// The narration half of the TTS log.
///
/// This was `NSLog` only, so none of its 162 call sites ever reached the in-app
/// diagnostics — including the one line that explains 朗讀斷在章末
/// (`chapter N still empty after layout; aborting wait`). Routing it through
/// `AppLogger` puts every one of them in front of the user without touching a
/// single call site.
///
/// `.trace` on purpose: this is step-by-step narration, and it belongs in the
/// flight recorder, which releases it attached to whatever actually went wrong.
/// The handful of lines that are verdicts rather than narration pass an explicit
/// level at their own call site instead of coming through here.
func ttsLog(_ message: String) {
    AppLogger.render(message, level: .trace)
}

/// What the host has to say when an engine reaches the end of the current chapter.
///
/// `waiting` exists because "the next chapter's text isn't in memory yet" and "there is no
/// next chapter" used to collapse into the same `nil`, and the engine treated both as the end
/// of the session — so an online book whose next chapter had not finished fetching + laying out
/// by the time the audio ran out simply stopped, and the user had to restart playback by hand.
enum TTSNextUnitOutcome {
    /// The next unit is available now; play it immediately.
    case ready(TTSNarrationUnit)
    /// The next unit is being prepared. Keep the session alive (silence keep-alive, background
    /// task, Now Playing) and wait for `supplyPendingUnit(_:)`; do NOT stop.
    case waiting
    /// There is genuinely nothing more to read. Stop.
    case finished
}

/// What the engine just started speaking.
///
/// This used to be three loose arguments `(index, total, text)`, and the reader found
/// the words on screen by searching the page for `text`. That picks the first match,
/// which is the wrong one as soon as a chapter says `「嗯。」` twice — and splitting
/// segments per speaker makes short repeated lines ordinary rather than rare. Carrying
/// `narrationRange` lets the reader derive the position instead of guessing it.
struct TTSActiveSegment: Equatable {
    let index: Int
    let total: Int
    let text: String
    /// Where the segment sits in the narration unit the engine was handed — not in the
    /// chapter. Only the reader knows how that unit was sliced out of the chapter, so
    /// only the reader can finish the conversion.
    let narrationRange: NSRange
}

enum TTSPlaybackError: LocalizedError {
    case chunkUnavailable(index: Int, underlying: Error)
    case chunkSkipped(index: Int, underlying: Error)
    case playbackFailed(index: Int)
    case systemVoiceUnavailable

    var errorDescription: String? {
        switch self {
        case let .chunkUnavailable(index, underlying):
            return String(
                format: localized("第 %d 段語音無法下載：%@"),
                index + 1,
                underlying.localizedDescription
            )
        case let .chunkSkipped(index, underlying):
            return String(
                format: localized("第 %d 段語音無法下載，已跳過：%@"),
                index + 1,
                underlying.localizedDescription
            )
        case let .playbackFailed(index):
            return String(format: localized("第 %d 段語音無法播放"), index + 1)
        case .systemVoiceUnavailable:
            return localized("系統語音無法播放，請到設定下載對應語音後重試")
        }
    }
}

/// Unified interface for TTS engines.
/// TTSCoordinator communicates with the underlying engine through this protocol
/// without knowledge of the concrete implementation.
protocol TTSPlayable: AnyObject {
    var isPlaying: Bool { get }
    /// After finishing the current segment, call this closure to get the next text.
    var onPageFinished: (() -> TTSNextUnitOutcome)? { get set }
    /// Hand the engine the unit it has been waiting for after a `.waiting` outcome.
    /// Ignored unless the engine is actually in that waiting state.
    func supplyPendingUnit(_ unit: TTSNarrationUnit)
    /// True between a `.waiting` outcome and the matching `supplyPendingUnit(_:)`.
    var isWaitingForNextUnit: Bool { get }
    var onStop: (() -> Void)? { get set }
    /// Playback cannot proceed because of this error. The engine may pause at the
    /// current segment for resume, or end the session through `onStop`.
    var onError: ((Error) -> Void)? { get set }
    /// One segment was given up on, but narration continues with the next one. Reported so a
    /// provider problem is never invisible, without tearing down a listening session that is
    /// still producing audio.
    var onSegmentSkipped: ((Error) -> Void)? { get set }
    var onPlaybackStarted: ((TimeInterval) -> Void)? { get set }
    var onSegmentChanged: ((TTSActiveSegment) -> Void)? { get set }

    /// 多角色朗讀: speaker name → voice identifier, already scoped to the book by the
    /// reader (engines have no idea which book is open).
    ///
    /// Empty means single-voice playback, and it means it all the way down: the chapter
    /// is not split at quote boundaries at all. Splitting with nobody cast would produce
    /// identical audio out of many more utterances — and on the network engine, many
    /// more requests — for no audible difference.
    var roleVoices: [String: String] { get set }

    /// Start reading the given text. Rate uses the UI scale 0.10–1.0 where 0.5 is 100%.
    func speak(text: String, title: String, rate: Float, pronunciationHints: [TTSPronunciationHint])
    /// Apply a new rate to the playback session already in progress, so a slider change
    /// takes effect immediately instead of only on the next `speak`.
    func updateRate(_ rate: Float)
    func configureAudioSessionOwnership(_ enabled: Bool)
    /// Rebuild playback after iOS reports that the media services were reset.
    func recoverAfterAudioSessionReset()
    func pause()
    func resume()
    func stop()
    func skipForward()
    func skipBackward()
    func seekToSegment(_ index: Int)
}

extension TTSPlayable {
    func speak(text: String, title: String, rate: Float) {
        speak(text: text, title: title, rate: rate, pronunciationHints: [])
    }
}
