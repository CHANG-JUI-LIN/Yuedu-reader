import AVFoundation
import Foundation
import UIKit

// MARK: - HTTP TTS Engine (chunked download + preload + rate-shifted chunk playback)

/// URL template supports placeholders: {{text}}, {{title}}, {{speakSpeed}}
final class HTTPTTSEngine: NSObject, TTSPlayable, @unchecked Sendable {

    var isPlaying: Bool = false
    var onPageFinished: (() -> TTSNextUnitOutcome)?
    var onStop: (() -> Void)?
    var onPlaybackStarted: ((TimeInterval) -> Void)?
    var onSegmentChanged: ((Int, Int, String) -> Void)?

    /// Set while the host prepares the next chapter; the same keep-alive silence that covers
    /// chunk-download gaps carries the session through this longer wait.
    private(set) var isWaitingForNextUnit = false
    /// Next chapter that arrived while the listener had playback paused. Held rather than
    /// played, so content becoming ready never overrides an explicit pause; `resume` plays it.
    private var pendingUnit: TTSNarrationUnit?

    private var audioPlayer: TTSChunkAudioPlayer?
    private let audioProvider: TTSAudioProvider
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    private var audioCache: [Int: Data] = [:]
    private var chunks: [String] = []
    private var currentIndex = 0
    private var playbackToken = UUID()
    private var lastTitle = ""
    private var lastRate: Float = 0.5
    private var isPaused = false
    /// Whether the active template embeds `speakSpeed`, i.e. the server bakes the speed into
    /// the synthesized audio. When it doesn't (plain templates, direct chapter audio), the
    /// speed is applied client-side via `AVAudioPlayer.rate` instead.
    private var serverControlsSpeed = false
    private var pendingPlaybackIndex: Int?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Playback offset (seconds into the current chunk) captured at `pause`, so that a resume
    /// which has to rebuild the player — because the OS tore `audioPlayer` down while paused
    /// (interruption, backgrounding, or the chunk finishing during the pause) — can seek back
    /// instead of replaying the whole ~5s sentence from its start.
    private var resumePlaybackTime: TimeInterval = 0

    /// Keeps the audio session emitting samples during the gap between one chunk finishing
    /// and the next being downloaded/ready, and across a chapter-boundary wait. Without it
    /// there is no active audio output and iOS may suspend the app while backgrounded /
    /// locked — playback stalling mid-book with the mini-player still showing "playing"
    /// until the device is unlocked.
    private let silence = TTSSilenceKeepAlive()

    private let preloadWindow = 3
    private let maxConcurrentDownloads = 2
    private let maxDownloadRetries = 2
    // Read by paragraph. Larger than before so a normal paragraph is one continuous
    // request instead of being chopped at every sentence; still bounded to keep each
    // cloud-TTS request (and its first-audio latency) reasonable.
    private let targetChunkLength = 300

    init(audioProvider: TTSAudioProvider = CustomHTTPProvider()) {
        self.audioProvider = audioProvider
        super.init()
    }

    // MARK: - TTSPlayable

    func configureAudioSessionOwnership(_ enabled: Bool) {
        ttsLog("[TTS][HTTPEngine] configureAudioSessionOwnership ignored enabled=\(enabled)")
    }

    func speak(
        text: String,
        title: String,
        rate: Float,
        pronunciationHints: [TTSPronunciationHint] = []
    ) {
        ttsLog("[TTS][HTTPEngine] speak requested textCount=\(text.count) title=\(title) rate=\(rate)")
        let isDirectChapterAudio = DirectChapterAudioResolver.request(from: text) != nil
        guard isDirectChapterAudio
            || !GlobalSettings.shared.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            ttsLog("[TTS][HTTPEngine] speak aborted empty template")
            return
        }

        resetPlaybackState()
        chunks = isDirectChapterAudio ? [text] : splitText(text)
        guard !chunks.isEmpty else {
            ttsLog("[TTS][HTTPEngine] speak aborted no chunks")
            return
        }

        playbackToken = UUID()
        lastTitle = title
        lastRate = rate
        serverControlsSpeed = !isDirectChapterAudio
            && GlobalSettings.shared.httpTtsUrlTemplate.contains("speakSpeed")
        currentIndex = 0
        isPaused = false
        isPlaying = true
        beginBackgroundTask()

        ttsLog("[TTS][HTTPEngine] chunked count=\(chunks.count) firstCount=\(chunks.first?.count ?? 0)")
        playChunk(at: 0, token: playbackToken)
    }

    func pause() {
        ttsLog("[TTS][HTTPEngine] pause requested isPlaying=\(isPlaying) index=\(currentIndex) playerPlaying=\(audioPlayer?.isPlaying ?? false)")
        guard isPlaying else { return }
        audioPlayer?.pause()
        stopSilence()
        resumePlaybackTime = audioPlayer?.currentTime ?? 0
        isPaused = true
        isPlaying = false
        endBackgroundTask()
        ttsLog("[TTS][HTTPEngine] pause done currentTime=\(resumePlaybackTime)")
    }

    func resume() {
        ttsLog("[TTS][HTTPEngine] resume requested isPlaying=\(isPlaying) isPaused=\(isPaused) index=\(currentIndex) waiting=\(isWaitingForNextUnit)")
        guard !isPlaying, isPaused else { return }
        beginBackgroundTask()
        isPaused = false
        isPlaying = true

        // Paused while waiting on the next chapter. If it arrived during the pause, play it
        // now; otherwise go back to waiting rather than replaying the finished chapter.
        if isWaitingForNextUnit {
            if let unit = pendingUnit {
                pendingUnit = nil
                isWaitingForNextUnit = false
                ttsLog("[TTS][HTTPEngine] resume plays chapter held during pause")
                speak(text: unit.text, title: "", rate: lastRate, pronunciationHints: unit.pronunciationHints)
                return
            }
            startSilence()
            ttsLog("[TTS][HTTPEngine] resume back into waiting state")
            return
        }

        // Consume the saved offset once; a later resume must re-capture it at its own pause.
        let resumeTime = resumePlaybackTime
        resumePlaybackTime = 0

        if let audioPlayer {
            let success = audioPlayer.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] resume player success=\(success) currentTime=\(audioPlayer.currentTime)")
        } else if let data = audioCache[currentIndex], resumeTime > 0.1 {
            // The player was gone but the chunk audio is still cached: rebuild and seek back to
            // where we paused instead of re-reading the sentence from the top.
            resumeCachedChunk(data, at: currentIndex, from: resumeTime, token: playbackToken)
        } else {
            playChunk(at: currentIndex, token: playbackToken)
        }
    }

    func stop() {
        ttsLog("[TTS][HTTPEngine] stop requested")
        playbackToken = UUID()
        resetPlaybackState()
        onStop?()
    }

    func updateRate(_ rate: Float) {
        guard lastRate != rate else { return }
        lastRate = rate
        guard !chunks.isEmpty else { return }
        ttsLog("[TTS][HTTPEngine] updateRate live rate=\(rate) serverControlsSpeed=\(serverControlsSpeed) index=\(currentIndex)")

        if !serverControlsSpeed {
            // The audio bytes are rate-independent; retune the live player and keep the cache.
            audioPlayer?.rate = clientPlaybackRate
            return
        }

        // Server-synthesized audio embeds the old speed, so everything downloaded so far is
        // stale: drop it and re-synthesize from the current chunk at the new speed.
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        audioCache.removeAll()
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if isPlaying {
            playChunk(at: currentIndex, token: playbackToken)
        }
        // A paused session re-fetches naturally on resume, because the cache is now empty.
    }

    func skipForward() {
        ttsLog("[TTS][HTTPEngine] skipForward requested index=\(currentIndex) count=\(chunks.count)")
        guard !chunks.isEmpty else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < chunks.count else {
            handlePageChunksFinished(token: playbackToken)
            return
        }
        jumpToChunk(at: nextIndex)
    }

    func skipBackward() {
        ttsLog("[TTS][HTTPEngine] skipBackward requested index=\(currentIndex) count=\(chunks.count)")
        guard !chunks.isEmpty else { return }
        jumpToChunk(at: max(currentIndex - 1, 0))
    }

    func seekToSegment(_ index: Int) {
        guard !chunks.isEmpty else { return }
        let targetIndex = max(0, min(index, chunks.count - 1))
        ttsLog("[TTS][HTTPEngine] seekToSegment requested index=\(targetIndex) current=\(currentIndex) isPlaying=\(isPlaying) isPaused=\(isPaused)")

        if isPlaying {
            jumpToChunk(at: targetIndex)
            return
        }

        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        currentIndex = targetIndex
        isPaused = true
        publishSegmentChanged(index: targetIndex)

        if audioCache[targetIndex] == nil {
            downloadChunk(at: targetIndex, token: playbackToken, priority: .preload)
        }
        startPreloading(from: targetIndex + 1, token: playbackToken)
    }

    // MARK: - Queue

    private func playChunk(at index: Int, token: UUID) {
        guard token == playbackToken else {
            ttsLog("[TTS][HTTPEngine] playChunk ignored stale token index=\(index)")
            return
        }
        guard !isPaused else {
            ttsLog("[TTS][HTTPEngine] playChunk paused index=\(index)")
            return
        }
        guard index < chunks.count else {
            handlePageChunksFinished(token: token)
            return
        }

        currentIndex = index
        publishSegmentChanged(index: index)

        if let data = audioCache[index] {
            ttsLog("[TTS][HTTPEngine] playChunk cached index=\(index) bytes=\(data.count)")
            startPreloading(from: index + 1, token: token)
            playAudioData(data, index: index, token: token)
            return
        }

        // Cache miss: real audio won't emit until the download lands. Start the silence
        // keep-alive so the audio session keeps producing samples and iOS doesn't suspend
        // the app while locked (the "locks after a while, resumes on unlock" bug).
        startSilence()

        if activeTasks[index] != nil {
            pendingPlaybackIndex = index
            ttsLog("[TTS][HTTPEngine] playChunk pending active preload index=\(index)")
            return
        }

        ttsLog("[TTS][HTTPEngine] playChunk waiting download index=\(index)")
        downloadChunk(at: index, token: token, priority: .current)
        startPreloading(from: index + 1, token: token)
    }

    private func startPreloading(from index: Int, token: UUID) {
        guard token == playbackToken, !chunks.isEmpty else { return }
        let end = min(chunks.count, index + preloadWindow)
        guard index < end else { return }

        for preloadIndex in index..<end {
            guard activeTasks.count < maxConcurrentDownloads else { return }
            guard audioCache[preloadIndex] == nil, activeTasks[preloadIndex] == nil else { continue }
            downloadChunk(at: preloadIndex, token: token, priority: .preload)
        }
    }

    private enum DownloadPriority {
        case current
        case preload
    }

    private func downloadChunk(at index: Int, token: UUID, priority: DownloadPriority) {
        guard token == playbackToken, index < chunks.count else { return }
        if audioCache[index] != nil { return }
        if activeTasks[index] != nil {
            if priority == .current {
                pendingPlaybackIndex = index
                ttsLog("[TTS][HTTPEngine] download already active; marked pending index=\(index)")
            }
            return
        }

        let chunkText = chunks[index]
        let title = lastTitle
        let rate = lastRate
        ttsLog("[TTS][HTTPEngine] provider request start index=\(index) provider=\(audioProvider.displayName) priority=\(priority) textCount=\(chunkText.count)")
        let task = Task { [weak self, audioProvider] in
            guard let self else { return }
            do {
                let data = try await self.fetchAudioDataWithRetry(
                    provider: audioProvider,
                    text: chunkText,
                    title: title,
                    rate: rate,
                    index: index
                )
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    self.handleDownloadedData(data, index: index, token: token, priority: priority)
                }
            } catch is CancellationError {
                ttsLog("[TTS][HTTPEngine] provider request cancelled index=\(index)")
            } catch let error as URLError where error.code == .cancelled {
                ttsLog("[TTS][HTTPEngine] provider request cancelled index=\(index)")
            } catch {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    self.handleDownloadFailure(error, index: index, token: token, priority: priority)
                }
            }
        }

        activeTasks[index] = task
    }

    private func fetchAudioDataWithRetry(
        provider: TTSAudioProvider,
        text: String,
        title: String,
        rate: Float,
        index: Int
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0...maxDownloadRetries {
            do {
                return try await provider.audioData(for: text, title: title, rate: rate)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                lastError = error
                guard attempt < maxDownloadRetries else { break }
                ttsLog("[TTS][HTTPEngine] provider retry index=\(index) attempt=\(attempt + 1)/\(maxDownloadRetries) error=\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw lastError ?? TTSAudioProviderError.emptyData
    }

    private func handleDownloadedData(
        _ data: Data,
        index: Int,
        token: UUID,
        priority: DownloadPriority
    ) {
        activeTasks[index] = nil
        guard token == playbackToken else {
            ttsLog("[TTS][HTTPEngine] provider result ignored stale token index=\(index)")
            return
        }

        let isPendingPlayback = pendingPlaybackIndex == index && currentIndex == index
        audioCache[index] = data
        ttsLog("[TTS][HTTPEngine] provider result success index=\(index) bytes=\(data.count)")

        if (priority == .current || isPendingPlayback), currentIndex == index, audioPlayer == nil, !isPaused {
            pendingPlaybackIndex = nil
            playChunk(at: index, token: token)
        } else {
            startPreloading(from: index + 1, token: token)
        }
    }

    private func handleDownloadFailure(
        _ error: Error,
        index: Int,
        token: UUID,
        priority: DownloadPriority
    ) {
        activeTasks[index] = nil
        guard token == playbackToken else {
            ttsLog("[TTS][HTTPEngine] provider failure ignored stale token index=\(index)")
            return
        }

        let isPendingPlayback = pendingPlaybackIndex == index && currentIndex == index
        ttsLog("[TTS][HTTPEngine] provider request failed index=\(index) error=\(error.localizedDescription)")
        if priority == .current || isPendingPlayback {
            pendingPlaybackIndex = nil
            playChunk(at: index + 1, token: token)
        } else {
            startPreloading(from: index + 1, token: token)
        }
    }

    // MARK: - Playback

    /// Client-side playback rate: 1.0 when the source synthesizes at the requested speed
    /// itself; otherwise the UI rate (0.5 == 100%) as a plain multiplier. No 2.0 ceiling
    /// any more — `TTSChunkAudioPlayer` replaced `AVAudioPlayer`, whose documented
    /// 0.5–2.0 `rate` range silently swallowed everything above 200%.
    private var clientPlaybackRate: Float {
        serverControlsSpeed ? 1.0 : lastRate / 0.5
    }

    private func playAudioData(_ data: Data, index: Int, token: UUID) {
        guard token == playbackToken else {
            ttsLog("[TTS][HTTPEngine] play ignored stale token index=\(index)")
            return
        }

        do {
            audioPlayer?.delegate = nil
            audioPlayer?.stop()
            stopSilence()   // real audio is about to play; stop the keep-alive silence

            let player = try TTSChunkAudioPlayer(data: data)
            player.delegate = self
            player.rate = clientPlaybackRate
            audioPlayer = player

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] play submitted index=\(index) success=\(success) duration=\(player.duration) rate=\(player.rate)")

            if !success {
                playChunk(at: index + 1, token: token)
            } else {
                // Wall-clock length, so the Now Playing clock matches what is heard.
                onPlaybackStarted?(player.effectiveDuration)
            }
        } catch {
            ttsLog("[TTS][HTTPEngine] player init failed index=\(index) error=\(error.localizedDescription)")
            playChunk(at: index + 1, token: token)
        }
    }

    /// Rebuilds the chunk player for the already-cached current chunk and seeks to `time`,
    /// so a resume after the OS discarded the paused player continues mid-sentence rather than
    /// replaying it. Falls back to the normal `playChunk` path on any failure.
    private func resumeCachedChunk(_ data: Data, at index: Int, from time: TimeInterval, token: UUID) {
        guard token == playbackToken else { return }
        do {
            audioPlayer?.delegate = nil
            audioPlayer?.stop()
            stopSilence()   // real audio is about to play; stop the keep-alive silence

            let player = try TTSChunkAudioPlayer(data: data)
            player.delegate = self
            player.rate = clientPlaybackRate
            player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
            audioPlayer = player
            currentIndex = index

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] resume cached chunk index=\(index) seekTo=\(time) duration=\(player.duration) success=\(success)")
            if success {
                onPlaybackStarted?(player.effectiveDuration)
            } else {
                playChunk(at: index, token: token)
            }
        } catch {
            ttsLog("[TTS][HTTPEngine] resume cached chunk failed index=\(index) error=\(error.localizedDescription)")
            playChunk(at: index, token: token)
        }
    }

    private func jumpToChunk(at index: Int) {
        guard index >= 0, index < chunks.count else { return }
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        currentIndex = index
        publishSegmentChanged(index: index)

        isPaused = false
        isPlaying = true
        beginBackgroundTask()
        playChunk(at: index, token: playbackToken)
    }

    private func publishSegmentChanged(index: Int) {
        guard chunks.indices.contains(index) else { return }
        onSegmentChanged?(index, chunks.count, chunks[index])
    }

    private func handlePlaybackEnded(successfully flag: Bool) {
        let finishedIndex = currentIndex
        ttsLog("[TTS][HTTPEngine] playback ended index=\(finishedIndex) successfully=\(flag)")
        audioPlayer?.delegate = nil
        audioPlayer = nil

        guard isPlaying, !isPaused else { return }
        playChunk(at: finishedIndex + 1, token: playbackToken)
    }

    private func handlePageChunksFinished(token: UUID) {
        guard token == playbackToken else { return }
        ttsLog("[TTS][HTTPEngine] page chunks finished count=\(chunks.count)")

        switch onPageFinished?() ?? .finished {
        case let .ready(next) where !next.text.isEmpty:
            speak(
                text: next.text,
                title: "",
                rate: lastRate,
                pronunciationHints: next.pronunciationHints
            )
        case .waiting:
            enterWaitingForNextUnit()
        case .ready, .finished:
            resetPlaybackState()
            onStop?()
        }
    }

    /// Hold the session open while the host fetches + lays out the next chapter, exactly as
    /// the chunk-gap path does: background task claimed, looped silence emitting, no stop.
    private func enterWaitingForNextUnit() {
        guard !isWaitingForNextUnit else { return }
        isWaitingForNextUnit = true
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = true
        beginBackgroundTask()
        startSilence()
        ttsLog("[TTS][HTTPEngine] waiting for next unit")
    }

    func supplyPendingUnit(_ unit: TTSNarrationUnit) {
        guard isWaitingForNextUnit else {
            ttsLog("[TTS][HTTPEngine] supplyPendingUnit ignored not waiting")
            return
        }
        guard !unit.text.isEmpty else {
            ttsLog("[TTS][HTTPEngine] supplyPendingUnit empty text; stopping")
            isWaitingForNextUnit = false
            resetPlaybackState()
            onStop?()
            return
        }
        guard !isPaused else {
            ttsLog("[TTS][HTTPEngine] supplyPendingUnit held; playback is paused")
            pendingUnit = unit
            return
        }
        ttsLog("[TTS][HTTPEngine] supplyPendingUnit resuming textCount=\(unit.text.count)")
        isWaitingForNextUnit = false
        // `speak` resets state and mints a fresh token — the wait IS the chapter boundary.
        speak(text: unit.text, title: "", rate: lastRate, pronunciationHints: unit.pronunciationHints)
    }

    private func resetPlaybackState() {
        isWaitingForNextUnit = false
        pendingUnit = nil
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        audioCache.removeAll()
        chunks.removeAll()
        currentIndex = 0
        isPaused = false
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        isPlaying = false
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        stopSilence()
        endBackgroundTask()
    }

    // MARK: - Text splitting

    private func splitText(_ text: String) -> [String] {
        TTSTextChunker.split(text, targetChunkLength: targetChunkLength)
    }

    // MARK: - Silence keep-alive

    /// Start emitting looped silence so the audio session has active output while waiting
    /// for the next chunk to download. Idempotent and only while not paused.
    private func startSilence() {
        guard !isPaused else { return }
        silence.start()
    }

    /// Stop the keep-alive silence. Called when real chunk playback begins, on pause, stop, and reset.
    private func stopSilence() {
        silence.stop()
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HTTP TTS Playback") { [weak self] in
            ttsLog("[TTS][HTTPEngine] background task expired")
            self?.endBackgroundTask()
        }
        ttsLog("[TTS][HTTPEngine] background task started id=\(backgroundTask.rawValue)")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        ttsLog("[TTS][HTTPEngine] background task ended id=\(backgroundTask.rawValue)")
        backgroundTask = .invalid
    }

    deinit {
        playbackToken = UUID()
        resetPlaybackState()
    }
}

extension HTTPTTSEngine: TTSChunkAudioPlayerDelegate {
    // Decode failures now surface as a throw from `TTSChunkAudioPlayer(data:)` (AVAudioFile
    // parses the container up front) and are handled by the `catch` in `playAudioData` /
    // `resumeCachedChunk`, which logs and skips to the next chunk — the same recovery the
    // old `audioPlayerDecodeErrorDidOccur` performed.
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handlePlaybackEnded(successfully: flag)
        }
    }
}
