import AVFoundation
import SwiftUI

/// 多角色朗讀 — assigns a voice to each character so a novel is read as a cast rather
/// than by one narrator.
///
/// Scoped to the open book: the same name is a different person in a different novel, and
/// the speaker list is read out of the chapter being listened to, so the names on screen
/// are the ones about to be spoken.
struct TTSRoleCastView: View {
    let bookID: UUID
    /// Speakers found in the chapter being read, in the order they first speak.
    let detectedSpeakers: [String]

    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var family: TTSVoiceFamily { .active() }
    private var cast: [String: String] { TTSRoleVoiceCast.cast(forBook: bookID, in: gs.ttsRoleVoices) }

    /// Characters cast earlier that this chapter does not happen to include. Without this
    /// they would look un-cast, and re-casting them would silently replace a deliberate
    /// choice made while reading a different chapter.
    private var castElsewhere: [String] {
        cast.keys.filter { !detectedSpeakers.contains($0) }.sorted()
    }

    var body: some View {
        Form {
            enableSection
            if family.supportsMultiRole {
                detectedSection
                if !castElsewhere.isEmpty { elsewhereSection }
            }
        }
        .navigationTitle(localized("多角色朗讀"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(localized("重設")) {
                    gs.ttsRoleVoices = TTSRoleVoiceCast.clearing(bookID: bookID, in: gs.ttsRoleVoices)
                }
                .disabled(cast.isEmpty)
            }
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(localized("多角色朗讀"), isOn: $gs.ttsMultiRoleEnabled)
                .disabled(!family.supportsMultiRole)
        } footer: {
            Text(enableFooterText).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var enableFooterText: String {
        switch family {
        case .system:
            return localized("為每個角色指派不同的系統語音。未指派的角色與旁白共用同一個聲音。")
        case .edge:
            return localized("為每個角色指派不同的微軟線上語音。角色越多，每章需要合成的片段也越多。")
        case .bookSource:
            return localized("目前使用的是匯入的語音源，它的音色寫死在網址裡，無法逐段更換。請改用系統語音或微軟線上語音。")
        }
    }

    private var detectedSection: some View {
        Section {
            if detectedSpeakers.isEmpty {
                Text(localized("這一章沒有偵測到對話。"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                ForEach(detectedSpeakers, id: \.self) { speaker in
                    speakerRow(speaker)
                }
            }
        } header: {
            Text(localized("本章角色"))
        } footer: {
            Text(localized("角色是從「某某說道：「…」」這類敘述裡讀出來的，判斷不出來的對話會用旁白的聲音。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var elsewhereSection: some View {
        Section {
            ForEach(castElsewhere, id: \.self) { speaker in
                speakerRow(speaker)
            }
        } header: {
            Text(localized("其他已指派的角色"))
        } footer: {
            Text(localized("這些角色在本書其他章節出現過。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    // MARK: - Rows

    private func speakerRow(_ speaker: String) -> some View {
        let assigned = cast[speaker].flatMap(TTSRoleVoice.init(storageValue:))
        return NavigationLink {
            TTSRoleVoicePickerView(bookID: bookID, speaker: speaker)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Text(speaker)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.sm)
                Text(voiceLabel(for: assigned))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        // One focus stop per character, reading the name and the voice together, rather
        // than the two labels VoiceOver would otherwise land on separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(speaker)，\(voiceLabel(for: assigned))")
        .accessibilityHint(localized("選擇這個角色的聲音"))
    }

    /// What a row says about a character's voice — including the case the whole tagging
    /// scheme exists for: cast with a voice the running engine cannot speak.
    private func voiceLabel(for voice: TTSRoleVoice?) -> String {
        guard let voice else { return localized("旁白") }
        switch (voice, family) {
        case let (.system(identifier), .system):
            return AVSpeechSynthesisVoice(identifier: identifier)?.name ?? localized("語音已移除")
        case let (.edge(voiceID), .edge):
            return EdgeTTSVoice.voice(id: voiceID)?.displayName ?? localized("語音已移除")
        default:
            return localized("目前的語音來源不支援")
        }
    }
}

/// Picks one voice for one character, from whichever catalogue the running engine uses.
struct TTSRoleVoicePickerView: View {
    let bookID: UUID
    let speaker: String

    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var family: TTSVoiceFamily { .active() }
    private var current: TTSRoleVoice? {
        TTSRoleVoiceCast.cast(forBook: bookID, in: gs.ttsRoleVoices)[speaker]
            .flatMap(TTSRoleVoice.init(storageValue:))
    }

    var body: some View {
        Form {
            Section {
                row(title: localized("旁白"), isSelected: current == nil) { assign(nil) }
            } footer: {
                Text(localized("與沒有指派聲音的角色、以及旁白文字使用同一個聲音。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            switch family {
            case .system: systemVoiceSections
            case .edge: edgeVoiceSection
            case .bookSource: EmptyView()
            }
        }
        .navigationTitle(speaker)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    @ViewBuilder
    private var systemVoiceSections: some View {
        ForEach(SystemTTSVoiceCatalog.groupedByLanguage()) { group in
            Section {
                ForEach(group.voices, id: \.identifier) { voice in
                    row(
                        title: voice.name,
                        detail: SystemTTSVoiceCatalog.qualityLabel(for: voice),
                        isSelected: current?.systemIdentifier == voice.identifier
                    ) {
                        assign(.system(identifier: voice.identifier))
                    }
                }
            } header: {
                Text(group.displayName)
            }
            .interfaceSectionSurface()
        }
    }

    private var edgeVoiceSection: some View {
        Section {
            ForEach(EdgeTTSVoice.voices) { voice in
                row(
                    title: voice.displayName,
                    isSelected: current?.edgeVoice?.id == voice.id
                ) {
                    assign(.edge(voiceID: voice.id))
                }
            }
        } header: {
            Text(localized("微軟線上語音"))
        }
        .interfaceSectionSurface()
    }

    private func row(
        title: String,
        detail: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        var traits: AccessibilityTraits = .isButton
        if isSelected { _ = traits.insert(.isSelected) }
        return Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(DSColor.textPrimary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        // Decorative: the selected state is already in the traits, and
                        // VoiceOver would otherwise read the raw symbol name.
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
    }

    private func assign(_ voice: TTSRoleVoice?) {
        gs.ttsRoleVoices = TTSRoleVoiceCast.setting(
            voiceIdentifier: voice?.storageValue,
            forSpeaker: speaker,
            bookID: bookID,
            in: gs.ttsRoleVoices
        )
        dismiss()
    }
}

#Preview("角色列表") {
    NavigationStack {
        TTSRoleCastView(
            bookID: UUID(),
            detectedSpeakers: ["張若塵", "池瑤", "齊源老道"]
        )
    }
}

#Preview("沒有偵測到對話") {
    NavigationStack {
        TTSRoleCastView(bookID: UUID(), detectedSpeakers: [])
    }
}
