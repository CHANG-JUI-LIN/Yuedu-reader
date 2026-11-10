import AVFoundation
import Foundation

/// Called on main: the player hops there before validating the finished schedule.
@MainActor
protocol TTSChunkAudioPlayerDelegate: AnyObject {
    /// The chunk ended and nothing was queued behind it.
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool)
    /// The chunk ended and the one queued behind it (`enqueue(data:)`) is now playing — it
    /// was already scheduled on the node, so there was no gap.
    func chunkAudioPlayerDidAdvanceToQueuedChunk(_ player: TTSChunkAudioPlayer)
}

extension TTSChunkAudioPlayerDelegate {
    func chunkAudioPlayerDidAdvanceToQueuedChunk(_ player: TTSChunkAudioPlayer) {}
}

/// A reusable audio graph for HTTP TTS chunks.
///
/// The player node and engine live for the whole TTS session. Only the decoded source is
/// replaced between chunks. Rebuilding an `AVAudioEngine` for every paragraph creates an
/// audio-session boundary precisely when an app is locked or backgrounded; iOS can suspend
/// that boundary before the next graph has started. Keeping one graph also makes route and
/// media-service recovery deterministic.
///
/// `AVAudioPlayer.rate` is documented to span only 0.5–2.0, so every speech rate above 200%
/// saturated silently. `AVAudioUnitTimePitch` covers the requested 5× range while preserving
/// pitch.
///
/// Consecutive chunks play without a gap: the next one can be queued (`enqueue(data:)`)
/// while the current one plays, and its buffers are scheduled on the same node right behind
/// the current chunk's last buffer. Loading a chunk instead stops the node and the engine and
/// waits for the previous chunk's final buffer to be played back before anything new is
/// decoded — a gap every listener heard between paragraphs, and between every line once
/// 多角色朗讀 cut a chapter at each change of voice.
final class TTSChunkAudioPlayer: @unchecked Sendable {
    weak var delegate: TTSChunkAudioPlayerDelegate?

    /// Source duration in seconds — unaffected by `rate`, matching `AVAudioPlayer.duration`.
    private(set) var duration: TimeInterval = 0

    /// Internal so tests can render the graph offline (`init(manualRenderingFormat:)`).
    let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var decoder: TTSChunkDecoder?
    private var sampleRate: Double = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var connectedSampleRate: Double = 0
    private var connectedChannelCount: AVAudioChannelCount = 0

    /// The chunk queued behind the current one, decoded and waiting.
    private var queued: TTSChunkDecoder?
    /// Which chunk a scheduled buffer belongs to. A buffer's completion is matched against the
    /// current chunk's id, so the end of the current chunk is told apart from the end of the
    /// one queued behind it — and from a chunk queued behind *that* after it became current.
    private var chunkCounter = 0
    private var currentChunkID = 0
    private var queuedChunkID = 0
    /// The queued chunk's buffers are being scheduled: the current chunk was read to its end.
    private var feedingQueued = false
    /// Frames scheduled for the current chunk, and for the queued one, in this schedule. The
    /// node's sample time runs on across the boundary, so the queued chunk's position is the
    /// node's time minus everything the current chunk put in front of it.
    private var currentScheduledFrames: AVAudioFramePosition = 0
    private var queuedScheduledFrames: AVAudioFramePosition = 0
    /// Node sample time at which the current chunk began playing in this schedule.
    private var chunkStartSampleTime: AVAudioFramePosition = 0

    /// Source frame the current schedule started at. `currentTime` is this plus whatever
    /// the node has rendered since; a seek restarts the schedule and resets it.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    /// Invalidates the completion handler of a schedule that a seek/load/stop superseded.
    private var scheduleToken = UUID()
    /// Decoded buffers handed to the node and not yet played back.
    private var queuedBuffers = 0
    /// Everything there is to schedule is scheduled: the current chunk's last buffer, and the
    /// queued chunk's too when one is being fed.
    private var reachedEndOfSource = false
    /// The decoder failed partway; the chunk ends once what was queued has played.
    private var decodeFailed = false
    /// The next decoded buffer, read before it is scheduled (see `fillBufferQueue`).
    private var lookahead: AVAudioPCMBuffer?
    private var hasStarted = false
    /// Position captured at `pause`. `engine.pause()` can make `lastRenderTime` nil, so
    /// retaining this position prevents a resume from replaying the whole paragraph.
    private var pausedTime: TimeInterval?

    private(set) var isPlaying = false
    var hasLoadedAudio: Bool { decoder != nil && totalFrames > 0 }
    /// A chunk is queued behind the current one.
    var hasQueuedChunk: Bool { queued != nil }

    /// Wall-clock length at the current rate — what the Now Playing elapsed clock needs.
    var effectiveDuration: TimeInterval {
        duration / Double(max(rate, 0.01))
    }

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = Self.clampRate(newValue) }
    }

    /// Source-domain playback position. Reading mirrors `AVAudioPlayer.currentTime`;
    /// writing seeks, which reschedules from the new frame.
    var currentTime: TimeInterval {
        get {
            if let pausedTime { return pausedTime }
            guard hasStarted,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
            else {
                return frameToSeconds(scheduleStartFrame)
            }
            // `playerTime.sampleTime` counts source frames, so it stays in the source domain
            // no matter what the time-pitch unit is doing downstream.
            let played = playerTime.sampleTime - chunkStartSampleTime
            return min(max(frameToSeconds(scheduleStartFrame + played), 0), duration)
        }
        set { seek(to: newValue) }
    }

    /// `manualRenderingFormat` puts the engine in offline manual rendering before the graph
    /// is built, so tests can pull exactly what a listener would hear. Production passes nil.
    init(manualRenderingFormat: AVAudioFormat? = nil) {
        if let manualRenderingFormat {
            do {
                try engine.enableManualRenderingMode(.offline, format: manualRenderingFormat, maximumFrameCount: 4096)
            } catch {
                ttsLog("[TTS][ChunkPlayer] manual rendering unavailable error=\(error.localizedDescription)")
            }
        }
        engine.attach(playerNode)
        engine.attach(timePitch)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        clear()
    }

    /// Replaces the source while retaining the audio graph. The chunk is decoded from memory;
    /// nothing is written to disk (see `TTSChunkDecoder`). Drops anything queued.
    func load(data: Data) throws {
        stop()
        clearCurrentSource()

        let newDecoder = try TTSChunkDecoder(data: data)
        install(newDecoder)
        connectGraph(for: newDecoder.processingFormat, force: true)

        scheduleStartFrame = 0
        pausedTime = nil
        hasStarted = false
    }

    /// Queues the chunk that follows the current one, so it starts the moment the current one
    /// ends. Returns `false` — and the caller loads it at the boundary as before — when there is
    /// nothing playing to follow or its format differs: the node is connected for one sample
    /// rate and channel count, and two imported voice sources can disagree on both.
    @discardableResult
    func enqueue(data: Data) throws -> Bool {
        guard decoder != nil, queued == nil else { return false }
        let next = try TTSChunkDecoder(data: data)
        guard next.processingFormat.sampleRate == connectedSampleRate,
              next.processingFormat.channelCount == connectedChannelCount else {
            ttsLog("[TTS][ChunkPlayer] queued chunk format differs; it will load at the boundary")
            return false
        }
        queued = next
        chunkCounter += 1
        queuedChunkID = chunkCounter
        // The current chunk may already be read to its end, its last buffer waiting to be
        // heard; then the queued chunk is fed right away, or there would be a gap after all.
        if hasStarted, reachedEndOfSource, !decodeFailed {
            beginFeedingQueued()
            do {
                try fillBufferQueue(token: scheduleToken)
            } catch {
                ttsLog("[TTS][ChunkPlayer] queued chunk decode failed error=\(error.localizedDescription)")
                decodeFailed = true
            }
        }
        return true
    }

    /// Releases the current source but keeps the reusable graph attached to the engine.
    func clear() {
        stop()
        clearCurrentSource()
    }

    @discardableResult
    func play() -> Bool {
        guard decoder != nil, totalFrames > 0, scheduleStartFrame < totalFrames else { return false }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            ttsLog("[TTS][ChunkPlayer] engine start failed error=\(error.localizedDescription)")
            return false
        }
        if !hasStarted {
            do {
                try scheduleFromCurrentStartFrame()
            } catch {
                ttsLog("[TTS][ChunkPlayer] decode failed at frame=\(scheduleStartFrame) error=\(error.localizedDescription)")
                return false
            }
        }
        playerNode.play()
        pausedTime = nil
        hasStarted = true
        isPlaying = true
        return true
    }

    func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime
        playerNode.pause()
        engine.pause()
        isPlaying = false
    }

    func stop() {
        scheduleToken = UUID()
        playerNode.stop()
        engine.stop()
        pausedTime = nil
        hasStarted = false
        isPlaying = false
        scheduleStartFrame = 0
        queued = nil
        feedingQueued = false
    }

    // MARK: - Private

    private func install(_ newDecoder: TTSChunkDecoder) {
        chunkCounter += 1
        currentChunkID = chunkCounter
        decoder = newDecoder
        sampleRate = newDecoder.processingFormat.sampleRate
        totalFrames = newDecoder.length
        duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }

    private func clearCurrentSource() {
        decoder = nil
        queued = nil
        feedingQueued = false
        lookahead = nil
        sampleRate = 0
        totalFrames = 0
        duration = 0
        scheduleStartFrame = 0
        pausedTime = nil
        hasStarted = false
    }

    /// Seeks within the current chunk. A queued chunk stays queued and is fed again from its
    /// start once the current one has been read to its end.
    private func seek(to time: TimeInterval) {
        guard hasLoadedAudio else { return }
        let wasPlaying = isPlaying
        scheduleToken = UUID()
        playerNode.stop()
        engine.stop()
        pausedTime = nil
        hasStarted = false
        isPlaying = false
        feedingQueued = false
        scheduleStartFrame = secondsToFrame(min(max(time, 0), duration))
        if wasPlaying {
            _ = play()
        }
    }

    /// Seconds of decoded audio per scheduled buffer, and how many buffers stay queued. The
    /// queue is refilled from the main queue, so it is what a busy main thread can fall behind
    /// by before the listener hears a gap.
    private static let bufferDuration: Double = 1
    private static let bufferQueueDepth = 3

    private func scheduleFromCurrentStartFrame() throws {
        guard let decoder, totalFrames - scheduleStartFrame > 0 else { return }
        try decoder.seek(toFrame: scheduleStartFrame)
        queuedBuffers = 0
        reachedEndOfSource = false
        decodeFailed = false
        feedingQueued = false
        currentScheduledFrames = 0
        queuedScheduledFrames = 0
        chunkStartSampleTime = 0
        lookahead = try decoder.read(frameCapacity: bufferFrameCapacity)
        try fillBufferQueue(token: scheduleToken)
    }

    private var bufferFrameCapacity: AVAudioFrameCount {
        AVAudioFrameCount(max(1, sampleRate * Self.bufferDuration))
    }

    /// The decoder buffers are being read from: the current chunk's, or the queued one's once
    /// the current chunk is read to its end.
    private var feedDecoder: TTSChunkDecoder? { feedingQueued ? queued : decoder }

    /// Switches reading to the queued chunk, from its first frame.
    private func beginFeedingQueued() {
        guard let queued else { return }
        do {
            try queued.seek(toFrame: 0)
            lookahead = try queued.read(frameCapacity: bufferFrameCapacity)
            feedingQueued = true
            queuedScheduledFrames = 0
            reachedEndOfSource = lookahead == nil
        } catch {
            ttsLog("[TTS][ChunkPlayer] queued chunk decode failed error=\(error.localizedDescription)")
            self.queued = nil
        }
    }

    /// Reads one buffer ahead, so the last buffer of a chunk is known when it is scheduled:
    /// it waits for `.dataPlayedBack` (the chunk is over when the listener has heard it); every
    /// other buffer refills the queue at `.dataConsumed`, as soon as the node has taken it.
    ///
    /// When the current chunk's last buffer is scheduled and a chunk is queued, reading moves
    /// straight on to the queued chunk: its buffers land on the node right behind.
    private func fillBufferQueue(token: UUID) throws {
        while queuedBuffers < Self.bufferQueueDepth {
            guard let buffer = lookahead, let source = feedDecoder else {
                reachedEndOfSource = true
                return
            }
            lookahead = try source.read(frameCapacity: bufferFrameCapacity)
            let endsChunk = lookahead == nil
            let ofQueued = feedingQueued
            let chunkID = ofQueued ? queuedChunkID : currentChunkID
            queuedBuffers += 1
            if ofQueued {
                queuedScheduledFrames += AVAudioFramePosition(buffer.frameLength)
            } else {
                currentScheduledFrames += AVAudioFramePosition(buffer.frameLength)
            }
            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: endsChunk ? .dataPlayedBack : .dataConsumed
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    // A seek, load, or stop replaced this schedule; it is not the chunk finishing.
                    guard token == self.scheduleToken else { return }
                    self.bufferCompleted(endsChunk: endsChunk, chunkID: chunkID, token: token)
                }
            }
            if endsChunk {
                if !ofQueued, queued != nil {
                    beginFeedingQueued()
                    continue
                }
                reachedEndOfSource = true
                return
            }
        }
    }

    /// On main, where the delegate is called, as every completion is hopped there.
    @MainActor
    private func bufferCompleted(endsChunk: Bool, chunkID: Int, token: UUID) {
        guard decoder != nil else { return }
        queuedBuffers -= 1
        if !reachedEndOfSource, !decodeFailed {
            do {
                try fillBufferQueue(token: token)
            } catch {
                // The bytes decoded at load and up to here, so this is a corrupt stretch
                // mid-chunk. End the chunk where the audio ends rather than stall silent.
                ttsLog("[TTS][ChunkPlayer] decode failed mid-chunk error=\(error.localizedDescription)")
                decodeFailed = true
            }
        }
        let currentEnded = endsChunk && chunkID == currentChunkID
        if currentEnded, feedingQueued, let next = queued {
            // The current chunk has been heard to its end and the queued one is already
            // playing behind it: it becomes the current chunk, with no gap.
            advance(to: next)
            delegate?.chunkAudioPlayerDidAdvanceToQueuedChunk(self)
            return
        }
        let finished = currentEnded || (decodeFailed && queuedBuffers == 0)
        guard finished, isPlaying else { return }
        isPlaying = false
        delegate?.chunkAudioPlayerDidFinishPlaying(self, successfully: !decodeFailed)
    }

    private func advance(to next: TTSChunkDecoder) {
        chunkStartSampleTime += currentScheduledFrames
        currentScheduledFrames = queuedScheduledFrames
        queuedScheduledFrames = 0
        decoder = next
        currentChunkID = queuedChunkID
        sampleRate = next.processingFormat.sampleRate
        totalFrames = next.length
        duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
        queued = nil
        feedingQueued = false
        scheduleStartFrame = 0
    }

    private func connectGraph(for format: AVAudioFormat, force: Bool = false) {
        let channelCount = format.channelCount
        guard force || connectedSampleRate != format.sampleRate || connectedChannelCount != channelCount else {
            return
        }

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        connectedSampleRate = format.sampleRate
        connectedChannelCount = channelCount
    }

    /// A route change can invalidate the running graph. Reconnect it before restarting from
    /// the captured source position; the decoder and current queue item remain intact.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying, let decoder = self.decoder else { return }
            let resumeAt = self.currentTime
            ttsLog("[TTS][ChunkPlayer] audio graph changed; resuming at \(resumeAt)")
            self.connectGraph(for: decoder.processingFormat, force: true)
            self.seek(to: resumeAt)
        }
    }

    private func frameToSeconds(_ frame: AVAudioFramePosition) -> TimeInterval {
        sampleRate > 0 ? Double(frame) / sampleRate : 0
    }

    private func secondsToFrame(_ seconds: TimeInterval) -> AVAudioFramePosition {
        sampleRate > 0 ? AVAudioFramePosition(seconds * sampleRate) : 0
    }

    /// `AVAudioUnitTimePitch` documents a 1/32–32 rate range; anything outside is rejected.
    private static func clampRate(_ rate: Float) -> Float {
        min(max(rate, 1.0 / 32.0), 32.0)
    }
}
