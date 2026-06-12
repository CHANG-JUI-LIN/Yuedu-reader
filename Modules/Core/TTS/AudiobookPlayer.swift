import AVFoundation
import Combine
import Foundation
import MediaPlayer
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
    private let chapterAudioProvider: ChapterAudioProvider

    // MARK: - Engine

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var loadToken = UUID()
    private var pendingResumeTime: TimeInterval = 0
    private var didSeekForResume = false
    private var lastPersist: Date = .distantPast
    private var loadedRuntimeVariables: [String: String]?

    // MARK: - Sleep timer

    private var sleepTimer: Timer?
    private var stopAtChapterEnd = false

    // MARK: - Remote commands

    private var remoteCommandsConfigured = false

    private override init() {
        self.chapterAudioProvider = OnlineChapterAudioProvider()
        super.init()
    }

    // MARK: - Public lifecycle

    /// Whether a given book is the one currently loaded into the coordinator.
    func isActive(bookId id: UUID) -> Bool { bookId == id }

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
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        currentTime = clamped
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
                let audio = try await self.chapterAudioProvider.audio(
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
        // Stop the previous item but keep session/remote commands alive.
        teardownPlayerObservers()

        let options: [String: Any] = audio.headers.isEmpty
            ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": audio.headers]
        let asset = AVURLAsset(url: audio.url, options: options)
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
                    if !self.didSeekForResume, self.pendingResumeTime > 1 {
                        self.didSeekForResume = true
                        let t = self.pendingResumeTime
                        self.pendingResumeTime = 0
                        self.player?.seek(
                            to: CMTime(seconds: t, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                        self.currentTime = t
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
                self.currentTime = time.seconds
                self.updateDuration()
                self.persistPosition(force: false)
            }
        }

        NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification, object: item
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.handleChapterFinished() }
        .store(in: &cancellables)
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
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
    }

    // MARK: - Teardown

    private func teardownPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        cancellables.removeAll()
    }

    private func stopInternal() {
        loadToken = UUID()
        player?.pause()
        teardownPlayerObservers()
        player?.replaceCurrentItem(with: nil)
        player = nil
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
}

// MARK: - Logging

func audiobookLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Audiobook] \(message())")
    #endif
}
