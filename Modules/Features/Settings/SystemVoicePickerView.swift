import AVFoundation
import Combine
import SwiftUI

/// Speaks one sample line so the user can hear a voice before choosing it.
///
/// Its own synthesizer on purpose: `TTSCoordinator` routes by the *active* TTS
/// source, so previewing through it would either speak with an HTTP source or
/// force the app's TTS source over to 系統離線語音 behind the user's back.
@MainActor
final class SystemVoicePreviewPlayer: NSObject, ObservableObject {
    /// Voices whose preview ran to completion without speaking a single word.
    ///
    /// iOS lists voices the user never downloaded, and `AVSpeechSynthesisVoice`
    /// exposes no property that tells them apart from installed ones — Apple
    /// acknowledged this as FB12994908 and has still shipped no availability API.
    /// Attempting the synthesis is therefore the only signal there is: an
    /// utterance that reaches `didFinish` without ever reporting a spoken range
    /// produced no audio, so the voice is not really on the device. Delete this
    /// the day `AVSpeechSynthesisVoice` gains an availability property.
    @Published private(set) var silentVoiceIdentifiers: Set<String> = []

    private let synthesizer = AVSpeechSynthesizer()
    /// The voice being previewed right now, and whether it has spoken anything.
    /// Cleared before we cancel a previous preview so our own `stopSpeaking`
    /// never gets mistaken for a voice that failed to speak.
    private var previewingIdentifier: String?
    private var didSpeakAnything = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(voice: AVSpeechSynthesisVoice, rate: Float) {
        AudioSessionActivator.activate(category: .playback)
        previewingIdentifier = nil
        synthesizer.stopSpeaking(at: .immediate)

        // The voice's own language, not the app's: an English voice handed a
        // Chinese line simply says nothing.
        let utterance = AVSpeechUtterance(string: SystemTTSVoiceCatalog.sampleText(for: voice))
        utterance.voice = voice
        utterance.rate = SystemTTSEngine.utteranceRate(forUIRate: rate)

        previewingIdentifier = voice.identifier
        didSpeakAnything = false
        silentVoiceIdentifiers.remove(voice.identifier)
        synthesizer.speak(utterance)
    }

    func stop() {
        previewingIdentifier = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SystemVoicePreviewPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.didSpeakAnything = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard let identifier = self.previewingIdentifier else { return }
            self.previewingIdentifier = nil
            guard !self.didSpeakAnything else { return }
            ttsLog("[TTS][VoicePreview] voice spoke nothing identifier=\(identifier)")
            self.silentVoiceIdentifiers.insert(identifier)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.previewingIdentifier = nil }
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
                Text(localized("iOS 會把尚未下載的語音一併列出，選了也發不出聲音。試聽沒有聲音的音色會標示為「此裝置未安裝」，到上面的系統設定把它下載下來就能用。"))
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
        if isSelected { _ = traits.insert(.isSelected) }
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
            // Without this only the label text is hit-testable: `.plain` drops the
            // button style's own row-wide shape, and `Spacer()` draws nothing to
            // tap. Same reason `TTSSettingsView`'s source rows carry it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("跟隨系統預設"))
        .accessibilityAddTraits(traits)
        // `children: .ignore` replaces the button's own element, so the activation
        // action has to be restated or VoiceOver's double-tap does nothing.
        .accessibilityAction {
            SystemTTSVoiceCatalog.clearSelection(forLanguage: group.id)
        }
    }

    private func voiceRow(
        _ voice: AVSpeechSynthesisVoice,
        in group: SystemTTSVoiceCatalog.VoiceGroup
    ) -> some View {
        let isSelected = SystemTTSVoiceCatalog.selectedIdentifier(forLanguage: group.id)
            == voice.identifier
        let quality = SystemTTSVoiceCatalog.qualityLabel(for: voice)
        let isPersonal = SystemTTSVoiceCatalog.isPersonalVoice(voice)
        let isNovelty = SystemTTSVoiceCatalog.isNoveltyVoice(voice)
        let isSilent = preview.silentVoiceIdentifiers.contains(voice.identifier)
        var traits: AccessibilityTraits = .isButton
        if isSelected { _ = traits.insert(.isSelected) }

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
                            .foregroundStyle(DSColor.textSecondary)
                        if isPersonal {
                            Text(localized("個人語音"))
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        if isNovelty {
                            Text(localized("趣味音色"))
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        if isSilent {
                            Text(localized("此裝置未安裝"))
                                .foregroundStyle(DSColor.warning)
                        }
                    }
                    .font(DSFont.caption)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            // See `systemDefaultRow`: `.plain` + a `Spacer()` leaves everything but
            // the voice name untappable, which read as "音色切換不了".
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One focus stop per voice: name spoken, quality as its value, 試聽 as a
        // rotor action rather than a second element to swipe past.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voice.name)
        .accessibilityValue(
            voiceAccessibilityValue(
                quality: quality,
                isPersonal: isPersonal,
                isNovelty: isNovelty,
                isSilent: isSilent
            )
        )
        .accessibilityAddTraits(traits)
        .accessibilityHint(localized("點兩下選用並試聽"))
        // Restates what `children: .ignore` discarded, so double-tap selects the
        // voice instead of falling through to nothing.
        .accessibilityAction {
            SystemTTSVoiceCatalog.select(voice)
            preview.play(voice: voice, rate: previewRate)
        }
        .accessibilityActions {
            Button(localized("試聽")) { preview.play(voice: voice, rate: previewRate) }
        }
    }

    /// Everything the row shows under the name, in one spoken string — VoiceOver
    /// reads the row as a single element, so the 此裝置未安裝 warning has to travel
    /// here or a blind user only finds out by hearing nothing.
    private func voiceAccessibilityValue(
        quality: String,
        isPersonal: Bool,
        isNovelty: Bool,
        isSilent: Bool
    ) -> String {
        var parts = [quality]
        if isPersonal { parts.append(localized("個人語音")) }
        if isNovelty { parts.append(localized("趣味音色")) }
        if isSilent { parts.append(localized("此裝置未安裝")) }
        return parts.joined(separator: "，")
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
