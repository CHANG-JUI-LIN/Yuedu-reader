import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/// One video book's playback: which episode plays, where it is, and what comes next.
///
/// The position lives in the audiobook fields (`audioChapterIndex`, `audioTimeSeconds`) — one
/// position scheme for both timed kinds. A book that is not on the shelf keeps it in memory
/// only, as the audiobook player's transient books do. A source script's single link
/// (`java.openVideoPlayer`) plays as a video of one episode, its position kept per link.
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
    /// The span the timeline and a swipe across the picture can seek in; `nil` while the stream
    /// has no seekable span (still loading, or live with no window to go back in).
    private(set) var seekableRange: ClosedRange<Double>?
    /// The speed the player keeps; a long press only lends it another for a while.
    private(set) var rate: Float = 1
    private(set) var isLongPressing = false
    /// The picture's size once the stream reports it; the player turns to match it.
    private(set) var pictureSize: CGSize?

    private enum Source {
        /// A book's episodes, resolved through the chapter cache; `persists` for a shelf book.
        case book(BookStore, persists: Bool)
        /// A script's link, played as it is.
        case link(VideoStream)
    }

    private let source: Source
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var timelineObservations: [NSKeyValueObservation] = []
    /// Where the episode being loaded opens, applied once it is ready to play.
    private var pendingSeek: Double = 0
    /// The episode whose link was already resolved again after failing to play: legado
    /// refreshes a failed link once (`retryOnPlayError`), then reports the failure.
    private var refetchedChapter: Int?
    private var lastSavedTime: Double = 0
    private var nowPlayingSession: MPNowPlayingSession?
    /// Not state the screen shows; set while the picture's layer is made.
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    private let pictureInPictureDelegate = VideoPictureInPictureDelegate()

    /// `book` must carry its table of contents (`BookStore.readingBook(id:)`).
    init(book: ReadingBook, store: BookStore, persists: Bool) {
        self.book = book
        self.source = .book(store, persists: persists)
        self.guide = VideoEpisodeGuide(chapters: book.onlineChapters ?? [])
        self.chapterIndex = guide.resumeEpisode(saved: book.audioChapterIndex) ?? 0
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// A script's link, opening where it was left (`VideoLinkPositions`).
    init(link: VideoStream, title: String) {
        var book = ReadingBook(title: title, author: "", contentFilename: "")
        book.onlineChapters = [OnlineChapterRef(index: 0, title: title, url: link.url.absoluteString)]
        book.audioChapterIndex = 0
        book.audioTimeSeconds = VideoLinkPositions.time(for: link.url) ?? 0
        self.book = book
        self.source = .link(link)
        self.guide = VideoEpisodeGuide(chapters: book.onlineChapters ?? [])
        self.chapterIndex = 0
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
        sizeObservation = nil
        timelineObservations = []
        nowPlayingSession = nil
        pictureInPicture = nil
    }

    /// Lets the picture go on in Picture in Picture when the app leaves the foreground while it
    /// plays. Only then: the player lives as long as its screen, so a window started from a
    /// button would end with the screen it floats over.
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            AppLogger.info("[Video] Picture in Picture unavailable for this layer", level: .notice)
            return
        }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = pictureInPictureDelegate
        pictureInPicture = controller
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
        sizeObservation = nil
        timelineObservations = []
        pictureSize = nil
        phase = .loading
        currentTime = time
        duration = 0
        seekableRange = nil
        pendingSeek = time
        lastSavedTime = time
        let store: BookStore
        switch source {
        case .link(let stream):
            begin(stream)
            return
        case .book(let bookStore, _):
            store = bookStore
        }
        let book = book
        let chapterIndex = chapterIndex
        loadTask = Task { [weak self] in
            do {
                let stream = try await VideoChapterLinks.stream(
                    for: book, chapterIndex: chapterIndex, priority: .immediate, store: store
                )
                try Task.checkCancellation()
                self?.begin(stream)
            } catch is CancellationError {
                return
            } catch VideoChapterLinkError.notALink(let preview) {
                guard let self else { return }
                // A chapter cached before the book was known as a video — read in the text
                // reader, whose fetch shows a source's note and lets its script open a player
                // or a page — holds that note, not the episode. It is fetched again once, as
                // the episode being played, the same single retry a link that fails to play
                // gets. Delete with that retry once no copy can hold a chapter cached by a
                // build before 2026-11-01's handover (`LegadoJSBridge.videoEpisodeHandover`).
                if self.refetchedChapter != chapterIndex {
                    self.refetchedChapter = chapterIndex
                    AppLogger.info("[Video] cached episode is not a link; fetching it again", level: .notice)
                    VideoChapterLinks.discardResolvedLink(for: book, chapterIndex: chapterIndex, store: store)
                    self.load(at: time)
                } else {
                    AppLogger.info("[Video] episode is not a link: \(preview)", level: .error)
                    self.phase = .failed(VideoChapterLinkError.notALink(preview: preview).localizedDescription)
                }
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
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor in
                guard self?.player.currentItem.map(ObjectIdentifier.init) == identity else { return }
                self?.pictureSize = size
            }
        }
        // Both change after `readyToPlay`: an HLS playlist without `#EXT-X-ENDLIST` plays as
        // live, its duration indefinite while its seekable span grows with every reload.
        let timelineChanged: @Sendable (AVPlayerItem) -> Void = { [weak self] item in
            let timeline = VideoTimeline(duration: item.duration.seconds,
                                         seekable: item.seekableTimeRanges.map(\.timeRangeValue))
            Task { @MainActor in self?.timelineChanged(timeline, of: identity) }
        }
        timelineObservations = [
            item.observe(\.duration, options: [.new]) { item, _ in timelineChanged(item) },
            item.observe(\.seekableTimeRanges, options: [.new]) { item, _ in timelineChanged(item) },
        ]
        player.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, of item: ObjectIdentifier) {
        // A change can arrive after the next episode has replaced the item it was about.
        guard player.currentItem.map(ObjectIdentifier.init) == item else { return }
        switch status {
        case .readyToPlay:
            guard phase == .loading, let item = player.currentItem else { return }
            apply(VideoTimeline(duration: item.duration.seconds,
                                seekable: item.seekableTimeRanges.map(\.timeRangeValue)))
            let seek = pendingSeek
            pendingSeek = 0
            if seek > 0, duration == 0 || seek < duration - 1 {
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            }
            resume()
            activateNowPlaying()
        case .failed:
            // A script's link has nothing to resolve it again from.
            if case .book(let store, _) = source, refetchedChapter != chapterIndex {
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

    private func timelineChanged(_ timeline: VideoTimeline, of item: ObjectIdentifier) {
        guard player.currentItem.map(ObjectIdentifier.init) == item else { return }
        apply(timeline)
    }

    private func apply(_ timeline: VideoTimeline) {
        duration = timeline.duration
        seekableRange = timeline.seekableRange
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

    /// Does nothing while nothing is seekable: a live stream with no window, or one still loading.
    func seek(to seconds: Double) {
        guard let range = seekableRange else { return }
        let target = min(max(seconds, range.lowerBound), range.upperBound)
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
        switch source {
        case .link(let stream):
            VideoLinkPositions.save(currentTime, for: stream.url)
            return
        case .book(_, persists: false):
            return
        case .book(let store, persists: true):
            store.updateAudioPosition(
                bookId: book.id, chapter: chapterIndex, time: currentTime,
                totalChapters: book.onlineChapters?.count ?? 0, forceSave: force
            )
        }
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

/// How far an episode reaches and where it can be sought, from what its item reports.
///
/// An MP4 or a finished HLS playlist reports its duration, and is seekable from 0 to there. An
/// HLS playlist without `#EXT-X-ENDLIST` plays as live: its duration is indefinite (NaN), yet its
/// seekable ranges still cover the segments listed so far (measured 2026-11-10 against a 60 s
/// playlist with the tag removed: duration NaN, seekable 0–30 s) — the timeline is those ranges.
/// A live stream with no window to go back in has none, and nothing to seek.
struct VideoTimeline: Equatable, Sendable {
    /// 0 when the item does not know it.
    let duration: Double
    let seekableRange: ClosedRange<Double>?

    init(duration seconds: Double, seekable: [CMTimeRange]) {
        if seconds.isFinite, seconds > 0 {
            duration = seconds
            seekableRange = 0...seconds
            return
        }
        duration = 0
        let spans = seekable.filter { $0.start.isNumeric && $0.end.isNumeric }
        guard let lower = spans.map(\.start.seconds).min(),
              let upper = spans.map(\.end.seconds).max(), upper > lower else {
            seekableRange = nil
            return
        }
        seekableRange = lower...upper
    }
}

/// The interface stays on screen under Picture in Picture, so there is nothing to bring back.
private final class VideoPictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
