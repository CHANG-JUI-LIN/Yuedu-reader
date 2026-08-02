import Foundation

func ttsLog(_ message: String) {
    NSLog("%@", message)
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

enum TTSPlaybackError: LocalizedError {
    case chunkUnavailable(index: Int, underlying: Error)
    case playbackFailed(index: Int)

    var errorDescription: String? {
        switch self {
        case let .chunkUnavailable(index, underlying):
            return String(
                format: localized("第 %d 段語音無法下載：%@"),
                index + 1,
                underlying.localizedDescription
            )
        case let .playbackFailed(index):
            return String(format: localized("第 %d 段語音無法播放"), index + 1)
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
    var onError: ((Error) -> Void)? { get set }
    var onPlaybackStarted: ((TimeInterval) -> Void)? { get set }
    var onSegmentChanged: ((Int, Int, String) -> Void)? { get set }

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
