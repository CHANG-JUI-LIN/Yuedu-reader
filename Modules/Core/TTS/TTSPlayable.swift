import Foundation

func ttsLog(_ message: String) {
    NSLog("%@", message)
}

/// Unified interface for TTS engines.
/// TTSCoordinator communicates with the underlying engine through this protocol
/// without knowledge of the concrete implementation.
protocol TTSPlayable: AnyObject {
    var isPlaying: Bool { get }
    /// After finishing the current segment, call this closure to get the next text.
    /// Return nil to indicate the end.
    var onPageFinished: (() -> TTSNarrationUnit?)? { get set }
    var onStop: (() -> Void)? { get set }
    var onPlaybackStarted: ((TimeInterval) -> Void)? { get set }
    var onSegmentChanged: ((Int, Int, String) -> Void)? { get set }

    /// Start reading the given text. Rate is interpreted by the HTTP TTS service,
    /// currently using a 0.10–0.65 range in the UI.
    func speak(text: String, title: String, rate: Float, pronunciationHints: [TTSPronunciationHint])
    func configureAudioSessionOwnership(_ enabled: Bool)
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
