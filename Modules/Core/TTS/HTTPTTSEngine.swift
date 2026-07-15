import AVFoundation
import Foundation
import UIKit

// MARK: - HTTP TTS Engine (chunked download + preload + AVAudioPlayer playback)

/// URL template supports placeholders: {{text}}, {{title}}, {{speakSpeed}}
final class HTTPTTSEngine: NSObject, TTSPlayable, @unchecked Sendable {

    var isPlaying: Bool = false
    var onPageFinished: (() -> TTSNarrationUnit?)?
    var onStop: (() -> Void)?
    var onPlaybackStarted: ((TimeInterval) -> Void)?
    var onSegmentChanged: ((Int, Int, String) -> Void)?

    private var audioPlayer: AVAudioPlayer?
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

    /// Looped-silence player that keeps the audio session emitting samples during the gap
    /// between one chunk finishing and the next being downloaded/ready. Without it the
    /// `AVAudioPlayer` is `nil`, there is no active audio output, and iOS may suspend the
    /// app while backgrounded / locked — manifesting as playback stalling mid-book with the
    /// mini-player still showing "playing" until the device is unlocked. The silence is
    /// looped until a real chunk playback starts, which stops it.
    private var silencePlayer: AVAudioPlayer?

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
        ttsLog("[TTS][HTTPEngine] resume requested isPlaying=\(isPlaying) isPaused=\(isPaused) index=\(currentIndex)")
        guard !isPlaying, isPaused else { return }
        beginBackgroundTask()
        isPaused = false
        isPlaying = true

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
    /// itself; otherwise the UI rate (0.5 == 100%) mapped into AVAudioPlayer's 0.5–2.0 range.
    private var clientPlaybackRate: Float {
        serverControlsSpeed ? 1.0 : max(0.5, min(lastRate / 0.5, 2.0))
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

            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = clientPlaybackRate
            let prepared = player.prepareToPlay()
            player.volume = 1.0
            player.numberOfLoops = 0
            audioPlayer = player

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] play submitted index=\(index) prepared=\(prepared) success=\(success) duration=\(player.duration) currentTime=\(player.currentTime) format=\(player.format) volume=\(player.volume)")

            if !success {
                playChunk(at: index + 1, token: token)
            } else {
                onPlaybackStarted?(player.duration)
            }
        } catch {
            ttsLog("[TTS][HTTPEngine] player init failed index=\(index) error=\(error.localizedDescription)")
            playChunk(at: index + 1, token: token)
        }
    }

    /// Rebuilds the AVAudioPlayer for the already-cached current chunk and seeks to `time`,
    /// so a resume after the OS discarded the paused player continues mid-sentence rather than
    /// replaying it. Falls back to the normal `playChunk` path on any failure.
    private func resumeCachedChunk(_ data: Data, at index: Int, from time: TimeInterval, token: UUID) {
        guard token == playbackToken else { return }
        do {
            audioPlayer?.delegate = nil
            audioPlayer?.stop()
            stopSilence()   // real audio is about to play; stop the keep-alive silence

            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = clientPlaybackRate
            player.prepareToPlay()
            player.volume = 1.0
            player.numberOfLoops = 0
            player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
            audioPlayer = player
            currentIndex = index

            let success = player.play()
            isPlaying = success
            ttsLog("[TTS][HTTPEngine] resume cached chunk index=\(index) seekTo=\(time) duration=\(player.duration) success=\(success)")
            if success {
                onPlaybackStarted?(player.duration)
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

    private func resetPlaybackState() {
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

    /// PCM silence data (1 second, mono 16-bit 44.1kHz) wrapped in a minimal WAV container.
    /// Built once; the silence player loops it for as long as the engine is "playing" but
    /// has no real audio to emit (chunk download gaps).
    private static let silenceWAV: Data = {
        let sampleRate: UInt32 = 44_100
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        let frames: UInt32 = sampleRate // 1 second
        let dataSize: UInt32 = frames * UInt32(blockAlign)

        var d = Data()
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func tag(_ s: String) {
            s.utf8.forEach { d.append($0) }
        }
        tag("RIFF"); u32(36 + dataSize); tag("WAVE")
        tag("fmt "); u32(16); u16(1) // PCM
        u16(numChannels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        tag("data"); u32(dataSize)
        d.append(Data(repeating: 0, count: Int(dataSize)))
        return d
    }()

    private func ensureSilencePlayer() {
        if silencePlayer != nil { return }
        guard let p = try? AVAudioPlayer(data: Self.silenceWAV) else {
            ttsLog("[TTS][HTTPEngine] silence player init failed — chunk-gap keep-alive disabled")
            return
        }
        p.numberOfLoops = -1
        p.volume = 0.0
        p.prepareToPlay()
        silencePlayer = p
    }

    /// Start emitting looped silence so the audio session has active output while waiting
    /// for the next chunk to download. Idempotent and only while not paused.
    private func startSilence() {
        guard !isPaused else { return }
        ensureSilencePlayer()
        if silencePlayer?.isPlaying == false {
            _ = silencePlayer?.play()
        }
    }

    /// Stop the keep-alive silence. Called when real chunk playback begins, on pause, stop, and reset.
    private func stopSilence() {
        silencePlayer?.pause()
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

extension HTTPTTSEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handlePlaybackEnded(successfully: flag)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            ttsLog("[TTS][HTTPEngine] decode error=\(error?.localizedDescription ?? "nil")")
            guard let self else { return }
            self.audioPlayer?.delegate = nil
            self.audioPlayer = nil
            self.playChunk(at: self.currentIndex + 1, token: self.playbackToken)
        }
    }
}
