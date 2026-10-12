import AVFoundation
import CoreImage
import SwiftUI
import UIKit

// MARK: - Audiobook Reader (dedicated full-screen player page)
//
// The reader for `.audio` books. `BookReaderView` routes here once a book is
// detected as an audiobook. Playback itself lives in the long-lived
// `AudiobookPlayer.shared` singleton, so dismissing this page keeps audio going
// with lock-screen controls; re-opening re-attaches to the live session.

struct AudiobookReaderView: View {
    let bookId: UUID

    @EnvironmentObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudiobookPlayer.shared

    @State private var sliderValue: Double = 0
    @State private var isDraggingSlider = false
    /// The chapter the slider is scrubbing; its position is only meaningful on that chapter.
    @State private var scrubbedChapter: Int?
    @State private var showChapterList = false
    @State private var showSleepTimer = false
    @State private var showSkipCredits = false
    @State private var baseColor: Color = DSColor.coverGradients[0][0]
    @State private var sourcePage: ReaderHTMLUtilities.ReviewTarget?

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()
            Color.black.opacity(0.18).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: DSSpacing.lg)
                coverArt
                Spacer(minLength: DSSpacing.lg)
                titleBlock
                    .padding(.horizontal, DSSpacing.xl)
                if let message = player.error {
                    errorBlock(message)
                }
                progressSection
                    .padding(.top, DSSpacing.lg)
                transportRow
                    .padding(.top, DSSpacing.xl)
                bottomRow
                    .padding(.top, DSSpacing.xl)
                    .padding(.bottom, DSSpacing.xl)
            }
        }
        // Dark styling for THIS page only. `.preferredColorScheme(.dark)` applies to the
        // whole window, which flipped the bookshelf dark for an instant during the
        // fullScreenCover transition (the "theme flashes black" bug). The environment
        // override scopes the dark appearance to this subtree; the page paints its own
        // dark gradient background, so nothing else is needed.
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let book = store.readingBook(id: bookId) {
                player.start(book: book, store: store)
                SourceCallBackService.notify(.startRead, book: book, chapter: currentCallBackChapter)
            } else if !player.isActive(bookId: bookId) {
                dismiss()
            }
            updateBaseColor()
        }
        // legado `AudioPlayActivity` sends endRead when its player screen goes away.
        .onDisappear {
            if let book = store.readingBook(id: bookId) {
                SourceCallBackService.notify(.endRead, book: book, chapter: currentCallBackChapter)
            }
        }
        .onChanged(of: player.bookId) { _ in updateBaseColor() }
        .onChanged(of: player.currentTime) { t in
            if !isDraggingSlider { sliderValue = t }
        }
        .sheet(item: $sourcePage) { target in
            LegadoReviewBrowserView(target: target) { _ in sourcePage = nil }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChapterList) {
            AudiobookChapterListView(player: player)
        }
        .sheet(isPresented: $showSleepTimer) {
            AudiobookSleepTimerView(player: player)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSkipCredits) {
            AudiobookSkipCreditsView(player: player)
                .presentationDetents([.medium])
        }
    }

    // MARK: Background

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [baseColor, baseColor.opacity(0.55), Color.black.opacity(0.92)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func updateBaseColor() {
        baseColor = Self.dominantColor(from: player.coverImage) ?? DSColor.coverGradients[0][0]
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(DSFont.fixed(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(localized("收合"))
            Spacer()
            Text(localized("有聲書"))
                .font(DSFont.fixed(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if let source = callBackSource {
                sourceMenu(source)
            } else {
                // Symmetry spacer matching the close button width.
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.top, DSSpacing.sm)
    }

    // MARK: Source events (legado `AudioPlayActivity` custom button / 複製播放 URL)

    /// The book's source when it listens for events or asks for its own button.
    private var callBackSource: BookSource? {
        guard let id = store.readingBook(id: bookId)?.bookSourceId,
              let source = BookSourceStore.shared.source(id: id),
              SourceCallBackService.isListening(source) || SourceCallBackService.showsCustomButton(source)
        else { return nil }
        return source
    }

    private var currentCallBackChapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot? {
        player.chapters.indices.contains(player.chapterIndex)
            ? SourceCallBackService.chapterSnapshot(player.chapters[player.chapterIndex]) : nil
    }

    private func sourceMenu(_ source: BookSource) -> some View {
        Menu {
            if SourceCallBackService.showsCustomButton(source) {
                Button { runSourceTap(.clickCustomButton, source: source, result: nil, fallback: nil) } label: {
                    Label(localized("自訂按鈕"), systemImage: "hand.tap")
                }
            }
            if let url = player.currentAudioURL?.absoluteString {
                Button {
                    runSourceTap(.clickCopyPlayUrl, source: source, result: url) {
                        UIPasteboard.general.string = url
                        BookSourceFormLoginView.presentToastAlert(message: localized("已複製"))
                    }
                } label: {
                    Label(localized("複製播放網址"), systemImage: "link")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.fixed(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(localized("更多"))
    }

    private func runSourceTap(
        _ event: SourceCallBackEvent, source: BookSource, result: String?,
        fallback: (@MainActor () -> Void)?
    ) {
        guard let book = store.readingBook(id: bookId) else { return }
        let chapter = currentCallBackChapter
        Task { @MainActor in
            let outcome = await SourceCallBackService.tap(
                event, source: source,
                book: SourceCallBackService.snapshot(of: book, chapter: chapter),
                runtimeVariables: book.runtimeVariables ?? [:], chapter: chapter, result: result
            )
            if let page = outcome.page {
                // The script ran for seconds; the menu that started it is long gone.
                sourcePage = page
            }
            if SourceCallBackService.shouldFallBack(outcome) {
                fallback?()
            }
        }
    }

    // MARK: Cover

    private var coverArt: some View {
        Group {
            if let image = player.coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.12))
                    Image(systemName: "headphones")
                        .font(DSFont.fixed(size: 64))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 260, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        .overlay {
            if player.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(player.currentChapterTitle.isEmpty ? player.bookTitle : player.currentChapterTitle)
                .font(DSFont.fixed(size: 18, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(player.bookTitle)
                .font(DSFont.fixed(size: 14))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(DSFont.caption)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Button(localized("重試")) {
                player.retryCurrentChapter()
            }
            .foregroundColor(.white)
            .font(DSFont.subheadline.weight(.semibold))
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.sm)
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: $sliderValue,
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isDraggingSlider = true
                        scrubbedChapter = player.chapterIndex
                    } else if isDraggingSlider {
                        // Seek once per scrub. After a release at the far end the player
                        // received a seek to the current chapter's end every ~40 ms
                        // (simulator, CoreMedia log), and each one finished whichever
                        // chapter was current by then — chapters were skipped.
                        isDraggingSlider = false
                        player.seek(to: sliderValue, inChapter: scrubbedChapter)
                        scrubbedChapter = nil
                    }
                }
            )
            .tint(.white)
            .disabled(player.isLoading || player.duration <= 0)

            HStack {
                Text(Self.formatTime(sliderValue))
                Spacer()
                Text(Self.formatTime(player.duration))
            }
            .font(DSFont.fixed(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, DSSpacing.xl)
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack {
            transportButton("backward.end.fill", size: 24, enabled: player.hasPreviousChapter) {
                player.previousChapter()
            }
            .accessibilityLabel(localized("上一章"))
            Spacer()
            transportButton("gobackward.15", size: 30) { player.skipBackward(15) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(DSFont.fixed(size: 64))
                    .foregroundColor(.white)
            }
            .disabled(player.isLoading)
            Spacer()
            transportButton("goforward.15", size: 30) { player.skipForward(15) }
            Spacer()
            transportButton("forward.end.fill", size: 24, enabled: player.hasNextChapter) {
                player.nextChapter()
            }
            .accessibilityLabel(localized("下一章"))
        }
        .padding(.horizontal, DSSpacing.xl)
    }

    private func transportButton(
        _ systemName: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DSFont.fixed(size: size, weight: .medium))
                .foregroundColor(.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 50, height: 50)
        }
        .disabled(!enabled)
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack {
            Menu {
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if player.playbackRate == rate {
                            Label(Self.rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(Self.rateLabel(rate))
                        }
                    }
                }
            } label: {
                bottomItem(text: Self.rateLabel(player.playbackRate), systemImage: "speedometer")
            }
            Spacer()
            // legado's play-mode button: each tap moves on to the next mode.
            Button { cyclePlayMode() } label: {
                bottomItem(text: player.playMode.localizedTitle, systemImage: player.playMode.systemImage)
            }
            .accessibilityLabel(localized("播放模式"))
            .accessibilityValue(player.playMode.localizedTitle)
            Spacer()
            Button { showChapterList = true } label: {
                bottomItem(text: localized("目錄"), systemImage: "list.bullet")
            }
            Spacer()
            Button { showSleepTimer = true } label: {
                bottomItem(text: sleepLabel, systemImage: "moon.zzz")
            }
            Spacer()
            Button { showSkipCredits = true } label: {
                // Filled while this book skips credits: a cue that is not colour.
                bottomItem(
                    text: localized("片頭片尾"),
                    systemImage: skipsCredits ? "forward.fill" : "forward"
                )
            }
            .accessibilityLabel(localized("跳過片頭片尾"))
            .accessibilityValue(skipCreditsValue)
        }
        // Five items: the narrower inset of the transport row above keeps them on one line
        // on a 375 pt screen.
        .padding(.horizontal, DSSpacing.xl)
    }

    private func cyclePlayMode() {
        player.cyclePlayMode()
        // The button's value changes under VoiceOver's focus without being read out.
        AccessibilityNotification.Announcement(player.playMode.localizedTitle).post()
    }

    private var skipsCredits: Bool {
        player.openingCreditsSeconds > 0 || player.closingCreditsSeconds > 0
    }

    private var skipCreditsValue: String {
        guard skipsCredits else { return localized("狀態：關閉") }
        return String(
            format: localized("片頭 %d 秒，片尾 %d 秒"),
            player.openingCreditsSeconds,
            player.closingCreditsSeconds
        )
    }

    private func bottomItem(text: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(DSFont.fixed(size: 18, weight: .medium))
            Text(text)
                .font(DSFont.fixed(size: 11, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.9))
        // Reader chrome keeps a 44 pt target (docs/design.md); icon and caption are shorter.
        .frame(minWidth: 56, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var sleepLabel: String {
        switch player.sleepOption {
        case .off: return localized("定時")
        case .endOfChapter: return localized("本章結束")
        case .minutes(let m): return String(format: localized("%d 分鐘"), m)
        }
    }

    // MARK: Helpers

    static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() { return "\(Int(rate)).0x" }
        return "\(rate)x"
    }

    static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Average color of the cover, used to tint the player background. Returns nil
    /// when there is no cover so callers can fall back to the palette.
    static func dominantColor(from image: UIImage?) -> Color? {
        // Darken slightly so white controls stay legible on pale covers.
        image.flatMap(CoverTint.average(of:))?.scaled(by: 0.82).color
    }
}

// MARK: - Chapter list

struct AudiobookChapterListView: View {
    @ObservedObject var player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters, id: \.index) { chapter in
                    Button {
                        player.selectChapter(chapter.index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title.isEmpty
                                 ? String(format: localized("第 %d 章"), chapter.index + 1)
                                 : chapter.title)
                                .foregroundStyle(DSColor.textPrimary)
                                .font(DSFont.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if chapter.index == player.chapterIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .interfaceSectionSurface()
                    .id(chapter.index)
                }
                .softScrollEdges()
                .onAppear { proxy.scrollTo(player.chapterIndex, anchor: .center) }
            }
            // Rows carry their own surface; the modifier below only clears the list
            // container, not each row's system fill. docs/design.md §4.1.
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("目錄"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}

// MARK: - Sleep timer

struct AudiobookSleepTimerView: View {
    @ObservedObject var player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    private let minuteOptions = [10, 15, 20, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                option(localized("狀態：關閉"), isSelected: player.sleepOption == .off) {
                    player.setSleepOption(.off)
                }
                option(localized("本章結束"), isSelected: player.sleepOption == .endOfChapter) {
                    player.setSleepOption(.endOfChapter)
                }
                ForEach(minuteOptions, id: \.self) { m in
                    option(String(format: localized("%d 分鐘"), m), isSelected: player.sleepOption == .minutes(m)) {
                        player.setSleepOption(.minutes(m))
                    }
                }
            }
            .softScrollEdges()
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("睡眠定時"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }

    private func option(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
        // Applied here rather than at each call site so every option row keeps the
        // shared surface instead of the opaque system default. docs/design.md §4.1.
        .interfaceSectionSurface()
    }
}

// MARK: - Skip credits

/// legado-E / legado-with-MD3 跳過片頭片尾: the seconds skipped at the start and cut at the
/// end of every chapter of this book, 0–180 each, in whole seconds as legado has them.
struct AudiobookSkipCreditsView: View {
    @ObservedObject var player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var openingSeconds: Double
    @State private var closingSeconds: Double

    private let range = Double(AudiobookPlayer.creditsSecondsRange.lowerBound)
        ... Double(AudiobookPlayer.creditsSecondsRange.upperBound)

    init(player: AudiobookPlayer) {
        self.player = player
        _openingSeconds = State(initialValue: Double(player.openingCreditsSeconds))
        _closingSeconds = State(initialValue: Double(player.closingCreditsSeconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsSliderRow(
                        title: localized("片頭"),
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        valueText: Self.secondsText(openingSeconds),
                        value: $openingSeconds,
                        range: range,
                        step: 1
                    )
                    SettingsSliderRow(
                        title: localized("片尾"),
                        systemImage: "text.line.last.and.arrowtriangle.forward",
                        valueText: Self.secondsText(closingSeconds),
                        value: $closingSeconds,
                        range: range,
                        step: 1
                    )
                } footer: {
                    Text(localized("只套用在這本書；片頭只在章節從頭播放時跳過。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("跳過片頭片尾"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.setSkipCredits(
                            openingSeconds: Int(openingSeconds.rounded()),
                            closingSeconds: Int(closingSeconds.rounded())
                        )
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private static func secondsText(_ seconds: Double) -> String {
        String(format: localized("%d 秒"), Int(seconds.rounded()))
    }
}

// MARK: - Play mode presentation

private extension AudiobookPlayMode {
    /// legado-with-MD3's names for the modes (`audio_play_mode_*`).
    var localizedTitle: String {
        switch self {
        case .listEndStop: return localized("順序播放")
        case .singleLoop: return localized("單曲循環")
        case .random: return localized("隨機播放")
        case .listLoop: return localized("列表循環")
        }
    }

    var systemImage: String {
        switch self {
        case .listEndStop: return "arrow.right.to.line"
        case .singleLoop: return "repeat.1"
        case .random: return "shuffle"
        case .listLoop: return "repeat"
        }
    }
}

#if DEBUG
#Preview {
    AudiobookReaderView(bookId: UUID())
        .environmentObject(BookStore())
}

#Preview("跳過片頭片尾") {
    AudiobookSkipCreditsView(player: .shared)
}
#endif
