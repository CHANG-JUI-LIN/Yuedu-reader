import SwiftUI

struct TTSSettingsView: View {
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var testCoordinator = TTSCoordinator()

    var body: some View {
        Form {
            Section(header: Text(localized("語音源 URL 模板"))) {
                TextEditor(text: $gs.httpTtsUrlTemplate)
                    .frame(minHeight: 80)
                    .font(.system(.footnote, design: .monospaced))

                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("目前沒有內建雲端 TTS。這裡需要填入能直接回傳音訊資料的接口。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .padding(.bottom, 4)
                    Text(localized("支援的佔位符："))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    placeholderRow("{{text}}", desc: localized("段落文字（URL 編碼）"))
                    placeholderRow("{{title}}", desc: localized("章節標題（URL 編碼）"))
                    placeholderRow("{{speakSpeed}}", desc: localized("語速，範圍 0.10–0.65"))
                }
                .padding(.vertical, 4)

                HStack(spacing: 36) {
                    Spacer()
                    Button {
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }
                    .disabled(true)

                    Button {
                        toggleTestPlayback()
                    } label: {
                        Image(systemName: testCoordinator.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46))
                    }
                    .disabled(gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                    .disabled(true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(localized("語音朗讀設定"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            testCoordinator.stop()
        }
    }

    // MARK: - Private

    private func placeholderRow(_ placeholder: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(placeholder)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(DSColor.accent)
            Text("—")
                .font(.caption)
                .foregroundColor(DSColor.textSecondary)
            Text(desc)
                .font(.caption)
                .foregroundColor(DSColor.textSecondary)
        }
    }

    private func toggleTestPlayback() {
        switch testCoordinator.playbackState {
        case .playing:
            testCoordinator.pause()
        case .paused:
            testCoordinator.resume()
        case .stopped:
            testCoordinator.stop(reason: "restart test playback")
            testCoordinator.speak(text: "這是一段測試文字，用於確認 HTTP TTS 引擎設定是否正確。", title: "測試")
        }
    }
}
