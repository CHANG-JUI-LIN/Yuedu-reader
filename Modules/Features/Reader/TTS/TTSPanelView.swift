import SwiftUI

#Preview {
    TTSPanelView(
        tts: TTSCoordinator(),
        chapters: [],
        currentReaderChapterIndex: 0,
        activeTTSChapterIndex: nil,
        activeChapterTitle: "",
        onPlayPause: {},
        onPreviousChapter: { false },
        onNextChapter: { false },
        onSelectChapter: { _ in },
        bookID: UUID(),
        detectedSpeakers: ["張若塵", "池瑤"]
    )
}

// MARK: - TTS Control Panel

struct TTSPanelView: View {
    @ObservedObject var tts: TTSCoordinator
    let chapters: [BookChapter]
    let currentReaderChapterIndex: Int
    let activeTTSChapterIndex: Int?
    let activeChapterTitle: String
    let onPlayPause: () -> Void
    let onPreviousChapter: () -> Bool
    let onNextChapter: () -> Bool
    let onSelectChapter: (Int) -> Void
    let bookID: UUID
    /// Characters detected in the chapter being read, for 多角色朗讀. Computed by the
    /// reader, which is the only thing holding the chapter's narration text.
    let detectedSpeakers: [String]
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var showChapterPicker = false

    // Playback is always available: when no HTTP source is configured, the coordinator falls
    // back to the on-device offline voice.
    private var hasAudioSource: Bool { true }

    private var usesSystemVoice: Bool {
        gs.ttsUseSystemVoice
            || gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The system voice saturates at `AVSpeechUtteranceMaximumSpeechRate`, so say so
    /// instead of letting the upper half of the slider do nothing.
    private var systemVoiceRateIsCapped: Bool {
        usesSystemVoice && tts.speechRate > SystemTTSEngine.maxSupportedUIRate
    }

    private var controlChapterIndex: Int {
        activeTTSChapterIndex ?? currentReaderChapterIndex
    }

    private var canGoPreviousChapter: Bool {
        controlChapterIndex > 0
    }

    private var canGoNextChapter: Bool {
        controlChapterIndex < chapters.count - 1
    }

    private var playbackProgress: Double {
        guard tts.totalSegments > 1 else { return 0 }
        return Double(tts.currentSegmentIndex) / Double(tts.totalSegments - 1)
    }

    /// Speech rate as the percentage shown under the slider; also what VoiceOver reads
    /// as the slider's value, so it doesn't fall back to a raw fraction of the range.
    private var speechRateText: String {
        String(format: "%.0f%%", tts.speechRate / 0.5 * 100)
    }

    var body: some View {
        NavigationStack {
            List {
                if let notice = tts.playbackNotice {
                    Section {
                        HStack(alignment: .top, spacing: DSSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(DSColor.textSecondary)
                                .accessibilityHidden(true)
                            Text(notice)
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                            Spacer(minLength: 0)
                            Button {
                                tts.dismissPlaybackNotice()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(DSColor.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localized("關閉提示"))
                        }
                    }
                    .interfaceSectionSurface()
                }

                Section {
                    NavigationLink(destination: TTSSettingsView()) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(DSColor.accent)
                                .accessibilityHidden(true)
                            Text(localized("語音源設定"))
                            Spacer()
                        }
                    }
                    NavigationLink(
                        destination: TTSRoleCastView(bookID: bookID, detectedSpeakers: detectedSpeakers)
                    ) {
                        HStack {
                            Image(systemName: "person.2.wave.2")
                                .foregroundColor(DSColor.accent)
                                .accessibilityHidden(true)
                            Text(localized("多角色朗讀"))
                            Spacer()
                            if gs.ttsMultiRoleEnabled {
                                Text(localized("開啟"))
                                    .font(DSFont.subheadline)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    }
                    if usesSystemVoice {
                        Label(localized("未配置網路語音源，將使用系統離線語音朗讀"), systemImage: "iphone.gen2")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
                .interfaceSectionSurface()

                Section {
                    VStack(spacing: 16) {
                        if tts.playbackState != .stopped, tts.totalSegments > 0 {
                            Text("\(localized("章節進度")) \(tts.currentSegmentIndex + 1) / \(tts.totalSegments)")
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }

                        HStack {
                            Spacer()
                            Button {
                                ttsLog("[TTS][Panel] previousChapterButton tapped state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                                _ = onPreviousChapter()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "backward.fill")
                                        .font(DSFont.fixed(size: 24))
                                    Text(localized("上一章"))
                                        .font(DSFont.caption)
                                }
                                .foregroundColor(DSColor.textSecondary)
                            }
                            .disabled(!hasAudioSource || !canGoPreviousChapter)

                            Spacer()

                            Button {
                                ttsLog("[TTS][Panel] playButton tapped coordinatorPlaying=\(tts.isPlaying) state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                                if hasAudioSource {
                                    onPlayPause()
                                } else {
                                    ttsLog("[TTS][Panel] ignored play tap because audio source is not configured")
                                }
                            } label: {
                                Image(
                                    systemName: tts.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill"
                                )
                                .font(DSFont.fixed(size: 52))
                                .foregroundColor(.accentColor)
                            }
                            .disabled(tts.playbackState == .stopped && !hasAudioSource)

                            Spacer()

                            Button {
                                ttsLog("[TTS][Panel] nextChapterButton tapped state=\(tts.playbackState) chapter=\(controlChapterIndex)")
                                _ = onNextChapter()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "forward.fill")
                                        .font(DSFont.fixed(size: 24))
                                    Text(localized("下一章"))
                                        .font(DSFont.caption)
                                }
                                .foregroundColor(DSColor.textSecondary)
                            }
                            .disabled(!hasAudioSource || !canGoNextChapter)

                            Spacer()
                        }
                        .buttonStyle(.borderless)

                        if tts.playbackState != .stopped, tts.totalSegments > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { isScrubbing ? scrubProgress : playbackProgress },
                                        set: { scrubProgress = $0 }
                                    ),
                                    in: 0...1,
                                    onEditingChanged: { editing in
                                        isScrubbing = editing
                                        if editing {
                                            scrubProgress = playbackProgress
                                        } else {
                                            tts.seekToProgress(scrubProgress)
                                        }
                                    }
                                )
                                HStack {
                                    Text(localized("章節開始"))
                                    Spacer()
                                    Text(localized("章節結尾"))
                                }
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .interfaceSectionSurface()

                Section {
                    Button {
                        showChapterPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet")
                                .foregroundColor(DSColor.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localized("目錄"))
                                Text(activeChapterTitle)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                }
                .interfaceSectionSurface()

                Section(header: Text(localized("語速"))) {
                    HStack {
                        // Slow/fast end-caps, the same tortoise/hare pair Apple uses for
                        // playback speed. Hidden from VoiceOver: as plain images they were
                        // two focusable elements announcing a raw SF Symbol name on either
                        // side of the control they only illustrate.
                        Image(systemName: "tortoise")
                            .foregroundColor(DSColor.textSecondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: Binding(
                                get: { tts.speechRate },
                                set: { tts.updateRate($0) }
                            ),
                            in: TTSCoordinator.minSpeechRate...TTSCoordinator.maxSpeechRate,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing { tts.applyRateToActivePlayback() }
                            }
                        )
                        .accessibilityLabel(localized("語速"))
                        .accessibilityValue(speechRateText)
                        Image(systemName: "hare")
                            .foregroundColor(DSColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text("\(localized("當前速度"))：\(speechRateText)")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                    if systemVoiceRateIsCapped {
                        Text(
                            String(
                                format: localized("系統語音最快 %@（iOS 限制），需要更快請改用網路語音"),
                                String(format: "%.0f%%", SystemTTSEngine.maxSupportedUIRate / 0.5 * 100)
                            )
                        )
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                    }
                }
                .interfaceSectionSurface()

                Section(header: Text(localized("定時停止"))) {
                    Menu {
                        Button(localized("不定時")) { tts.setSleepTimer(minutes: 0) }
                        ForEach([15, 30, 60, 90], id: \.self) { min in
                            Button("\(min) \(localized("分鐘"))") { tts.setSleepTimer(minutes: min) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "moon.zzz")
                                .foregroundColor(DSColor.textSecondary)
                            Text(localized("定時停止"))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(sleepTimerLabel)
                                .foregroundColor(DSColor.textSecondary)
                                .font(DSFont.caption)
                        }
                    }
                }
                .interfaceSectionSurface()

                Section {
                    Toggle(localized("朗讀時保持螢幕開啟"), isOn: $gs.ttsKeepsScreenAwake)
                } header: {
                    Text(localized("播放行為"))
                } footer: {
                    Text(localized("只防止自動鎖定，按下電源鍵仍可鎖屏並繼續朗讀。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()

                Section {
                    Toggle(localized("朗讀高亮"), isOn: ttsHighlightEnabledBinding)

                    if gs.ttsHighlightEnabled {
                        ColorPicker(
                            localized("高亮顏色"),
                            selection: ttsHighlightColorBinding,
                            supportsOpacity: false
                        )

                        Toggle(localized("朗讀底色框"), isOn: ttsHighlightBoxEnabledBinding)

                        if gs.ttsHighlightBoxEnabled {
                            Picker(localized("底色框樣式"), selection: ttsHighlightBoxStyleBinding) {
                                Text(localized("純色塊")).tag(0)
                                Text(localized("漸層膠囊")).tag(1)
                            }
                            .pickerStyle(.segmented)

                            ColorPicker(
                                localized("底色框顏色"),
                                selection: ttsHighlightBoxColorBinding,
                                supportsOpacity: false
                            )
                        }
                    }
                } header: {
                    Text(localized("高亮"))
                } footer: {
                    Text(localized("朗讀時高亮目前正在唸的文字。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(localized("語音朗讀"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
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
                NavigationStack {
                    List(chapters.indices, id: \.self) { index in
                        Button {
                            showChapterPicker = false
                            onSelectChapter(index)
                        } label: {
                            HStack {
                                Text(chapters[index].title)
                                    .foregroundColor(.primary)
                                Spacer()
                                if index == controlChapterIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
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
                        }
                    }
                }
            }
            .onChange(of: tts.currentSegmentIndex) { _, _ in
                if !isScrubbing {
                    scrubProgress = playbackProgress
                }
            }
            .onChange(of: gs.ttsKeepsScreenAwake) { _, _ in
                tts.updateScreenAwakePreference()
            }
        }
    }
}

// MARK: - TTS Highlight bindings + sleep label

private extension TTSPanelView {
    var sleepTimerLabel: String {
        tts.sleepMinutes == 0 ? localized("不定時") : "\(tts.sleepMinutes) \(localized("分鐘"))"
    }

    var ttsHighlightEnabledBinding: Binding<Bool> {
        Binding(get: { gs.ttsHighlightEnabled }, set: { gs.ttsHighlightEnabled = $0 })
    }

    var ttsHighlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: GlobalSettings.uiColor(rgbHex: gs.ttsHighlightColorHex)) },
            set: { gs.ttsHighlightColorHex = UIColor($0).rgbHex ?? GlobalSettings.defaultTTSHighlightColorHex }
        )
    }

    var ttsHighlightBoxEnabledBinding: Binding<Bool> {
        Binding(get: { gs.ttsHighlightBoxEnabled }, set: { gs.ttsHighlightBoxEnabled = $0 })
    }

    var ttsHighlightBoxColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: GlobalSettings.uiColor(rgbHex: gs.ttsHighlightBoxColorHex)) },
            set: { gs.ttsHighlightBoxColorHex = UIColor($0).rgbHex ?? GlobalSettings.defaultTTSHighlightBoxColorHex }
        )
    }

    var ttsHighlightBoxStyleBinding: Binding<Int> {
        Binding(get: { gs.ttsHighlightBoxStyleRaw }, set: { gs.ttsHighlightBoxStyleRaw = $0 })
    }
}
