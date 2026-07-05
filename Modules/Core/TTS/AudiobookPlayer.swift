import AVFoundation
import Combine
import Foundation
import MediaPlayer
import os.log
import UIKit

// MARK: - Audiobook sleep timer option

enum AudiobookSleepOption: Equatable {
    case off
    case minutes(Int)
    case endOfChapter
}

// MARK: - Audiobook playback coordinator
//
// The single brain for audiobook (有聲書) playback. It is a long-lived singleton
// so that audio keeps playing — with lock-screen / Control-Center controls — after
// the player page is dismissed, exactly like the EPUB inline-video manager and TTS.
//
// Responsibilities: hold the current book's chapter context, ask a
// `ChapterAudioProvider` for a playable chapter audio asset, drive an `AVPlayer`,
// auto-advance at the end of a chapter, expose prev/next/seek/rate/sleep, publish
// NowPlaying info + handle remote commands, and persist `(audioChapterIndex,
// audioTimeSeconds)`.

@MainActor
final class AudiobookPlayer: NSObject, ObservableObject {

    static let shared = AudiobookPlayer()

    private struct CoverFallback {
        let urlString: String
        let sourceBaseURL: String?
        let sourceHeaders: [String: String]
    }

    // MARK: - Published State (bound to AudiobookReaderView)

    @Published private(set) var bookId: UUID?
    @Published private(set) var bookTitle: String = ""
    @Published private(set) var coverImage: UIImage?
    @Published private(set) var chapters: [OnlineChapterRef] = []
    @Published private(set) var chapterIndex: Int = 0
    @Published private(set) var currentChapterTitle: String = ""

    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: String? = nil
    @Published var playbackRate: Float = 1.0
    @Published var sleepOption: AudiobookSleepOption = .off

    // MARK: - Context

    private weak var store: BookStore?
    private var activeBook: ReadingBook?
    private var persistsPositionInStore = true
    private var coverFallbacks: [UUID: CoverFallback] = [:]
    private let onlineChapterAudioProvider: ChapterAudioProvider
    private let localChapterAudioProvider: ChapterAudioProvider

    // MARK: - Engine

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var boundaryObserverToken: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var loadToken = UUID()
    private var pendingResumeTime: TimeInterval = 0
    private var didSeekForResume = false
    private var lastPersist: Date = .distantPast
    private var loadedRuntimeVariables: [String: String]?
    private var currentItemSourceURL: URL?
    private var chapterStartSeconds: TimeInterval = 0
    private var chapterDurationOverride: TimeInterval?
    private var chapterFinishHandled = false

    // MARK: - Sleep timer

    private var sleepTimer: Timer?
    private var stopAtChapterEnd = false

    // MARK: - Remote commands

    private var remoteCommandsConfigured = false

    private override init() {
        self.onlineChapterAudioProvider = OnlineChapterAudioProvider()
        self.localChapterAudioProvider = LocalChapterAudioProvider()
        super.init()
    }

    // MARK: - Public lifecycle

    /// Whether a given book is the one currently loaded into the coordinator.
    func isActive(bookId id: UUID) -> Bool { bookId == id }

    func prepareCoverFallback(
        bookId: UUID,
        coverUrl: String,
        sourceBaseURL: String?,
        sourceHeaders: [String: String]
    ) {
        let trimmed = coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fallback = CoverFallback(
            urlString: trimmed,
            sourceBaseURL: sourceBaseURL,
            sourceHeaders: sourceHeaders
        )
        coverFallbacks[bookId] = fallback
        if self.bookId == bookId, coverImage == nil {
            loadRemoteCoverIfNeeded(for: bookId, fallback: fallback)
        }
    }

    /// Attach to (or start) playback for a book. If the same book is already
    /// loaded, keep the live session unless the stored chapters/runtime changed.
    func start(book: ReadingBook, store: BookStore) {
        start(book: book, store: store, persistsPositionInStore: true)
    }

    /// Start playback from a detail-page book that has not been added to the bookshelf.
    /// Progress is intentionally kept in-memory so this path does not create or mutate
    /// a `BookStore.books` entry.
    func startTransient(book: ReadingBook, store: BookStore) {
        start(book: book, store: store, persistsPositionInStore: false)
    }

    private func start(
        book: ReadingBook,
        store: BookStore,
        persistsPositionInStore: Bool
    ) {
        self.store = store
        self.activeBook = book
        self.persistsPositionInStore = persistsPositionInStore
        if bookId == book.id, player != nil {
            refreshActiveBookIfNeeded(book)
            NowPlayingHub.shared.attachAudiobook(self)
            audiobookLog("start: already active book=\(book.title) — attaching to live session")
            return
        }

        // Take over the audio session from any active TTS narration (audiobook only
        // displaces TTS, never another audiobook).
        NowPlayingHub.shared.stopTTSIfActive()

        stopInternal()
        error = nil

        bookId = book.id
        bookTitle = book.title
        coverImage = Self.loadCover(book.coverImagePath)
        if coverImage == nil, let fallback = coverFallbacks[book.id] {
            loadRemoteCoverIfNeeded(for: book.id, fallback: fallback)
        }
        loadedRuntimeVariables = book.runtimeVariables

        chapters = book.onlineChapters ?? []
        let restoredIndex = min(max(0, book.audioChapterIndex), max(0, chapters.count - 1))
        chapterIndex = restoredIndex
        pendingResumeTime = max(0, book.audioTimeSeconds)

        configureRemoteCommandsIfNeeded()
        activateAudioSession()

        NowPlayingHub.shared.attachAudiobook(self)
        audiobookLog("start: book=\(book.title) chapters=\(chapters.count) restoreCh=\(restoredIndex) resumeT=\(pendingResumeTime)")
        loadCurrentChapter(autoPlay: true)
    }

    private func refreshActiveBookIfNeeded(_ book: ReadingBook) {
        let updatedChapters = book.onlineChapters ?? []
        guard activeBookNeedsRefresh(updatedChapters: updatedChapters, runtimeVariables: book.runtimeVariables) else {
            return
        }

        let shouldAutoplay = isPlaying || error != nil
        chapters = updatedChapters
        loadedRuntimeVariables = book.runtimeVariables
        if !chapters.indices.contains(chapterIndex) {
            chapterIndex = min(max(0, book.audioChapterIndex), max(0, chapters.count - 1))
        }
        pendingResumeTime = max(0, book.audioTimeSeconds)
        currentTime = 0
        duration = 0
        audiobookLog("start: refreshed active book=\(book.title) chapters=\(chapters.count)")
        loadCurrentChapter(autoPlay: shouldAutoplay)
    }

    private func activeBookNeedsRefresh(
        updatedChapters: [OnlineChapterRef],
        runtimeVariables: [String: String]?
    ) -> Bool {
        guard !updatedChapters.isEmpty else { return false }
        if loadedRuntimeVariables != runtimeVariables { return true }
        if chapters.count != updatedChapters.count { return true }
        return zip(chapters, updatedChapters).contains { old, new in
            old.index != new.index
                || old.title != new.title
                || old.url != new.url
                || old.runtimeVariables != new.runtimeVariables
                || old.audioStartSeconds != new.audioStartSeconds
                || old.audioDurationSeconds != new.audioDurationSeconds
        }
    }

    func play() {
        guard player != nil else { return }
        player?.rate = playbackRate
        isPlaying = true
        startSleepTimerIfNeeded()
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        persistPosition(force: true)
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isLoading { return }
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        persistPosition(force: true)
        stopInternal()
        deactivateAudioSession()
        bookId = nil
        chapters = []
        currentChapterTitle = ""
        bookTitle = ""
        coverImage = nil
        activeBook = nil
        persistsPositionInStore = true
        loadedRuntimeVariables = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Seeking

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        seekWithinCurrentChapter(to: clamped)
        persistPosition(force: true)
        updateNowPlaying()
    }

    func skipForward(_ seconds: Double = 15) { seek(to: currentTime + seconds) }
    func skipBackward(_ seconds: Double = 15) { seek(to: currentTime - seconds) }

    // MARK: - Rate

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
        updateNowPlaying()
    }

    // MARK: - Chapter navigation

    func selectChapter(_ index: Int) {
        guard chapters.indices.contains(index), index != chapterIndex else { return }
        chapterIndex = index
        pendingResumeTime = 0
        loadCurrentChapter(autoPlay: true)
    }

    func nextChapter() {
        guard chapterIndex + 1 < chapters.count else { return }
        selectChapter(chapterIndex + 1)
    }

    func previousChapter() {
        guard chapterIndex - 1 >= 0 else { return }
        selectChapter(chapterIndex - 1)
    }

    var hasNextChapter: Bool { chapterIndex + 1 < chapters.count }
    var hasPreviousChapter: Bool { chapterIndex - 1 >= 0 }

    // MARK: - Sleep timer

    func setSleepOption(_ option: AudiobookSleepOption) {
        sleepOption = option
        cancelSleepTimer()
        stopAtChapterEnd = false
        switch option {
        case .off:
            break
        case .endOfChapter:
            stopAtChapterEnd = true
        case .minutes(let m) where m > 0:
            sleepTimer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(m * 60), repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSleepFired() }
            }
        default:
            break
        }
        audiobookLog("sleep option=\(option)")
    }

    private func startSleepTimerIfNeeded() {
        // Minute-based timers are absolute from when they were set; nothing to do
        // on resume. End-of-chapter is handled when the item finishes.
    }

    private func handleSleepFired() {
        pause()
        sleepOption = .off
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    // MARK: - Chapter loading

    private func loadCurrentChapter(autoPlay: Bool) {
        guard let store, chapters.indices.contains(chapterIndex) else {
            error = localized("未找到音訊")
            return
        }
        guard let id = bookId,
              let book = store.books.first(where: { $0.id == id })
                ?? (activeBook?.id == id ? activeBook : nil) else { return }

        let ref = chapters[chapterIndex]
        currentChapterTitle = ref.title
        isLoading = true
        error = nil
        let token = UUID()
        loadToken = token
        didSeekForResume = false
        updateNowPlaying()

        Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.chapterAudioProvider(for: book).audio(
                    for: book,
                    chapterIndex: self.chapterIndex,
                    store: store
                )
                guard self.loadToken == token else { return }
                audiobookLog("loadChapter ch=\(self.chapterIndex) audioURL=\(audio.url.absoluteString)")
                self.play(audio: audio, autoPlay: autoPlay)
            } catch let providerError as ChapterAudioProviderError {
                guard self.loadToken == token else { return }
                self.isLoading = false
                self.error = providerError.localizedDescription
                if case let .missingAudio(contentLength, preview) = providerError {
                    audiobookLog("loadChapter ch=\(self.chapterIndex) NO AUDIO URL contentLen=\(contentLength) head=\(preview)")
                }
            } catch {
                guard self.loadToken == token else { return }
                self.isLoading = false
                self.error = error.localizedDescription
                audiobookLog("loadChapter ch=\(self.chapterIndex) ERROR \(error.localizedDescription)")
            }
        }
    }

    private func play(audio: ChapterAudio, autoPlay: Bool) {
        let startSeconds = max(0, audio.chapterStartSeconds ?? 0)
        let durationOverride = audio.chapterDurationSeconds.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        let resumeTime = max(0, pendingResumeTime)

        if currentItemSourceURL == audio.url,
           let currentPlayer = player,
           currentPlayer.currentItem?.status == .readyToPlay {
            chapterStartSeconds = startSeconds
            chapterDurationOverride = durationOverride
            chapterFinishHandled = false
            didSeekForResume = true
            pendingResumeTime = 0
            isLoading = false
            teardownBoundaryObserver()
            updateDuration()
            installBoundaryObserverIfNeeded(on: currentPlayer)
            seekWithinCurrentChapter(to: resumeTime)
            if autoPlay {
                currentPlayer.rate = playbackRate
                isPlaying = true
            }
            updateNowPlaying()
            audiobookLog("reuse current audio item ch=\(chapterIndex) start=\(startSeconds) duration=\(durationOverride ?? -1)")
            return
        }

        // Stop the previous item but keep session/remote commands alive.
        teardownPlayerObservers()

        currentItemSourceURL = audio.url
        chapterStartSeconds = startSeconds
        chapterDurationOverride = durationOverride
        chapterFinishHandled = false

        // 番茄畅听-style URLs have no audio file extension and the CDN's Content-Type
        // is not one AVFoundation recognizes, so a plain AVURLAsset fails with
        // "無法打開". Route those through a resource loader that declares the MIME type
        // out-of-band. Ordinary .mp3/.m4a links keep the plain fast path.
        let asset: AVURLAsset
        if AudioStreamResourceLoader.requiresLoader(for: audio.url),
           let loaderAsset = AudioStreamResourceLoader.makeAsset(url: audio.url, headers: audio.headers) {
            asset = loaderAsset
        } else {
            let options: [String: Any] = audio.headers.isEmpty
                ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": audio.headers]
            asset = AVURLAsset(url: audio.url, options: options)
        }
        let item = AVPlayerItem(asset: asset)
        let newPlayer = player ?? AVPlayer()
        newPlayer.replaceCurrentItem(with: item)
        newPlayer.rate = 0
        player = newPlayer

        currentTime = 0
        duration = 0

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    self.updateDuration()
                    self.teardownBoundaryObserver()
                    self.installBoundaryObserverIfNeeded(on: newPlayer)
                    if !self.didSeekForResume {
                        self.didSeekForResume = true
                        let t = max(0, self.pendingResumeTime)
                        self.pendingResumeTime = 0
                        self.seekWithinCurrentChapter(to: t)
                    }
                    if autoPlay {
                        self.player?.rate = self.playbackRate
                        self.isPlaying = true
                    }
                    self.updateNowPlaying()
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.error = item.error?.localizedDescription ?? localized("未找到音訊")
                    audiobookLog("item failed: \(item.error?.localizedDescription ?? "?")")
                default:
                    break
                }
            }
            .store(in: &cancellables)

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.updateDuration()
                let relative = max(0, time.seconds - self.chapterStartSeconds)
                self.currentTime = min(relative, self.duration > 0 ? self.duration : relative)
                if let limit = self.chapterDurationOverride, relative > limit + 0.75 {
                    self.finishCurrentChapterIfNeeded()
                    return
                }
                self.persistPosition(force: false)
            }
        }

        NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification, object: item
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.finishCurrentChapterIfNeeded() }
        .store(in: &cancellables)
    }

    private func chapterAudioProvider(for book: ReadingBook) -> ChapterAudioProvider {
        book.isOnline ? onlineChapterAudioProvider : localChapterAudioProvider
    }

    private func seekWithinCurrentChapter(to relativeTime: TimeInterval) {
        let upperBound = duration > 0 ? duration : relativeTime
        let clamped = max(0, min(relativeTime, upperBound))
        let target = chapterStartSeconds + clamped
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    private func installBoundaryObserverIfNeeded(on player: AVPlayer) {
        guard let chapterDurationOverride, chapterDurationOverride > 0 else { return }
        let boundary = chapterStartSeconds + chapterDurationOverride
        guard boundary.isFinite, boundary > 0 else { return }
        boundaryObserverToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            Task { @MainActor in
                self?.finishCurrentChapterIfNeeded()
            }
        }
    }

    private func finishCurrentChapterIfNeeded() {
        guard !chapterFinishHandled else { return }
        chapterFinishHandled = true
        handleChapterFinished()
    }

    private func handleChapterFinished() {
        currentTime = duration
        persistPosition(force: true)
        if stopAtChapterEnd {
            stopAtChapterEnd = false
            sleepOption = .off
            isPlaying = false
            player?.pause()
            updateNowPlaying()
            return
        }
        if hasNextChapter {
            audiobookLog("chapter finished → auto-advance to \(chapterIndex + 1)")
            selectChapter(chapterIndex + 1)
        } else {
            isPlaying = false
            player?.pause()
            updateNowPlaying()
        }
    }

    // MARK: - Persistence

    private func persistPosition(force: Bool) {
        guard persistsPositionInStore else { return }
        guard let id = bookId else { return }
        if !force, Date().timeIntervalSince(lastPersist) < 10 { return }
        lastPersist = Date()
        store?.updateAudioPosition(
            bookId: id,
            chapter: chapterIndex,
            time: currentTime,
            totalChapters: chapters.count,
            forceSave: force
        )
    }

    // MARK: - Duration

    private func updateDuration() {
        guard let item = player?.currentItem, item.status == .readyToPlay else { return }
        if let chapterDurationOverride, chapterDurationOverride > 0 {
            duration = chapterDurationOverride
            return
        }
        let d = item.duration.seconds
        if d.isFinite, d > 0 {
            duration = max(0, d - chapterStartSeconds)
        }
    }

    // MARK: - Teardown

    private func teardownBoundaryObserver() {
        if let token = boundaryObserverToken {
            player?.removeTimeObserver(token)
            boundaryObserverToken = nil
        }
    }

    private func teardownPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        teardownBoundaryObserver()
        cancellables.removeAll()
    }

    private func stopInternal() {
        loadToken = UUID()
        player?.pause()
        teardownPlayerObservers()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentItemSourceURL = nil
        chapterStartSeconds = 0
        chapterDurationOverride = nil
        chapterFinishHandled = false
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func deactivateAudioSession() {
        UIApplication.shared.endReceivingRemoteControlEvents()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Now Playing + Remote commands

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = true
        c.skipBackwardCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.changePlaybackPositionCommand.isEnabled = true

        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentChapterTitle.isEmpty ? bookTitle : currentChapterTitle
        info[MPMediaItemPropertyArtist] = bookTitle
        info[MPMediaItemPropertyAlbumTitle] = bookTitle
        if let coverImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: coverImage.size) { _ in coverImage }
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = max(duration, 1)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(playbackRate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Cover

    private static func loadCover(_ filename: String?) -> UIImage? {
        guard let filename, !filename.isEmpty else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func loadRemoteCoverIfNeeded(for id: UUID, fallback: CoverFallback) {
        let headers = BookCoverLoader.headers(
            sourceBaseURL: fallback.sourceBaseURL,
            sourceHeaders: fallback.sourceHeaders
        )
        Task { [weak self] in
            guard let image = await BookCoverLoader.loadImage(
                urlString: fallback.urlString,
                headers: headers
            ) else { return }
            await MainActor.run {
                guard let self, self.bookId == id, self.coverImage == nil else { return }
                self.coverImage = image
            }
        }
    }
}

// MARK: - Logging

/// On-device audiobook playback diagnostics (Console.app, category `audiobook`).
/// Must NOT be `#if DEBUG`-gated: audiobook open failures ("未找到音訊" / AVPlayer
/// "無法打開") only reproduce against live sources on Release/TestFlight builds, and
/// the `item failed:` / `NO AUDIO URL contentLen=… head=…` lines are the only signal
/// for why a specific book (e.g. a VIP 番茄有聲 title) won't play. os_log surfaces in
/// Release; `print` behind `#if DEBUG` is invisible in the field.
private let audiobookOSLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.yuedu.app", category: "audiobook")

func audiobookLog(_ message: @autoclosure () -> String) {
    let text = message()
    audiobookOSLog.notice("[Audiobook] \(text, privacy: .public)")
}
