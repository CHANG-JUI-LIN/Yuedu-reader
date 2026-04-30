import SwiftUI

// MARK: - TTS 控制面板

struct TTSPanelView: View {
    @ObservedObject var tts: TTSCoordinator
    let currentText: String
    let chapterTitle: String
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            List {
                // 引擎標示
                Section {
                    NavigationLink(destination: TTSSettingsView()) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(DSColor.accent)
                            Text(localized("語音引擎"))
                            Spacer()
                            Text(localized(gs.ttsEngine.displayName))
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                }

                // 播放控制
                Section {
                    HStack {
                        Spacer()
                        // 上一頁 (未實作跨頁)
                        Button {
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 24))
                                .foregroundColor(DSColor.textSecondary)
                        }
                        .disabled(true)

                        Spacer()

                        // 播放 / 暫停
                        Button {
                            if tts.isPlaying {
                                tts.pause()
                            } else if !currentText.isEmpty {
                                tts.speak(text: currentText, title: chapterTitle)
                            }
                        } label: {
                            Image(
                                systemName: tts.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                            )
                            .font(.system(size: 52))
                            .foregroundColor(.accentColor)
                        }

                        Spacer()

                        // 停止
                        Button {
                            tts.stop()
                            dismiss()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.red.opacity(0.8))
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                // 語速
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

                // 定時停止
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 自動閱讀控制面板

struct AutoReadPanelView: View {
    @ObservedObject var autoReader: AutoReadController
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            List {
                // 播放控制
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

                // 速度
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) { dismiss() }
                }
            }
        }
    }
}
