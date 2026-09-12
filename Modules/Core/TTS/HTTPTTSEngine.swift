import YueduCoreText
import AVFoundation
import Foundation
import UIKit

// MARK: - HTTP TTS Engine (chunked download + preload + rate-shifted chunk playback)

/// URL template supports placeholders: {{text}}, {{title}}, {{speakSpeed}}
final class HTTPTTSEngine: NSObject, TTSPlayable, @unchecked Sendable {

    /// Whether a failed download is one the listener is actually waiting to hear, as opposed
    /// to a preload for a segment further ahead (which the normal preload path retries on its
    /// own when playback reaches it).
    static func shouldStopAfterCurrentChunkFailure(
        isCurrentRequest: Bool,
        isPendingPlayback: Bool
    ) -> Bool {
        isCurrentRequest || isPendingPlayback
    }

    var isPlaying: Bool = false
    var onPageFinished: (() -> TTSNextUnitOutcome)?
    var onStop: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onSegmentSkipped: ((Error) -> Void)?
    var onPlaybackStarted: ((TimeInterval) -> Void)?
    var onSegmentChanged: ((TTSActiveSegment) -> Void)?
    /// Speaker → voice, scoped to the open book by the reader. Empty = single voice.
    var roleVoices: [String: String] = [:]

    /// Set while the host prepares the next chapter; the same keep-alive silence that covers
    /// chunk-download gaps carries the session through this longer wait.
    private(set) var isWaitingForNextUnit = false
    /// Next chapter that arrived while the listener had playback paused. Held rather than
    /// played, so content becoming ready never overrides an explicit pause; `resume` plays it.
    private var pendingUnit: TTSNarrationUnit?

    /// One reusable graph is kept across chunk boundaries. The index prevents a paused
    /// session after a seek/new chapter from accidentally resuming the previous chunk.
    private var audioPlayer: TTSChunkAudioPlayer?
    private var loadedPlayerIndex: Int?
    private var audioProvider: TTSAudioProvider
    private let injectedAudioProvider: TTSAudioProvider?
    private struct DownloadTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var activeTasks: [Int: DownloadTask] = [:]
    /// A failed speculative request is retried only when playback actually needs it.
    private var failedPreloads: Set<Int> = []
    private var audioCache: [Int: Data] = [:]
    private var segments: [TTSSpeakableSegment] = []
    /// Ruby-substituted text actually sent to the provider, derived from `segments`
    /// in one `map` so the two can never fall out of step.
    private var speechChunks: [String] = []
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
    /// Playback offset (seconds into the current chunk) captured at `pause`, so a resume that
    /// has to reload cached bytes can seek back instead of replaying the whole sentence.
    private var resumePlaybackTime: TimeInterval = 0

    /// Keeps the audio session emitting samples during the gap between one chunk finishing
    /// and the next being downloaded/ready, and across a chapter-boundary wait. Without it
    /// there is no active audio output and iOS may suspend the app while backgrounded /
    /// locked — playback stalling mid-book with the mini-player still showing "playing"
    /// until the device is unlocked.
    private let silence = TTSSilenceKeepAlive()

    // Keep at least three segments ready, and enough lookahead to use the selected
    // concurrency after the current audio starts playing.
    private var preloadWindow: Int { max(3, maxConcurrentDownloads) }
    private var maxConcurrentDownloads = 2
    private let maxDownloadRetries = 2
    // Read by paragraph. Larger than before so a normal paragraph is one continuous
    // request instead of being chopped at every sentence; still bounded to keep each
    // cloud-TTS request (and its first-audio latency) reasonable.
    private let targetChunkLength = 300

    init(audioProvider: TTSAudioProvider? = nil) {
        self.injectedAudioProvider = audioProvider
        self.audioProvider = audioProvider ?? CustomHTTPProvider()
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
        // Snapshot per narration unit; changing settings never cancels audible work.
        maxConcurrentDownloads = GlobalSettings.shared.ttsPreSynthesisConcurrency
        do {
            // Capture the voice for this narration unit so queued preloads cannot change
            // voice when the settings screen edits the selection mid-request.
            audioProvider = try injectedAudioProvider ?? TTSAudioProviderSelection.make(
                template: GlobalSettings.shared.httpTtsUrlTemplate,
                isDirectChapterAudio: isDirectChapterAudio
            )
        } catch {
            onError?(error)
            return
        }
        segments = isDirectChapterAudio
            ? [TTSSpeakableSegment(
                text: text,
                sourceRange: NSRange(location: 0, length: (text as NSString).length)
              )]
            : TTSPronunciationProjector.segments(
                text,
                targetLength: targetChunkLength,
                hints: pronunciationHints,
                // Only 微軟線上語音 can change voice between segments; a book-source
                // template bakes its voice into the URL, so splitting buys nothing.
                multiRole: audioProvider is EdgeTTSAudioProvider
                    && TTSRoleVoiceCast.containsSpeakableVoice(in: roleVoices, system: false)
            )
        speechChunks = segments.map {
            TTSPronunciationSpeechText(text: $0.text, hints: $0.pronunciationHints).text
        }
        guard !segments.isEmpty else {
            ttsLog("[TTS][HTTPEngine] speak aborted no chunks")
            return
        }

        playbackToken = UUID()
        lastTitle = title
        lastRate = rate
        serverControlsSpeed = !isDirectChapterAudio
            && (audioProvider is EdgeTTSAudioProvider
                || GlobalSettings.shared.httpTtsUrlTemplate.contains("speakSpeed"))
        currentIndex = 0
        isPaused = false
        isPlaying = true
        beginBackgroundTask()

        ttsLog("[TTS][HTTPEngine] chunked count=\(segments.count) firstCount=\(segments.first?.text.count ?? 0)")
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

        if loadedPlayerIndex == currentIndex, let audioPlayer, audioPlayer.hasLoadedAudio {
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
        if isPlaying {
            startPreloading(token: playbackToken)
        }
    }

    /// Rebuilds the reusable audio graph after iOS reports that its media services were
    /// reset. The HTTP bytes remain cached, so recovery does not create another network
    /// request or restart the current chunk from its beginning.
    func recoverAfterAudioSessionReset() {
        guard isPlaying, !isPaused else { return }
        if isWaitingForNextUnit {
            silence.restart()
            return
        }
        guard let data = audioCache[currentIndex] else {
            playChunk(at: currentIndex, token: playbackToken)
            return
        }
        let resumeAt = audioPlayer?.currentTime ?? resumePlaybackTime
        ttsLog("[TTS][HTTPEngine] recovering after media-services reset index=\(currentIndex) offset=\(resumeAt)")
        resumeCachedChunk(data, at: currentIndex, from: resumeAt, token: playbackToken)
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
        guard !segments.isEmpty else { return }
        ttsLog("[TTS][HTTPEngine] updateRate live rate=\(rate) serverControlsSpeed=\(serverControlsSpeed) index=\(currentIndex)")

        if !serverControlsSpeed {
            // The audio bytes are rate-independent; retune the live player and keep the cache.
            audioPlayer?.rate = clientPlaybackRate
            return
        }

        // Server-synthesized audio embeds the old speed, so everything downloaded so far is
        // stale: drop it and re-synthesize from the current chunk at the new speed.
        invalidateDownloads()
        failedPreloads.removeAll()
        audioCache.removeAll()
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        loadedPlayerIndex = nil
        audioPlayer?.clear()
        if isPlaying {
            playChunk(at: currentIndex, token: playbackToken)
        }
        // A paused session re-fetches naturally on resume, because the cache is now empty.
    }

    func skipForward() {
        ttsLog("[TTS][HTTPEngine] skipForward requested index=\(currentIndex) count=\(segments.count)")
        guard !segments.isEmpty else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < segments.count else {
            handlePageChunksFinished(token: playbackToken)
            return
        }
        jumpToChunk(at: nextIndex)
    }

    func skipBackward() {
        ttsLog("[TTS][HTTPEngine] skipBackward requested index=\(currentIndex) count=\(segments.count)")
        guard !segments.isEmpty else { return }
        jumpToChunk(at: max(currentIndex - 1, 0))
    }

    func seekToSegment(_ index: Int) {
        guard !segments.isEmpty else { return }
        let targetIndex = max(0, min(index, segments.count - 1))
        ttsLog("[TTS][HTTPEngine] seekToSegment requested index=\(targetIndex) current=\(currentIndex) isPlaying=\(isPlaying) isPaused=\(isPaused)")

        if isPlaying {
            jumpToChunk(at: targetIndex)
            return
        }

        invalidateDownloads()
        audioPlayer?.stop()
        loadedPlayerIndex = nil
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        currentIndex = targetIndex
        isPaused = true
        publishSegmentChanged(index: targetIndex)

        if audioCache[targetIndex] == nil {
            downloadChunk(at: targetIndex, token: playbackToken, priority: .preload)
        }
        startPreloading(token: playbackToken)
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
        guard index < segments.count else {
            handlePageChunksFinished(token: token)
            return
        }

        currentIndex = index
        publishSegmentChanged(index: index)

        if let data = audioCache[index] {
            ttsLog("[TTS][HTTPEngine] playChunk cached index=\(index) bytes=\(data.count)")
            startPreloading(token: token)
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
        startPreloading(token: token)
    }

    private func startPreloading(token: UUID) {
        guard token == playbackToken, !segments.isEmpty, !isPaused else { return }
        // Download completion does not move the playback cursor. Basing this window on
        // the completed download recursively synthesized the rest of the chapter.
        let index = currentIndex + 1
        let end = min(segments.count, index + preloadWindow)
        guard index < end else { return }

        for preloadIndex in index..<end {
            guard activeTasks.count < maxConcurrentDownloads else { return }
            guard audioCache[preloadIndex] == nil, activeTasks[preloadIndex] == nil,
                  !failedPreloads.contains(preloadIndex) else { continue }
            downloadChunk(at: preloadIndex, token: token, priority: .preload)
        }
    }

    private enum DownloadPriority {
        case current
        case preload
    }

    /// Which provider synthesizes one segment.
    ///
    /// 多角色朗讀 swaps the voice per segment, which on this engine means a different
    /// provider instance per request — an Edge request carries its voice in the SSML it
    /// sends, so the voice is fixed the moment the request is built and cannot be changed
    /// for a request already in flight. Building a fresh provider per segment is therefore
    /// the only way to switch, and it is cheap: `EdgeTTSAudioProvider` is a value holding a
    /// voice and a stateless transport.
    ///
    /// Everything else — a book-source template, direct chapter audio — keeps the provider
    /// captured for this narration unit. Those bake the voice into a URL the user imported,
    /// so there is no second voice to switch to.
    private func provider(forSegmentAt index: Int) -> any TTSAudioProvider {
        guard injectedAudioProvider == nil,
              audioProvider is EdgeTTSAudioProvider,
              segments.indices.contains(index),
              let speaker = segments[index].speaker,
              let stored = roleVoices[speaker],
              let voice = TTSRoleVoice(storageValue: stored)?.edgeVoice
        else {
            return audioProvider
        }
        return EdgeTTSAudioProvider(voice: voice)
    }

    private func downloadChunk(at index: Int, token: UUID, priority: DownloadPriority) {
        guard token == playbackToken, index < segments.count else { return }
        if audioCache[index] != nil { return }
        if activeTasks[index] != nil {
            if priority == .current {
                pendingPlaybackIndex = index
                ttsLog("[TTS][HTTPEngine] download already active; marked pending index=\(index)")
            }
            return
        }

        // Give the audible segment a slot before speculative work, including after a
        // failed preload. Its replacement gets a new ID, so a late completion cannot
        // remove or populate the replacement request.
        if priority == .current, activeTasks.count >= maxConcurrentDownloads,
           let farthest = activeTasks.keys.filter({ $0 != currentIndex }).max() {
            activeTasks.removeValue(forKey: farthest)?.task.cancel()
        }
        guard activeTasks.count < maxConcurrentDownloads else { return }

        let requestID = UUID()
        let chunkText = speechChunks[index]
        let title = lastTitle
        let rate = lastRate
        let audioProvider = provider(forSegmentAt: index)
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
                    self.handleDownloadedData(data, index: index, token: token, requestID: requestID, priority: priority)
                }
            } catch {
                // Only our own cancellation retires a request silently. A provider can
                // independently cancel its transport; leaving that entry active forever
                // would leave playback waiting for a completion that will never arrive.
                guard !Task.isCancelled else {
                    ttsLog("[TTS][HTTPEngine] provider request cancelled index=\(index)")
                    return
                }
                DispatchQueue.main.async {
                    self.handleDownloadFailure(error, index: index, token: token, requestID: requestID, priority: priority)
                }
            }
        }

        activeTasks[index] = DownloadTask(id: requestID, task: task)
    }

    private func fetchAudioDataWithRetry(
        provider: TTSAudioProvider,
        text: String,
        title: String,
        rate: Float,
        index: Int
    ) async throws -> Data {
        // Edge returns explicit protocol/service failures. Surface them without the legacy
        // imported-source retry delay; retrying an incompatible handshake cannot repair it.
        if provider is EdgeTTSAudioProvider {
            return try await provider.audioData(for: text, title: title, rate: rate)
        }
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
                // Only transient transport failures can recover by sending the same text
                // again. Invalid credentials, source scripts and undecodable payloads need
                // correction, not repeated requests followed by an omitted paragraph.
                guard let networkError = error as? URLError,
                      [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(networkError.code),
                      attempt < maxDownloadRetries else { break }
                ttsLog("[TTS][HTTPEngine] provider retry index=\(index) attempt=\(attempt + 1)/\(maxDownloadRetries) error=\(error.localizedDescription)")
                // Bounded backoff for the transport failures above, not a state-settling
                // delay. Remove if the provider takes ownership of transport retries.
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw lastError ?? TTSAudioProviderError.emptyData
    }

    private func handleDownloadedData(
        _ data: Data,
        index: Int,
        token: UUID,
        requestID: UUID,
        priority: DownloadPriority
    ) {
        guard token == playbackToken, activeTasks[index]?.id == requestID else {
            ttsLog("[TTS][HTTPEngine] provider result ignored stale token index=\(index)")
            return
        }
        activeTasks[index] = nil

        let isPendingPlayback = pendingPlaybackIndex == index && currentIndex == index
        audioCache[index] = data
        failedPreloads.remove(index)
        ttsLog("[TTS][HTTPEngine] provider result success index=\(index) bytes=\(data.count)")

        if (priority == .current || isPendingPlayback),
           currentIndex == index,
           audioPlayer?.isPlaying != true,
           !isPaused {
            pendingPlaybackIndex = nil
            playChunk(at: index, token: token)
        } else {
            startPreloading(token: token)
        }
    }

    private func handleDownloadFailure(
        _ error: Error,
        index: Int,
        token: UUID,
        requestID: UUID,
        priority: DownloadPriority
    ) {
        guard token == playbackToken, activeTasks[index]?.id == requestID else {
            ttsLog("[TTS][HTTPEngine] provider failure ignored stale token index=\(index)")
            return
        }
        activeTasks[index] = nil
        failedPreloads.insert(index)

        let isPendingPlayback = pendingPlaybackIndex == index && currentIndex == index
        ttsLog("[TTS][HTTPEngine] provider request failed index=\(index) error=\(error.localizedDescription)")
        guard currentIndex == index, Self.shouldStopAfterCurrentChunkFailure(
            isCurrentRequest: priority == .current,
            isPendingPlayback: isPendingPlayback
        ) else {
            // A preload that failed for a segment further ahead: playback will request it
            // again through `playChunk` when it gets there, so nothing is lost yet.
            startPreloading(token: token)
            return
        }

        pendingPlaybackIndex = nil
        pauseForChunkFailure(index: index, token: token, error: error)
    }

    /// Keep the failed segment as the next audible one. Resume retries this exact text;
    /// neither a failed download nor invalid audio counts as having read a paragraph.
    private func pauseForChunkFailure(index: Int, token: UUID, error: Error) {
        guard token == playbackToken, currentIndex == index else { return }
        pause()
        invalidateDownloads()
        audioCache[index] = nil
        loadedPlayerIndex = nil
        resumePlaybackTime = 0
        audioPlayer?.clear()
        AppLogger.error(
            "[TTS] 段落取得失敗，保留位置並暫停",
            context: [
                "index": index,
                "reason": String(describing: error)
            ],
            level: .warning
        )
        onError?(TTSPlaybackError.chunkUnavailable(index: index, underlying: error))
    }

    /// End the session with a visible error when the audio graph itself cannot continue.
    private func failPlayback(_ error: Error, token: UUID) {
        guard token == playbackToken else { return }
        ttsLog("[TTS][HTTPEngine] playback failed error=\(error.localizedDescription)")
        resetPlaybackState()
        onError?(error)
        onStop?()
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
            stopSilence()   // real audio is about to play; stop the keep-alive silence

            let player = audioPlayer ?? TTSChunkAudioPlayer()
            player.delegate = self
            try player.load(data: data)
            player.rate = clientPlaybackRate
            audioPlayer = player
            loadedPlayerIndex = index

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] play submitted index=\(index) success=\(success) duration=\(player.duration) rate=\(player.rate)")

            if !success {
                failPlayback(TTSPlaybackError.playbackFailed(index: index), token: token)
            } else {
                // Wall-clock length, so the Now Playing clock matches what is heard.
                onPlaybackStarted?(player.effectiveDuration)
            }
        } catch {
            // The bytes, not just the error: a rate-limit page, a JSON quota notice and a
            // truncated body all surface as the same opaque `kAudioFileError_InvalidFile`
            // ('dta?', 1685348671). `TTSAudioProvider` now rejects non-audio payloads before
            // they are cached, so reaching here means something got past that — and this is
            // the only line that can say what, on a device, from a locked screen.
            ttsLog("[TTS][HTTPEngine] player init failed index=\(index) error=\(error.localizedDescription) payload=\(TTSAudioPayload.diagnosticHead(of: data))")
            audioCache[index] = nil
            pauseForChunkFailure(index: index, token: token, error: error)
        }
    }

    /// Rebuilds the chunk player for the already-cached current chunk and seeks to `time`,
    /// so a resume after the OS discarded the paused player continues mid-sentence.
    private func resumeCachedChunk(_ data: Data, at index: Int, from time: TimeInterval, token: UUID) {
        guard token == playbackToken else { return }
        do {
            stopSilence()   // real audio is about to play; stop the keep-alive silence

            let player = audioPlayer ?? TTSChunkAudioPlayer()
            player.delegate = self
            try player.load(data: data)
            player.rate = clientPlaybackRate
            player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
            audioPlayer = player
            loadedPlayerIndex = index
            currentIndex = index

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] resume cached chunk index=\(index) seekTo=\(time) duration=\(player.duration) success=\(success)")
            if success {
                onPlaybackStarted?(player.effectiveDuration)
            } else {
                failPlayback(TTSPlaybackError.playbackFailed(index: index), token: token)
            }
        } catch {
            ttsLog("[TTS][HTTPEngine] resume cached chunk failed index=\(index) error=\(error.localizedDescription)")
            pauseForChunkFailure(index: index, token: token, error: error)
        }
    }

    private func jumpToChunk(at index: Int) {
        guard index >= 0, index < segments.count else { return }
        invalidateDownloads()
        audioPlayer?.stop()
        loadedPlayerIndex = nil
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
        guard segments.indices.contains(index) else { return }
        onSegmentChanged?(TTSActiveSegment(
            index: index,
            total: segments.count,
            text: segments[index].text,
            narrationRange: segments[index].sourceRange
        ))
    }

    private func handlePlaybackEnded(successfully flag: Bool) {
        let finishedIndex = currentIndex
        ttsLog("[TTS][HTTPEngine] playback ended index=\(finishedIndex) successfully=\(flag)")
        guard flag else {
            failPlayback(TTSPlaybackError.playbackFailed(index: finishedIndex), token: playbackToken)
            return
        }

        guard isPlaying, !isPaused else { return }
        playChunk(at: finishedIndex + 1, token: playbackToken)
    }

    private func handlePageChunksFinished(token: UUID) {
        guard token == playbackToken else { return }
        ttsLog("[TTS][HTTPEngine] page chunks finished count=\(segments.count)")

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
        audioPlayer?.stop()
        loadedPlayerIndex = nil
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

    private func invalidateDownloads() {
        playbackToken = UUID()
        activeTasks.values.forEach { $0.task.cancel() }
        activeTasks.removeAll()
        pendingPlaybackIndex = nil
    }

    private func resetPlaybackState() {
        invalidateDownloads()
        isWaitingForNextUnit = false
        pendingUnit = nil
        failedPreloads.removeAll()
        audioCache.removeAll()
        segments.removeAll()
        speechChunks.removeAll()
        currentIndex = 0
        isPaused = false
        pendingPlaybackIndex = nil
        resumePlaybackTime = 0
        isPlaying = false
        loadedPlayerIndex = nil
        audioPlayer?.clear()
        stopSilence()
        endBackgroundTask()
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
    // Decode failures surface from `TTSChunkAudioPlayer.load(data:)` before playback starts;
    // current-chunk failures are reported to the coordinator instead of being skipped.
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool) {
        // The player validates its schedule token and calls us on the main queue. Another
        // async hop here allowed a seek/new chunk to land between that validation and this
        // cursor advance, turning the previous chunk's completion into a skipped new chunk.
        guard player === audioPlayer else { return }
        handlePlaybackEnded(successfully: flag)
    }
}
