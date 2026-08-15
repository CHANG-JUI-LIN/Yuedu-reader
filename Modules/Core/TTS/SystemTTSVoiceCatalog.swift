import AVFoundation
import Foundation

/// The device's installed speech voices, and the user's choice among them.
///
/// `AVSpeechSynthesisVoice(language:)` returns nothing but the system default
/// voice for a language, which is why 系統離線語音 sounded like exactly one voice
/// however many the device had installed. Everything iOS actually vends to a
/// third-party app is here:
///
/// - the preinstalled compact voices,
/// - any 增強 / 優質 voice the user downloaded in
///   設定 → 輔助使用 → 朗讀內容 → 語音 (they can also delete one, so a stored
///   choice must be re-resolved, never assumed present), and
/// - 個人語音 (iOS 17+) once the user grants access.
///
/// Siri's own voices are deliberately absent and cannot be added: Apple limits
/// them to its own system apps and does not vend them through `speechVoices()`
/// for third-party synthesis. There is no entitlement or API to opt in.
enum SystemTTSVoiceCatalog {

    /// One language's voices, for a sectioned picker.
    struct VoiceGroup: Identifiable {
        /// BCP-47 code, e.g. "zh-TW".
        let id: String
        let displayName: String
        let voices: [AVSpeechSynthesisVoice]
    }

    // MARK: - Enumeration

    /// Every voice the OS will let this app speak with, best quality first
    /// within each language.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if qualityRank(lhs) != qualityRank(rhs) { return qualityRank(lhs) > qualityRank(rhs) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Voices grouped by language. The device's own languages come first — a
    /// Chinese reader should not have to scroll past 40 locales to find 婷婷.
    static func groupedByLanguage() -> [VoiceGroup] {
        let preferred = Locale.preferredLanguages.map { $0.lowercased() }
        let grouped = Dictionary(grouping: installedVoices(), by: \.language)

        return grouped
            .map { language, voices in
                VoiceGroup(
                    id: language,
                    displayName: displayName(forLanguage: language),
                    voices: voices
                )
            }
            .sorted { lhs, rhs in
                let lhsRank = preferenceRank(lhs.id, preferred: preferred)
                let rhsRank = preferenceRank(rhs.id, preferred: preferred)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
    }

    static func displayName(forLanguage language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    /// 預設 / 增強 / 優質 — the label the user sees in iOS's own voice list.
    static func qualityLabel(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .enhanced: return localized("增強")
        case .premium: return localized("優質")
        default: return localized("預設")
        }
    }

    static func isPersonalVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.voiceTraits.contains(.isPersonalVoice)
    }

    // MARK: - Selection

    /// The voice the user picked for `language`, or nil to let the system decide.
    ///
    /// Falls back from an exact match ("zh-TW") to the same base language
    /// ("zh-*"): a reader who picked 美佳 for Traditional Chinese means it for
    /// Chinese, and text detected as zh-CN would otherwise silently revert to the
    /// system default.
    ///
    /// Returns nil when the stored identifier no longer resolves — a downloaded
    /// voice the user has since deleted — so playback falls back instead of
    /// failing.
    static func selectedVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let overrides = GlobalSettings.shared.ttsSystemVoiceIdentifiers
        guard !overrides.isEmpty else { return nil }

        if let identifier = overrides[language],
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        let base = baseLanguage(language)
        for (storedLanguage, identifier) in overrides
        where baseLanguage(storedLanguage) == base {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        }
        return nil
    }

    /// The identifier stored for `language` exactly (used to tick the right row).
    static func selectedIdentifier(forLanguage language: String) -> String? {
        GlobalSettings.shared.ttsSystemVoiceIdentifiers[language]
    }

    static func select(_ voice: AVSpeechSynthesisVoice) {
        var overrides = GlobalSettings.shared.ttsSystemVoiceIdentifiers
        overrides[voice.language] = voice.identifier
        GlobalSettings.shared.ttsSystemVoiceIdentifiers = overrides
    }

    /// Hand a language back to the system default.
    static func clearSelection(forLanguage language: String) {
        var overrides = GlobalSettings.shared.ttsSystemVoiceIdentifiers
        overrides.removeValue(forKey: language)
        GlobalSettings.shared.ttsSystemVoiceIdentifiers = overrides
    }

    static func clearAllSelections() {
        GlobalSettings.shared.ttsSystemVoiceIdentifiers = [:]
    }

    // MARK: - Personal Voice (iOS 17+)

    static var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
        AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    }

    /// Asks for access to the user's 個人語音. Granted voices then appear in
    /// `speechVoices()` like any other, so the picker just reloads afterwards.
    @discardableResult
    static func requestPersonalVoiceAccess() async
        -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
        await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
    }

    // MARK: - Private

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private static func baseLanguage(_ language: String) -> String {
        String(language.split(separator: "-").first ?? "").lowercased()
    }

    /// 0 for an exact device-language match, 1 for the same base language,
    /// 2 for everything else.
    private static func preferenceRank(_ language: String, preferred: [String]) -> Int {
        let lower = language.lowercased()
        if preferred.contains(lower) { return 0 }
        if preferred.contains(where: { baseLanguage($0) == baseLanguage(lower) }) { return 1 }
        return 2
    }
}
