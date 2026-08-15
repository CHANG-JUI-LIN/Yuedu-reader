import AVFoundation
import Combine
import SwiftUI

/// Speaks one sample line so the user can hear a voice before choosing it.
///
/// Its own synthesizer on purpose: `TTSCoordinator` routes by the *active* TTS
/// source, so previewing through it would either speak with an HTTP source or
/// force the app's TTS source over to 系統離線語音 behind the user's back.
@MainActor
final class SystemVoicePreviewPlayer: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func play(voice: AVSpeechSynthesisVoice, rate: Float) {
        AudioSessionActivator.activate(category: .playback)
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: localized("這是一段試聽文字，用來確認語音音色。"))
        utterance.voice = voice
        utterance.rate = SystemTTSEngine.utteranceRate(forUIRate: rate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Picks which installed system voice reads each language.
///
/// Before this screen the app only ever used `AVSpeechSynthesisVoice(language:)`,
/// i.e. one system-chosen voice per language, so every 增強/優質 voice the user
/// had downloaded went unused.
struct SystemVoicePickerView: View {
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var preview = SystemVoicePreviewPlayer()
    @State private var groups: [SystemTTSVoiceCatalog.VoiceGroup] = []
    @State private var personalVoiceStatus = SystemTTSVoiceCatalog.personalVoiceStatus
    @State private var isRequestingPersonalVoice = false

    /// The rate the reader is set to, so a preview sounds like real playback.
    private var previewRate: Float { TTSCoordinator.persistedSpeechRate }

    var body: some View {
        Form {
            personalVoiceSection

            if groups.isEmpty {
                Section {
                    Text(localized("這台裝置上沒有可用的語音。"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }

            ForEach(groups) { group in
                Section {
                    systemDefaultRow(for: group)
                    ForEach(group.voices, id: \.identifier) { voice in
                        voiceRow(voice, in: group)
                    }
                } header: {
                    Text(group.displayName)
                }
                .interfaceSectionSurface()
            }

            Section {
                Text(localized("想要更多音色，可到「設定 → 輔助使用 → 朗讀內容 → 語音」下載增強或優質語音，下載後會出現在這裡。Siri 音色由系統保留給內建 App，第三方 App 無法使用。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("系統語音音色"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(localized("重設")) {
                    SystemTTSVoiceCatalog.clearAllSelections()
                }
                .disabled(gs.ttsSystemVoiceIdentifiers.isEmpty)
            }
        }
        .onAppear(perform: reload)
        // iOS posts this when voices are installed or removed — including the
        // moment 個人語音 access is granted — so the list is never stale.
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVSpeechSynthesizer.availableVoicesDidChangeNotification
            )
        ) { _ in
            reload()
        }
        .onDisappear { preview.stop() }
    }

    // MARK: - Personal Voice

    @ViewBuilder
    private var personalVoiceSection: some View {
        // .unsupported = the device can't do Personal Voice at all; showing the
        // row there would only offer something that can never work.
        if personalVoiceStatus != .unsupported {
            Section {
                switch personalVoiceStatus {
                case .authorized:
                    Label(localized("已允許使用個人語音"), systemImage: "checkmark.circle")
                        .foregroundStyle(DSColor.textSecondary)
                case .denied:
                    Text(localized("個人語音未獲授權。可到「設定 → 輔助使用 → 個人語音」重新允許。"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                default:
                    Button {
                        requestPersonalVoice()
                    } label: {
                        Label(localized("允許使用個人語音"), systemImage: "waveform.badge.mic")
                    }
                    .disabled(isRequestingPersonalVoice)
                }
            } header: {
                Text(localized("個人語音"))
            } footer: {
                Text(localized("個人語音是你在「設定 → 輔助使用 → 個人語音」錄製的聲音。授權後會出現在下方語音列表中。"))
            }
            .interfaceSectionSurface()
        }
    }

    private func requestPersonalVoice() {
        isRequestingPersonalVoice = true
        Task {
            let status = await SystemTTSVoiceCatalog.requestPersonalVoiceAccess()
            personalVoiceStatus = status
            isRequestingPersonalVoice = false
            reload()
        }
    }

    // MARK: - Rows

    private func systemDefaultRow(for group: SystemTTSVoiceCatalog.VoiceGroup) -> some View {
        let isSelected = SystemTTSVoiceCatalog.selectedIdentifier(forLanguage: group.id) == nil
        var traits: AccessibilityTraits = .isButton
        if isSelected { traits.insert(.isSelected) }
        return Button {
            SystemTTSVoiceCatalog.clearSelection(forLanguage: group.id)
        } label: {
            HStack {
                Text(localized("跟隨系統預設"))
                    .foregroundStyle(DSColor.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        // The .isSelected trait already says this; left visible
                        // it would just read out "checkmark".
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("跟隨系統預設"))
        .accessibilityAddTraits(traits)
    }

    private func voiceRow(
        _ voice: AVSpeechSynthesisVoice,
        in group: SystemTTSVoiceCatalog.VoiceGroup
    ) -> some View {
        let isSelected = SystemTTSVoiceCatalog.selectedIdentifier(forLanguage: group.id)
            == voice.identifier
        let quality = SystemTTSVoiceCatalog.qualityLabel(for: voice)
        let isPersonal = SystemTTSVoiceCatalog.isPersonalVoice(voice)
        var traits: AccessibilityTraits = .isButton
        if isSelected { traits.insert(.isSelected) }

        return Button {
            SystemTTSVoiceCatalog.select(voice)
            preview.play(voice: voice, rate: previewRate)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: DSSpacing.xs) {
                        Text(quality)
                        if isPersonal {
                            Text(localized("個人語音"))
                        }
                    }
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        // One focus stop per voice: name spoken, quality as its value, 試聽 as a
        // rotor action rather than a second element to swipe past.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voice.name)
        .accessibilityValue(isPersonal ? quality + "，" + localized("個人語音") : quality)
        .accessibilityAddTraits(traits)
        .accessibilityHint(localized("點兩下選用並試聽"))
        .accessibilityActions {
            Button(localized("試聽")) { preview.play(voice: voice, rate: previewRate) }
        }
    }

    private func reload() {
        groups = SystemTTSVoiceCatalog.groupedByLanguage()
        personalVoiceStatus = SystemTTSVoiceCatalog.personalVoiceStatus
    }
}

#Preview {
    NavigationStack {
        SystemVoicePickerView()
    }
}
