import AVFoundation
import Foundation
import UIKit

// MARK: - System TTS Engine (offline, on-device AVSpeechSynthesizer)

/// Offline fallback engine driven by `AVSpeechSynthesizer`. Used when no HTTP TTS source is
/// configured, or when the user explicitly selects the system voice. Mirrors the segment /
/// skip / seek semantics of `HTTPTTSEngine` so `TTSCoordinator` can drive either engine through
/// `TTSPlayable` without special-casing.
final class SystemTTSEngine: NSObject, TTSPlayable, @unchecked Sendable {

    var isPlaying: Bool = false
    var onPageFinished: (() -> TTSNarrationUnit?)?
    var onStop: (() -> Void)?
    var onPlaybackStarted: ((TimeInterval) -> Void)?
    var onSegmentChanged: ((Int, Int, String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private var chunkPronunciationHints: [[TTSPronunciationHint]] = []
    private var currentIndex = 0
    private var isPaused = false
    private var lastRate: Float = 0.5
    private var playbackToken = UUID()
    private var activeUtterance: AVSpeechUtterance?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// UTF-16 offset (into the current chunk) of the last word the synthesizer reported it was
    /// about to speak. Used so a resume that lost the paused state — the OS commonly ends a
    /// paused utterance when backgrounded — can re-speak only the remainder of the sentence
    /// instead of replaying the whole ~5s chunk from its start.
    private var spokenUTF16Offset = 0
    /// Offset (into the current chunk) at which the active utterance's text begins: 0 for a
    /// full chunk, `spokenUTF16Offset` for a partial resume. Lets the delegate map the
    /// utterance-relative range it reports back onto the full chunk.
    private var utteranceBaseOffset = 0

    // Read by paragraph: system voices speak long utterances smoothly, so set the cap
    // high enough that a normal paragraph stays a single gap-free chunk. The cap only
    // kicks in to bound a pathologically long paragraph.
    private let targetChunkLength = 2000

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - TTSPlayable

    func configureAudioSessionOwnership(_ enabled: Bool) {
        // The coordinator owns the shared AVAudioSession; AVSpeechSynthesizer reuses it
        // (usesApplicationAudioSession defaults to true), so there is nothing to configure.
        ttsLog("[TTS][SystemEngine] configureAudioSessionOwnership ignored enabled=\(enabled)")
    }

    func speak(
        text: String,
        title: String,
        rate: Float,
        pronunciationHints: [TTSPronunciationHint]
    ) {
        ttsLog("[TTS][SystemEngine] speak requested textCount=\(text.count) title=\(title) rate=\(rate)")
        resetPlaybackState()
        let chunkRanges = TTSTextChunker.splitWithRanges(text, targetChunkLength: targetChunkLength)
        chunks = chunkRanges.map(\.text)
        chunkPronunciationHints = chunkRanges.map {
            TTSPronunciationProjector.project(pronunciationHints, into: $0.sourceRange)
        }
        guard !chunks.isEmpty else {
            ttsLog("[TTS][SystemEngine] speak aborted no chunks")
            return
        }

        playbackToken = UUID()
        lastRate = rate
        currentIndex = 0
        isPaused = false
        isPlaying = true
        beginBackgroundTask()

        ttsLog("[TTS][SystemEngine] chunked count=\(chunks.count) firstCount=\(chunks.first?.count ?? 0)")
        speakChunk(at: 0, token: playbackToken)
    }

    func pause() {
        ttsLog("[TTS][SystemEngine] pause requested isPlaying=\(isPlaying) index=\(currentIndex)")
        guard isPlaying else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
        isPlaying = false
        endBackgroundTask()
    }

    func resume() {
        ttsLog("[TTS][SystemEngine] resume requested isPlaying=\(isPlaying) isPaused=\(isPaused) index=\(currentIndex)")
        guard !isPlaying, isPaused else { return }
        beginBackgroundTask()
        isPaused = false
        isPlaying = true
        if synthesizer.isPaused {
            let success = synthesizer.continueSpeaking()
            ttsLog("[TTS][SystemEngine] resume continue success=\(success)")
        } else {
            resumeCurrentChunkFromSpokenOffset(token: playbackToken)
        }
    }

    func stop() {
        ttsLog("[TTS][SystemEngine] stop requested")
        playbackToken = UUID()
        resetPlaybackState()
        onStop?()
    }

    func skipForward() {
        ttsLog("[TTS][SystemEngine] skipForward requested index=\(currentIndex) count=\(chunks.count)")
        guard !chunks.isEmpty else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < chunks.count else {
            handlePageChunksFinished(token: playbackToken)
            return
        }
        jumpToChunk(at: nextIndex)
    }

    func skipBackward() {
        ttsLog("[TTS][SystemEngine] skipBackward requested index=\(currentIndex) count=\(chunks.count)")
        guard !chunks.isEmpty else { return }
        jumpToChunk(at: max(currentIndex - 1, 0))
    }

    func seekToSegment(_ index: Int) {
        guard !chunks.isEmpty else { return }
        let targetIndex = max(0, min(index, chunks.count - 1))
        ttsLog("[TTS][SystemEngine] seekToSegment requested index=\(targetIndex) current=\(currentIndex) isPlaying=\(isPlaying) isPaused=\(isPaused)")

        if isPlaying {
            jumpToChunk(at: targetIndex)
            return
        }

        stopSynthesizer()
        currentIndex = targetIndex
        isPaused = true
        spokenUTF16Offset = 0
        utteranceBaseOffset = 0
        publishSegmentChanged(index: targetIndex)
    }

    // MARK: - Playback

    private func speakChunk(at index: Int, token: UUID) {
        guard token == playbackToken else {
            ttsLog("[TTS][SystemEngine] speakChunk ignored stale token index=\(index)")
            return
        }
        guard !isPaused else {
            ttsLog("[TTS][SystemEngine] speakChunk paused index=\(index)")
            return
        }
        guard index < chunks.count else {
            handlePageChunksFinished(token: token)
            return
        }

        currentIndex = index
        publishSegmentChanged(index: index)
        // Fresh chunk: nothing spoken yet, and its utterance starts at the chunk's beginning.
        spokenUTF16Offset = 0
        utteranceBaseOffset = 0

        let hints = chunkPronunciationHints.indices.contains(index) ? chunkPronunciationHints[index] : []
        let utterance = Self.makeUtterance(
            text: chunks[index],
            rate: lastRate,
            pronunciationHints: hints
        )
        utterance.voice = preferredVoice(for: chunks[index])
        activeUtterance = utterance
        isPlaying = true

        onPlaybackStarted?(estimatedDuration(for: chunks[index]))
        ttsLog("[TTS][SystemEngine] speak chunk index=\(index) rate=\(utterance.rate) voice=\(utterance.voice?.identifier ?? "default")")
        synthesizer.speak(utterance)
    }

    /// Resume path taken when the synthesizer has already dropped its paused state (so
    /// `continueSpeaking` is a no-op). Re-speaks only the not-yet-spoken tail of the current
    /// chunk, from `spokenUTF16Offset`, avoiding the ~5s replay of the whole sentence.
    private func resumeCurrentChunkFromSpokenOffset(token: UUID) {
        guard token == playbackToken else { return }
        guard chunks.indices.contains(currentIndex) else {
            handlePageChunksFinished(token: token)
            return
        }
        let full = chunks[currentIndex] as NSString
        let offset = min(max(spokenUTF16Offset, 0), full.length)
        // Nothing spoken yet, or the whole chunk already spoken: fall back to the normal path.
        guard offset > 0, offset < full.length else {
            speakChunk(at: currentIndex, token: token)
            return
        }

        let remaining = full.substring(from: offset)
        publishSegmentChanged(index: currentIndex)

        let hints = remainingHints(forChunk: currentIndex, fromUTF16Offset: offset)
        let utterance = Self.makeUtterance(text: remaining, rate: lastRate, pronunciationHints: hints)
        utterance.voice = preferredVoice(for: remaining)
        activeUtterance = utterance
        utteranceBaseOffset = offset
        isPlaying = true

        onPlaybackStarted?(estimatedDuration(for: remaining))
        ttsLog("[TTS][SystemEngine] resume from offset=\(offset)/\(full.length) index=\(currentIndex)")
        synthesizer.speak(utterance)
    }

    /// Pronunciation hints for the tail of a chunk starting at `offset`, with each hint's range
    /// clipped to the tail and rebased so it lines up with the re-spoken substring.
    private func remainingHints(forChunk index: Int, fromUTF16Offset offset: Int) -> [TTSPronunciationHint] {
        guard chunkPronunciationHints.indices.contains(index) else { return [] }
        let full = chunks[index] as NSString
        let tail = NSRange(location: offset, length: max(0, full.length - offset))
        return chunkPronunciationHints[index].compactMap { hint in
            let clipped = NSIntersectionRange(hint.range, tail)
            guard clipped.length > 0 else { return nil }
            return TTSPronunciationHint(
                range: NSRange(location: clipped.location - offset, length: clipped.length),
                ipa: hint.ipa
            )
        }
    }

    private func jumpToChunk(at index: Int) {
        guard chunks.indices.contains(index) else { return }
        stopSynthesizer()
        currentIndex = index
        isPaused = false
        isPlaying = true
        beginBackgroundTask()
        speakChunk(at: index, token: playbackToken)
    }

    private func handlePlaybackEnded() {
        let finishedIndex = currentIndex
        ttsLog("[TTS][SystemEngine] playback ended index=\(finishedIndex)")
        activeUtterance = nil
        guard isPlaying, !isPaused else { return }
        speakChunk(at: finishedIndex + 1, token: playbackToken)
    }

    private func handlePageChunksFinished(token: UUID) {
        guard token == playbackToken else { return }
        ttsLog("[TTS][SystemEngine] page chunks finished count=\(chunks.count)")

        if let next = onPageFinished?(), !next.text.isEmpty {
            speak(
                text: next.text,
                title: "",
                rate: lastRate,
                pronunciationHints: next.pronunciationHints
            )
        } else {
            resetPlaybackState()
            onStop?()
        }
    }

    private func publishSegmentChanged(index: Int) {
        guard chunks.indices.contains(index) else { return }
        onSegmentChanged?(index, chunks.count, chunks[index])
    }

    private func stopSynthesizer() {
        activeUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func resetPlaybackState() {
        stopSynthesizer()
        chunks.removeAll()
        chunkPronunciationHints.removeAll()
        currentIndex = 0
        isPaused = false
        isPlaying = false
        spokenUTF16Offset = 0
        utteranceBaseOffset = 0
        endBackgroundTask()
    }

    // MARK: - Voice & rate

    private func preferredVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let savedIdentifier = GlobalSettings.shared.ttsSystemVoiceIdentifier
        if !savedIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: savedIdentifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Self.preferredLanguage(for: text))
    }

    static func preferredLanguage(for text: String) -> String {
        if text.unicodeScalars.contains(where: isHan) {
            return preferredChineseLanguage()
        }
        return AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// Picks Traditional vs. Simplified Chinese based on the user's preferred languages,
    /// matching the app's own zh-Hant / zh-Hans localization.
    private static func preferredChineseLanguage() -> String {
        for code in Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("zh-hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                return "zh-TW"
            }
            if lower.hasPrefix("zh") {
                return "zh-CN"
            }
        }
        return "zh-CN"
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }

    static func makeUtterance(
        text: String,
        rate: Float,
        pronunciationHints: [TTSPronunciationHint]
    ) -> AVSpeechUtterance {
        let utterance: AVSpeechUtterance
        if pronunciationHints.isEmpty {
            utterance = AVSpeechUtterance(string: text)
        } else {
            let attributed = NSMutableAttributedString(string: text)
            let key = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
            let bounds = NSRange(location: 0, length: attributed.length)
            for hint in pronunciationHints {
                let range = NSIntersectionRange(hint.range, bounds)
                guard range.length > 0 else { continue }
                attributed.addAttribute(key, value: hint.ipa, range: range)
            }
            utterance = AVSpeechUtterance(attributedString: attributed)
        }
        utterance.rate = utteranceRate(forUIRate: rate)
        return utterance
    }

    /// Maps the UI rate (0.10–0.65, where 0.5 is "normal") onto an `AVSpeechUtterance` rate
    /// centered on the system default, then clamps to the supported range.
    static func utteranceRate(forUIRate uiRate: Float) -> Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * (uiRate / 0.5)
        return max(AVSpeechUtteranceMinimumSpeechRate, min(scaled, AVSpeechUtteranceMaximumSpeechRate))
    }

    private func estimatedDuration(for text: String) -> TimeInterval {
        let characterCount = max(text.count, 1)
        let baseCharactersPerSecond = 5.5 * max(Double(lastRate) / 0.5, 0.5)
        return max(Double(characterCount) / baseCharactersPerSecond, 0.5)
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "System TTS Playback") { [weak self] in
            ttsLog("[TTS][SystemEngine] background task expired")
            self?.endBackgroundTask()
        }
        ttsLog("[TTS][SystemEngine] background task started id=\(backgroundTask.rawValue)")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        ttsLog("[TTS][SystemEngine] background task ended id=\(backgroundTask.rawValue)")
        backgroundTask = .invalid
    }

    deinit {
        playbackToken = UUID()
        resetPlaybackState()
    }
}

extension SystemTTSEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.activeUtterance else { return }
            // `characterRange` is relative to this utterance's string; add the utterance's base
            // offset to track how far into the full chunk we've reached.
            self.spokenUTF16Offset = self.utteranceBaseOffset + characterRange.location
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.activeUtterance else { return }
            self.handlePlaybackEnded()
        }
    }

    // didCancel is intentionally unhandled: cancellation only happens when we stop or jump,
    // and those paths drive the next utterance themselves.
}
