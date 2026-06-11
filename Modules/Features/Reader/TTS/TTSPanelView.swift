import SwiftUI

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: TTSSettingsView()) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(DSColor.accent)
                            Text(localized("語音源設定"))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                    if usesSystemVoice {
                        Label(localized("未配置網路語音源，將使用系統離線語音朗讀"), systemImage: "iphone.gen2")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

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
                                        .font(.system(size: 24))
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
                                .font(.system(size: 52))
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
                                        .font(.system(size: 24))
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
                                .font(.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                }

                Section(header: Text(localized("語速"))) {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundColor(DSColor.textSecondary)
                        Slider(
                            value: Binding(
                                get: { tts.speechRate },
                                set: { tts.updateRate($0) }
                            ),
                            in: 0.1...0.65,
                            step: 0.05
                        )
                        Image(systemName: "speedometer")
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Text("\(localized("當前速度"))：\(String(format: "%.0f%%", tts.speechRate / 0.5 * 100))")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }

                Section(header: Text(localized("定時停止"))) {
                    ForEach([0, 15, 30, 60, 90], id: \.self) { min in
                        Button {
                            tts.setSleepTimer(minutes: min)
                        } label: {
                            HStack {
                                Text(min == 0 ? localized("不定時") : "\(min) \(localized("分鐘"))")
                                    .foregroundColor(.primary)
                                Spacer()
                                if tts.sleepMinutes == min {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
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
        }
    }
}

// MARK: - Auto Read Control Panel

struct AutoReadPanelView: View {
    @ObservedObject var autoReader: AutoReadController
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        Button {
                            autoReader.toggle()
                        } label: {
                            VStack(spacing: 6) {
                                Image(
                                    systemName: autoReader.isRunning
                                        ? "pause.circle.fill" : "play.circle.fill"
                                )
                                .font(.system(size: 52))
                                .foregroundColor(.accentColor)
                                Text(localized(autoReader.isRunning ? "暫停" : "開始自動翻頁"))
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section(header: Text(localized("翻頁速度"))) {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundColor(DSColor.textSecondary)
                        Slider(
                            value: Binding(
                                get: { autoReader.speed },
                                set: { autoReader.updateSpeed($0) }
                            ),
                            in: 0.5...5.0,
                            step: 0.5
                        )
                        Image(systemName: "speedometer")
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Text(
                        "\(localized("速度")) \(String(format: "%.1fx", autoReader.speed))（\(localized("約每")) \(String(format: "%.1f", max(0.5, 4.0 / autoReader.speed))) \(localized("秒翻一頁") )）"
                    )
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                }
            }
            .navigationTitle(localized("自動閱讀"))
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
        }
    }
}

#Preview {
    TTSPanelView(
        tts: TTSCoordinator(),
        chapters: [
            BookChapter(index: 0, title: "第一章", content: ""),
            BookChapter(index: 1, title: "第二章", content: "")
        ],
        currentReaderChapterIndex: 0,
        activeTTSChapterIndex: nil,
        activeChapterTitle: "第一章",
        onPlayPause: {},
        onPreviousChapter: { false },
        onNextChapter: { false },
        onSelectChapter: { _ in }
    )
}
