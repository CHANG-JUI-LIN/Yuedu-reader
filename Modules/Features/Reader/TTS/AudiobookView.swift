import AVFoundation
import CoreImage
import SwiftUI

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
    @State private var showChapterList = false
    @State private var showSleepTimer = false
    @State private var baseColor: Color = DSColor.coverGradients[0][0]

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
            if let book = store.books.first(where: { $0.id == bookId }) {
                player.start(book: book, store: store)
            }
            updateBaseColor()
        }
        .onChanged(of: player.bookId) { _ in updateBaseColor() }
        .onChanged(of: player.currentTime) { t in
            if !isDraggingSlider { sliderValue = t }
        }
        .sheet(isPresented: $showChapterList) {
            AudiobookChapterListView(player: player)
        }
        .sheet(isPresented: $showSleepTimer) {
            AudiobookSleepTimerView(player: player)
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(localized("收合"))
            Spacer()
            Text(localized("有聲書"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            // Symmetry spacer matching the close button width.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.top, DSSpacing.sm)
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
                        .font(.system(size: 64))
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
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(player.bookTitle)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Button(localized("重試")) {
                player.selectChapter(player.chapterIndex)
            }
            .foregroundColor(.white)
            .font(.subheadline.weight(.semibold))
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
                    isDraggingSlider = editing
                    if !editing { player.seek(to: sliderValue) }
                }
            )
            .tint(.white)
            .disabled(player.isLoading || player.duration <= 0)

            HStack {
                Text(Self.formatTime(sliderValue))
                Spacer()
                Text(Self.formatTime(player.duration))
            }
            .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 64))
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
                .font(.system(size: size, weight: .medium))
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
            Button { showChapterList = true } label: {
                bottomItem(text: localized("目錄"), systemImage: "list.bullet")
            }
            Spacer()
            Button { showSleepTimer = true } label: {
                bottomItem(text: sleepLabel, systemImage: "moon.zzz")
            }
        }
        .padding(.horizontal, DSSpacing.xxl)
    }

    private func bottomItem(text: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.9))
        .frame(minWidth: 56)
    }

    private var sleepLabel: String {
        switch player.sleepOption {
        case .off: return localized("定時")
        case .endOfChapter: return localized("本章結束")
        case .minutes(let m): return "\(m)\(localized("分鐘"))"
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
        guard let image, let cg = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cg)
        let extent = ciImage.extent
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: CIVector(cgRect: extent)]
        ), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Darken slightly so white controls stay legible on pale covers.
        let scale = 0.82
        return Color(
            red: Double(bitmap[0]) / 255 * scale,
            green: Double(bitmap[1]) / 255 * scale,
            blue: Double(bitmap[2]) / 255 * scale
        )
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
                                .foregroundColor(.primary)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if chapter.index == player.chapterIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .id(chapter.index)
                }
                .onAppear { proxy.scrollTo(player.chapterIndex, anchor: .center) }
            }
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
                option(localized("關閉"), isSelected: player.sleepOption == .off) {
                    player.setSleepOption(.off)
                }
                option(localized("本章結束"), isSelected: player.sleepOption == .endOfChapter) {
                    player.setSleepOption(.endOfChapter)
                }
                ForEach(minuteOptions, id: \.self) { m in
                    option("\(m) \(localized("分鐘"))", isSelected: player.sleepOption == .minutes(m)) {
                        player.setSleepOption(.minutes(m))
                    }
                }
            }
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
    }
}

#if DEBUG
#Preview {
    AudiobookReaderView(bookId: UUID())
        .environmentObject(BookStore())
}
#endif
