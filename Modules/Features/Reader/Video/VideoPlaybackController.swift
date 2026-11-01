import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/// One video book's playback: which episode plays, where it is, and what comes next.
///
/// The position lives in the audiobook fields (`audioChapterIndex`, `audioTimeSeconds`) — one
/// position scheme for both timed kinds. A book that is not on the shelf keeps it in memory
/// only, as the audiobook player's transient books do.
@MainActor
@Observable
final class VideoPlaybackController {
    enum Phase: Equatable {
        case loading
        case playing
        case paused
        /// The last episode of the last 線路 has finished.
        case ended
        case failed(String)
    }

    /// Speeds the speed menu offers (legado-E / MD3: 0.5–3.0).
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    /// legado-E's long-press speed default (`longPressSpeed` 30 = 3.0×).
    static let longPressRate: Float = 3

    let player = AVPlayer()
    let guide: VideoEpisodeGuide
    private(set) var book: ReadingBook
    private(set) var chapterIndex: Int
    private(set) var phase: Phase = .loading
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// The speed the player keeps; a long press only lends it another for a while.
    private(set) var rate: Float = 1
    private(set) var isLongPressing = false

    private let store: BookStore
    private let persists: Bool
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// Where the episode being loaded opens, applied once it is ready to play.
    private var pendingSeek: Double = 0
    /// The episode whose link was already resolved again after failing to play: legado
    /// refreshes a failed link once (`retryOnPlayError`), then reports the failure.
    private var refetchedChapter: Int?
    private var lastSavedTime: Double = 0
    private var nowPlayingSession: MPNowPlayingSession?

    /// `book` must carry its table of contents (`BookStore.readingBook(id:)`).
    init(book: ReadingBook, store: BookStore, persists: Bool) {
        self.book = book
        self.store = store
        self.persists = persists
        self.guide = VideoEpisodeGuide(chapters: book.onlineChapters ?? [])
        self.chapterIndex = guide.resumeEpisode(saved: book.audioChapterIndex) ?? 0
        player.automaticallyWaitsToMinimizeStalling = true
    }

    var route: VideoEpisodeGuide.Route? { guide.route(containing: chapterIndex) }
    var hasNext: Bool { guide.episode(after: chapterIndex) != nil }
    var hasPrevious: Bool { guide.episode(before: chapterIndex) != nil }

    /// The episode's title as the source names it.
    var episodeTitle: String { title(of: chapterIndex) }

    func title(of chapterIndex: Int) -> String {
        guard let chapters = book.onlineChapters, chapters.indices.contains(chapterIndex) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: chapters[chapterIndex].title)
    }

    // MARK: Lifecycle

    /// Opens the saved episode at its saved time.
    func start() {
        guard !guide.isEmpty else {
            phase = .failed(localized("這部影片沒有可播放的集數"))
            return
        }
        AudioSessionActivator.activate(category: .playback, mode: .moviePlayback)
        NowPlayingHub.shared.yieldToVideo()
        observePlayer()
        let resumesSaved = chapterIndex == book.audioChapterIndex
        play(chapterIndex: chapterIndex, at: resumesSaved ? book.audioTimeSeconds : 0)
    }

    /// Saves where it is and lets the player go.
    func close() {
        saveProgress(force: true)
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        nowPlayingSession = nil
    }

    // MARK: Episodes

    func play(chapterIndex: Int, at time: Double = 0) {
        guard guide.route(containing: chapterIndex) != nil else { return }
        if chapterIndex != self.chapterIndex { saveProgress(force: true) }
        self.chapterIndex = chapterIndex
        if refetchedChapter != chapterIndex { refetchedChapter = nil }
        load(at: time)
    }

    func playNext() {
        if let next = guide.episode(after: chapterIndex) { play(chapterIndex: next) }
    }

    func playPrevious() {
        if let previous = guide.episode(before: chapterIndex) { play(chapterIndex: previous) }
    }

    private func load(at time: Double) {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        phase = .loading
        currentTime = time
        duration = 0
        pendingSeek = time
        lastSavedTime = time
        let book = book
        let chapterIndex = chapterIndex
        loadTask = Task { [weak self, store] in
            do {
                let stream = try await VideoChapterLinks.stream(
                    for: book, chapterIndex: chapterIndex, priority: .immediate, store: store
                )
                try Task.checkCancellation()
                self?.begin(stream)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.error("[Video] episode link failed", error: error,
                                context: ["book": book.id.uuidString, "chapter": "\(chapterIndex)"])
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func begin(_ stream: VideoStream) {
        let item = AVPlayerItem(asset: HeaderedMediaAsset.make(url: stream.url, headers: stream.headers))
        item.externalMetadata = nowPlayingMetadata()
        let identity = ObjectIdentifier(item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, error: message, of: identity) }
        }
        player.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, of item: ObjectIdentifier) {
        // A change can arrive after the next episode has replaced the item it was about.
        guard player.currentItem.map(ObjectIdentifier.init) == item else { return }
        switch status {
        case .readyToPlay:
            guard phase == .loading, let item = player.currentItem else { return }
            let seconds = item.duration.seconds
            duration = seconds.isFinite ? seconds : 0
            let seek = pendingSeek
            pendingSeek = 0
            if seek > 0, duration == 0 || seek < duration - 1 {
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            }
            resume()
            activateNowPlaying()
        case .failed:
            if refetchedChapter != chapterIndex {
                refetchedChapter = chapterIndex
                AppLogger.info("[Video] link failed to play; resolving it again", level: .notice)
                VideoChapterLinks.discardResolvedLink(for: book, chapterIndex: chapterIndex, store: store)
                load(at: currentTime)
            } else {
                AppLogger.info("[Video] episode failed to play: \(error ?? "-")", level: .error)
                phase = .failed(error ?? localized("無法播放這一集"))
            }
        default:
            break
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        switch phase {
        case .playing: pause()
        case .paused: resume()
        case .ended: play(chapterIndex: guide.firstEpisode ?? chapterIndex)
        case .failed: retry()
        case .loading: break
        }
    }

    func pause() {
        guard phase == .playing else { return }
        player.pause()
        phase = .paused
        saveProgress(force: true)
    }

    func resume() {
        player.playImmediately(atRate: isLongPressing ? Self.longPressRate : rate)
        phase = .playing
    }

    func retry() {
        refetchedChapter = nil
        load(at: currentTime)
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if phase == .playing, !isLongPressing { player.rate = rate }
    }

    /// legado-E's long press: a faster speed while the finger stays down.
    func setLongPressing(_ pressing: Bool) {
        guard pressing != isLongPressing else { return }
        isLongPressing = pressing
        if phase == .playing { player.rate = pressing ? Self.longPressRate : rate }
    }

    // MARK: Observation

    private func observePlayer() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.timeAdvanced(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item != nil, item === self.player.currentItem else { return }
                self.episodeEnded()
            }
        }
    }

    private func timeAdvanced(_ seconds: Double) {
        guard seconds.isFinite, phase == .playing else { return }
        currentTime = seconds
        if abs(seconds - lastSavedTime) >= 5 { saveProgress(force: false) }
    }

    private func episodeEnded() {
        if let next = guide.episode(after: chapterIndex) {
            play(chapterIndex: next)
        } else {
            phase = .ended
            currentTime = 0
            saveProgress(force: true)
        }
    }

    // MARK: Progress

    func saveProgress(force: Bool) {
        lastSavedTime = currentTime
        book.audioChapterIndex = chapterIndex
        book.audioTimeSeconds = currentTime
        guard persists else { return }
        store.updateAudioPosition(
            bookId: book.id, chapter: chapterIndex, time: currentTime,
            totalChapters: book.onlineChapters?.count ?? 0, forceSave: force
        )
    }

    // MARK: Now Playing

    /// The lock screen and Control Center through the player's own session, so the audiobook
    /// player's handlers on the shared command center are left as they are.
    private func activateNowPlaying() {
        if nowPlayingSession == nil {
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = true
            let commands = session.remoteCommandCenter
            commands.playCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.resume() }
                return .success
            }
            commands.pauseCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.pause() }
                return .success
            }
            commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.togglePlayPause() }
                return .success
            }
            commands.nextTrackCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.playNext() }
                return .success
            }
            commands.previousTrackCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.playPrevious() }
                return .success
            }
            commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let position = event.positionTime
                Task { @MainActor in self?.seek(to: position) }
                return .success
            }
            nowPlayingSession = session
        }
        nowPlayingSession?.remoteCommandCenter.nextTrackCommand.isEnabled = hasNext
        nowPlayingSession?.remoteCommandCenter.previousTrackCommand.isEnabled = hasPrevious
        nowPlayingSession?.becomeActiveIfPossible { _ in }
    }

    private func nowPlayingMetadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = episodeTitle as NSString
        title.extendedLanguageTag = "und"
        let album = AVMutableMetadataItem()
        album.identifier = .commonIdentifierAlbumName
        album.value = book.title as NSString
        album.extendedLanguageTag = "und"
        return [title, album]
    }
}
