import SwiftUI

#Preview {
    TTSPanelView(
        tts: TTSCoordinator(),
        chapters: [],
        currentChapterID: nil,
        currentReaderChapterIndex: 0,
        activeTTSChapterIndex: nil,
        canGoNextChapter: true,
        activeChapterTitle: "第三章　霧港",
        coverImage: nil,
        bookTitle: "歸舟",
        bookAuthor: "",
        onPlayPause: {},
        onPreviousChapter: { false },
        onNextChapter: { false },
        onSelectChapter: { _ in },
        bookID: UUID(),
        detectedSpeakers: ["張若塵", "池瑤"],
        aiAdapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
        aiProgress: 0.42
    )
}

// MARK: - TTS Control Panel

/// The pages 語音朗讀 pushes in its own navigation.
private enum TTSPanelRoute: Hashable {
    case voiceSource
    case roleCast
    case highlight
}

/// 語音朗讀: a short sheet over the page being read. What is playing and the transport on
/// top, 語速 under them, and the settings that are set once and left as rows that push
/// their own pages — so the sheet fits its content instead of being a long form.
struct TTSPanelView: View {
    @ObservedObject var tts: TTSCoordinator
    /// The 目錄 the chapter list shows. Its positions are not the spine indices below: an
    /// EPUB's TOC can be shorter than its spine or hold several entries in one item.
    let chapters: [BookChapter]
    /// The entry the list checks: where narration is, or the reader while nothing is read.
    let currentChapterID: UUID?
    let currentReaderChapterIndex: Int
    let activeTTSChapterIndex: Int?
    /// Whether 下一章 has a chapter to read, decided where it is started.
    let canGoNextChapter: Bool
    let activeChapterTitle: String
    let coverImage: UIImage?
    let bookTitle: String
    /// Only for the generated cover a book without artwork gets.
    let bookAuthor: String
    let onPlayPause: () -> Void
    let onPreviousChapter: () -> Bool
    let onNextChapter: () -> Bool
    let onSelectChapter: (BookChapter) -> Void
    let bookID: UUID
    /// Characters detected in the chapter being read, for 多角色朗讀. Computed by the
    /// reader, which is the only thing holding the chapter's narration text.
    let detectedSpeakers: [String]
    /// Passed through to 多角色朗讀 so character cards can be built where they are used.
    let aiAdapter: AIBookContentAdapter
    /// Reading position on the chunks' 0…1 scale, so the character list defaults to who has
    /// actually appeared.
    let aiProgress: Double
    @Environment(\.dismiss) var dismiss
    @Bindable private var gs = GlobalSettings.shared
    @State private var showChapterPicker = false
    @State private var path: [TTSPanelRoute] = []
    /// Measured height of the list's content, so the sheet is exactly as tall as what it
    /// holds — the same fit 主題's panel has.
    @State private var contentHeight = DSLayout.ttsPanelSheetHeight

    /// The UI rate scale puts 1× at 0.5 (see `TTSCoordinator.minSpeechRate`).
    private static let normalSpeechRate: Float = 0.5
    /// The one-tap speeds. Anything else in the coordinator's range is still reached a
    /// tenth at a time with the stepper beside the value.
    private static let speechRatePresets: [Double] = [0.75, 1, 1.25, 1.5, 2]
    private static let speechRateStep: Float = 0.05

    // Playback is always available: when no HTTP source is configured, the coordinator falls
    // back to the on-device offline voice.
    private var hasAudioSource: Bool { true }

    private var usesSystemVoice: Bool {
        gs.ttsUseSystemVoice
            || gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The system voice saturates at `AVSpeechUtteranceMaximumSpeechRate`, so say so
    /// instead of letting the upper speeds do nothing.
    private var systemVoiceRateIsCapped: Bool {
        usesSystemVoice && tts.speechRate > SystemTTSEngine.maxSupportedUIRate
    }

    private var controlChapterIndex: Int {
        activeTTSChapterIndex ?? currentReaderChapterIndex
    }

    private var canGoPreviousChapter: Bool {
        controlChapterIndex > 0
    }

    private var isPlaying: Bool {
        tts.playbackState == .playing
    }

    /// Seeking needs a chapter that is loaded into segments.
    private var canSeek: Bool {
        tts.playbackState != .stopped && tts.totalSegments > 1
    }

    /// 「段落 12 / 40」, or nil before a chapter has been split into segments.
    private var paragraphText: String? {
        guard tts.playbackState != .stopped, tts.totalSegments > 0 else { return nil }
        return String(
            format: localized("段落 %1$d / %2$d"),
            tts.currentSegmentIndex + 1,
            tts.totalSegments
        )
    }

    private var speechMultiplier: Double {
        Double(tts.speechRate / Self.normalSpeechRate)
    }

    /// 「1.0×」 beside 語速; also what VoiceOver reads as the stepper's value.
    private var speechRateText: String {
        speechMultiplier.formatted(.number.precision(.fractionLength(1...2))) + "×"
    }

    private func presetTitle(_ multiplier: Double) -> String {
        multiplier.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var voiceSourceName: String {
        if usesSystemVoice { return localized("系統離線語音") }
        if gs.usesEdgeTTS { return localized("微軟線上語音") }
        if let source = gs.activeTTSSource { return source.name }
        // A template no imported source carries any more (the source was deleted while
        // selected): name it by where it points.
        let template = gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: template)?.host ?? template
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    nowPlayingRow
                    progressRow
                    transportRow
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    speechRateRow
                    speechRatePresetRow
                } footer: {
                    if systemVoiceRateIsCapped {
                        Text(
                            String(
                                format: localized("系統語音最快 %@（iOS 限制），需要更快請改用網路語音"),
                                String(format: "%.0f%%", SystemTTSEngine.maxSupportedUIRate / 0.5 * 100)
                            )
                        )
                        .dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()

                Section {
                    sleepTimerRow
                    NavigationLink(value: TTSPanelRoute.voiceSource) {
                        LabeledContent(localized("語音源"), value: voiceSourceName)
                    }
                    .accessibilityIdentifier("tts_panel_voice_source")
                    NavigationLink(value: TTSPanelRoute.roleCast) {
                        LabeledContent(
                            localized("多角色朗讀"),
                            value: localized(gs.ttsMultiRoleEnabled ? "開啟" : "關閉")
                        )
                    }
                    .accessibilityIdentifier("tts_panel_role_cast")
                    NavigationLink(value: TTSPanelRoute.highlight) {
                        LabeledContent(
                            localized("高亮與螢幕"),
                            value: localized(gs.ttsHighlightEnabled ? "朗讀高亮" : "關閉")
                        )
                    }
                    .accessibilityIdentifier("tts_panel_highlight")
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .measuredContentHeight($contentHeight)
            // No title bar: the grabber and the ✓ beside the chapter are the way out, and a
            // navigation chrome on top of the sheet ate height the controls could use.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TTSPanelRoute.self) { route in
                destination(for: route)
                    .toolbar(.visible, for: .navigationBar)
            }
            .pageBackgroundToolbar(for: .settings)
        }
        // A pushed page is a whole form: the sheet opens to full height while one is up,
        // and goes back to fitting the panel.
        .presentationDetents(path.isEmpty ? [.height(contentHeight)] : [.large])
        .presentationDragIndicator(.visible)
        .alert(
            localized("語音朗讀"),
            isPresented: Binding(
                get: { tts.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { tts.dismissError() }
                }
            )
        ) {
            Button(localized("好"), role: .cancel) { tts.dismissError() }
        } message: {
            Text(tts.errorMessage ?? "")
        }
        .sheet(isPresented: $showChapterPicker) {
            chapterPicker
        }
        .onChange(of: gs.ttsKeepsScreenAwake) { _, _ in
            tts.updateScreenAwakePreference()
        }
    }

    @ViewBuilder
    private func destination(for route: TTSPanelRoute) -> some View {
        switch route {
        case .voiceSource:
            TTSSettingsView(isPushed: true)
        case .roleCast:
            if aiAdapter.isPrepared {
                TTSRoleCastView(
                    bookID: bookID,
                    detectedSpeakers: detectedSpeakers,
                    adapter: aiAdapter,
                    progress: aiProgress
                )
            } else {
                ProgressView(localized("載入中…"))
            }
        case .highlight:
            TTSHighlightSettingsView()
        }
    }

    // MARK: - Now playing

    /// The cover and the chapter being read, which is also the way to pick another
    /// chapter, and ✓ to put the sheet away.
    private var nowPlayingRow: some View {
        HStack(spacing: DSSpacing.md) {
            Button {
                showChapterPicker = true
            } label: {
                HStack(spacing: DSSpacing.md) {
                    cover
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Text(activeChapterTitle)
                            .font(DSFont.headline)
                            .foregroundStyle(DSColor.textPrimary)
                        // The title gives way to a long name; 段落 12 / 40 never does.
                        HStack(spacing: 0) {
                            Text(bookTitle)
                            if let paragraphText {
                                Text((bookTitle.isEmpty ? "" : " · ") + paragraphText)
                                    .fixedSize()
                            }
                        }
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint(localized("目錄"))
            .accessibilityIdentifier("tts_panel_chapters")

            Button {
                dismiss()
            } label: {
                Label(localized("完成"), systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .font(DSFont.body.weight(.semibold))
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .ttsPanelDoneButtonStyle()
            .accessibilityLabel(localized("完成"))
        }
        .buttonStyle(.borderless)
    }

    private var cover: some View {
        Group {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: bookTitle, author: bookAuthor)
            }
        }
        .frame(width: DSLayout.ttsPanelCoverWidth, height: DSLayout.ttsPanelCoverHeight)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Where in the chapter the voice is, and the place to drag it somewhere else.
    private var progressRow: some View {
        TTSNarrationProgressRow(
            segmentIndex: tts.currentSegmentIndex,
            segmentCount: tts.totalSegments,
            canSeek: canSeek,
            paragraphText: paragraphText,
            onSeek: { tts.seekToProgress($0) }
        )
    }

    private var transportRow: some View {
        HStack {
            Spacer()
            chapterButton(
                titleKey: "上一章",
                systemImage: "backward.fill",
                enabled: canGoPreviousChapter
            ) {
                ttsLog("[TTS][Panel] previousChapterButton tapped state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                _ = onPreviousChapter()
            }
            Spacer()
            Button {
                ttsLog("[TTS][Panel] playButton tapped coordinatorPlaying=\(tts.isPlaying) state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                if hasAudioSource {
                    onPlayPause()
                } else {
                    ttsLog("[TTS][Panel] ignored play tap because audio source is not configured")
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(DSFont.title2)
                    .foregroundStyle(DSColor.background)
                    .frame(width: DSLayout.ttsPanelPlayButtonSize, height: DSLayout.ttsPanelPlayButtonSize)
                    .background(DSColor.textPrimary, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityIdentifier("tts_panel_play_pause")
            .accessibilityLabel(localized(isPlaying ? "暫停" : "播放"))
            .disabled(tts.playbackState == .stopped && !hasAudioSource)
            Spacer()
            chapterButton(
                titleKey: "下一章",
                systemImage: "forward.fill",
                enabled: canGoNextChapter
            ) {
                ttsLog("[TTS][Panel] nextChapterButton tapped state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                _ = onNextChapter()
            }
            Spacer()
        }
        // Each control takes its own taps; a plain row would turn the three into one button.
        .buttonStyle(.borderless)
        .padding(.vertical, DSSpacing.xs)
    }

    private func chapterButton(
        titleKey: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xxs) {
                Image(systemName: systemImage)
                    .font(DSFont.title3)
                    .accessibilityHidden(true)
                Text(localized(titleKey))
                    .font(DSFont.caption)
            }
            .foregroundStyle(DSColor.textPrimary)
            .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
        }
        .disabled(!hasAudioSource || !enabled)
    }

    // MARK: - 語速

    private var speechRateRow: some View {
        TTSSpeechRateRow(
            rate: Binding(
                get: { tts.speechRate },
                set: { tts.updateRate($0) }
            ),
            bounds: TTSCoordinator.minSpeechRate...TTSCoordinator.maxSpeechRate,
            step: Self.speechRateStep,
            rateText: speechRateText,
            onEditingEnded: { tts.applyRateToActivePlayback() }
        )
    }

    /// One tap to a common speed. A speed set with the stepper selects none of them.
    private var speechRatePresetRow: some View {
        Picker(
            localized("語速"),
            selection: Binding<Double?>(
                get: {
                    Self.speechRatePresets.first {
                        abs(Float($0) * Self.normalSpeechRate - tts.speechRate) < Self.speechRateStep / 2
                    }
                },
                set: { multiplier in
                    guard let multiplier else { return }
                    tts.updateRate(Float(multiplier) * Self.normalSpeechRate)
                    tts.applyRateToActivePlayback()
                }
            )
        ) {
            ForEach(Self.speechRatePresets, id: \.self) { multiplier in
                Text(presetTitle(multiplier)).tag(Optional(multiplier))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Settings rows

    private var sleepTimerRow: some View {
        Picker(
            localized("定時停止"),
            selection: Binding(
                get: { tts.sleepMinutes },
                set: { tts.setSleepTimer(minutes: $0) }
            )
        ) {
            Text(localized("不定時")).tag(0)
            ForEach([15, 30, 60, 90], id: \.self) { minutes in
                Text(String(format: localized("%d 分鐘"), minutes)).tag(minutes)
            }
        }
        .pickerStyle(.menu)
    }

    private var chapterPicker: some View {
        NavigationStack {
            List(chapters.indices, id: \.self) { index in
                Button {
                    showChapterPicker = false
                    onSelectChapter(chapters[index])
                } label: {
                    HStack {
                        Text(chapters[index].title)
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer()
                        if chapters[index].id == currentChapterID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .softScrollEdges()
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("目錄"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showChapterPicker = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
            }
        }
    }
}

// MARK: - 高亮與螢幕

/// What reading aloud does to the page and the screen: the highlight that follows the
/// voice, and keeping the screen on.
private struct TTSHighlightSettingsView: View {
    @Bindable private var gs = GlobalSettings.shared

    var body: some View {
        List {
            Section {
                Toggle(localized("朗讀高亮"), isOn: $gs.ttsHighlightEnabled)

                if gs.ttsHighlightEnabled {
                    ColorPicker(
                        localized("高亮顏色"),
                        selection: highlightColorBinding,
                        supportsOpacity: false
                    )

                    Toggle(localized("朗讀底色框"), isOn: $gs.ttsHighlightBoxEnabled)

                    if gs.ttsHighlightBoxEnabled {
                        Picker(localized("底色框樣式"), selection: $gs.ttsHighlightBoxStyleRaw) {
                            Text(localized("純色塊")).tag(0)
                            Text(localized("漸層膠囊")).tag(1)
                        }
                        .pickerStyle(.segmented)

                        ColorPicker(
                            localized("底色框顏色"),
                            selection: highlightBoxColorBinding,
                            supportsOpacity: false
                        )
                    }
                }
            } footer: {
                Text(localized("朗讀時高亮目前正在唸的文字。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Toggle(localized("朗讀時保持螢幕開啟"), isOn: $gs.ttsKeepsScreenAwake)
            } footer: {
                Text(localized("只防止自動鎖定，按下電源鍵仍可鎖屏並繼續朗讀。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationTitle(localized("高亮與螢幕"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var highlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: GlobalSettings.uiColor(rgbHex: gs.ttsHighlightColorHex)) },
            set: { gs.ttsHighlightColorHex = UIColor($0).rgbHex ?? GlobalSettings.defaultTTSHighlightColorHex }
        )
    }

    private var highlightBoxColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: GlobalSettings.uiColor(rgbHex: gs.ttsHighlightBoxColorHex)) },
            set: { gs.ttsHighlightBoxColorHex = UIColor($0).rgbHex ?? GlobalSettings.defaultTTSHighlightBoxColorHex }
        )
    }
}

private extension View {
    /// ✓ as a glass circle on iOS 26, the bordered circle before it.
    @ViewBuilder
    func ttsPanelDoneButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle)
        }
        #else
        buttonStyle(.bordered).buttonBorderShape(.circle)
        #endif
    }

    /// Reports the list's content height so the sheet's detent can match it. iOS 17 has
    /// no scroll-geometry callback for a `List`, so there the binding keeps its starting
    /// value and the list scrolls inside it.
    @ViewBuilder
    func measuredContentHeight(_ height: Binding<CGFloat>) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                // A height detent excludes the bottom safe area, which UIKit adds back.
                geometry.contentSize.height + geometry.contentInsets.top
            } action: { _, newHeight in
                guard newHeight > 0 else { return }
                height.wrappedValue = newHeight
            }
        } else {
            self
        }
    }
}

// MARK: - 朗讀進度

/// Where in the chapter the voice is, and the place to drag it somewhere else.
struct TTSNarrationProgressRow: View {
    /// The paragraph being read, and how many the chapter was split into.
    let segmentIndex: Int
    let segmentCount: Int
    /// Seeking needs a chapter that is loaded into segments.
    let canSeek: Bool
    /// 「段落 12 / 40」, what VoiceOver reads as the slider's value.
    let paragraphText: String?
    /// A place in the chapter, 0–1.
    let onSeek: (Double) -> Void

    /// The place under the finger while it drags.
    @State private var scrub: Double?

    private var playbackProgress: Double {
        guard canSeek else { return 0 }
        return progress(ofSegment: segmentIndex)
    }

    private func progress(ofSegment index: Int) -> Double {
        Double(index) / Double(segmentCount - 1)
    }

    var body: some View {
        VStack(spacing: DSSpacing.xs) {
            ScrubSlider(
                value: scrub ?? playbackProgress,
                tint: DSColor.textPrimary,
                onScrub: { scrub = $0 },
                onCommit: { progress in
                    onSeek(progress)
                    scrub = nil
                },
                // A paragraph per swipe, the unit 段落 12 / 40 counts in. The slider's own
                // step, a tenth of the chapter, skips paragraphs in a long chapter and rounds
                // back to the same one in a chapter of five or fewer.
                onIncrement: segmentIndex + 1 < segmentCount
                    ? { onSeek(progress(ofSegment: segmentIndex + 1)) } : nil,
                onDecrement: segmentIndex > 0
                    ? { onSeek(progress(ofSegment: segmentIndex - 1)) } : nil
            )
            .disabled(!canSeek)
            .accessibilityLabel(localized("朗讀進度"))
            .accessibilityValue(paragraphText ?? "")
            HStack {
                Text(localized("章節開始"))
                Spacer()
                Text(localized("章節結尾"))
            }
            .font(DSFont.caption)
            .foregroundStyle(DSColor.textSecondary)
            .accessibilityHidden(true)
        }
    }
}

#Preview("朗讀進度") {
    TTSNarrationProgressRow(
        segmentIndex: 11,
        segmentCount: 40,
        canSeek: true,
        paragraphText: String(format: localized("段落 %1$d / %2$d"), 12, 40),
        onSeek: { _ in }
    )
    .padding(DSSpacing.lg)
}

// MARK: - 語速

/// 語速 and its value, with a tenth-at-a-time stepper for the speeds between and
/// beyond the presets — the panel's slider used to reach 0.2×–5×.
struct TTSSpeechRateRow: View {
    @Binding var rate: Float
    let bounds: ClosedRange<Float>
    let step: Float
    /// 「1.0×」 beside 語速; also what VoiceOver reads as the stepper's value.
    let rateText: String
    let onEditingEnded: () -> Void

    var body: some View {
        Stepper(value: $rate, in: bounds, step: step) {
            HStack {
                Text(localized("語速"))
                    .font(DSFont.headline)
                Spacer()
                Text(rateText)
                    .font(DSFont.headline.monospacedDigit())
            }
        } onEditingChanged: { editingChanged($0) }
        // A Stepper reads everything in its label into the name of both its buttons, and adds
        // an `.accessibilityLabel` to that rather than replacing it: each button read
        // 「語速、1.0×、語速, 增量」 and then 1.0× again as its value. VoiceOver gets a stepper
        // labelled 語速 alone instead: one adjustable element, read 「語速, 1.0×」, that a swipe
        // up or down moves a step — the gesture of 朗讀進度 just above it.
        .accessibilityRepresentation {
            Stepper(localized("語速"), value: $rate, in: bounds, step: step) { editingChanged($0) }
                .accessibilityValue(rateText)
        }
    }

    /// Once per press, not per step: re-synthesising HTTP audio on every tick
    /// would hammer rate-limited sources. A VoiceOver swipe is a press.
    private func editingChanged(_ editing: Bool) {
        if !editing { onEditingEnded() }
    }
}

#Preview("語速") {
    @Previewable @State var rate: Float = 0.5
    List {
        TTSSpeechRateRow(
            rate: $rate,
            bounds: TTSCoordinator.minSpeechRate...TTSCoordinator.maxSpeechRate,
            step: 0.05,
            rateText: (Double(rate) / 0.5).formatted(.number.precision(.fractionLength(1...2))) + "×",
            onEditingEnded: {}
        )
    }
}
