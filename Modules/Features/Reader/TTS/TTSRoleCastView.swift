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
    /// The book, for building character cards from here — the aliases they produce are what
    /// stop one person being cast as three.
    let adapter: AIBookContentAdapter
    /// How far the reader has got, so the character list can default to people who have
    /// actually appeared rather than spoiling the rest of the book.
    let progress: Double

    @ObservedObject private var gs = GlobalSettings.shared
    @ObservedObject private var cards = AICharacterCardStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAISettings = false
    @State private var showResetConfirmation = false
    @ObservedObject private var rosters = AISpeakerRosterStore.shared
    /// Resolved on appear: `isConfigured` reads the Keychain, and `body` runs often.
    @State private var aiConfigured = false

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
            // Outside the multi-role gate on purpose: character cards are worth having
            // before a second voice exists — they are a reading aid in their own right, and
            // the aliases have to be there the moment the reader does import one. Hiding
            // them behind the toggle made them unreachable for anyone on a single source.
            aliasSection
            if supportsMultiRole {
                detectedSection
                if !castElsewhere.isEmpty { elsewhereSection }
            }
        }
        .navigationTitle(localized("多角色朗讀"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            aiConfigured = AIAssistantService.shared.isConfigured
            cards.loadIfNeeded(forBook: bookID)
            rosters.loadIfNeeded(forBook: bookID)
        }
        .sheet(isPresented: $showAISettings, onDismiss: {
            aiConfigured = AIAssistantService.shared.isConfigured
        }) {
            AISettingsView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(localized("重設")) {
                    showResetConfirmation = true
                }
                // Dead only when there is genuinely nothing for this book: no cast, no
                // roster, no cards. It used to test the cast alone, so it sat greyed out
                // while a roster and a pile of character cards existed behind it.
                .disabled(!hasAnythingToReset)
            }
        }
        .confirmationDialog(
            localized("重設這本書的角色設定？"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("重設"), role: .destructive) { resetBook() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("會清掉這本書的配音、AI 整理的角色名單，以及所有人物卡。書本身和聽書設定不受影響。"))
        }
    }

    private var hasAnythingToReset: Bool {
        !cast.isEmpty
            || !rosters.roster(forBook: bookID).isEmpty
            || !cards.profiles(forBook: bookID).isEmpty
    }

    private func resetBook() {
        gs.ttsRoleVoices = TTSRoleVoiceCast.clearing(bookID: bookID, in: gs.ttsRoleVoices)
        rosters.clear(forBook: bookID)
        for profile in cards.profiles(forBook: bookID) {
            cards.remove(name: profile.name, forBook: bookID)
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(localized("多角色朗讀"), isOn: $gs.ttsMultiRoleEnabled)
                .disabled(!supportsMultiRole)
        } footer: {
            Text(enableFooterText).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// Re-read from the live source list rather than the default argument, so importing a
    /// second voice enables the toggle without leaving this screen.
    private var supportsMultiRole: Bool {
        family.supportsMultiRole(importedSourceCount: gs.importedTTSSources.count)
    }

    private var enableFooterText: String {
        switch family {
        case .system:
            return localized("為每個角色指派不同的系統語音。未指派的角色與旁白共用同一個聲音。")
        case .edge:
            return localized("為每個角色指派不同的微軟線上語音。角色越多，每章需要合成的片段也越多。")
        case .bookSource:
            // One source is one voice, so the cast is the list of imported sources. A reader
            // with only one has nothing to switch between — which is a missing import, not
            // an unsupported engine.
            return supportsMultiRole
                ? localized("為每個角色指派不同的匯入語音源。角色越多，每章需要的請求也越多。")
                : localized("匯入的語音源一個就是一個聲音，目前只匯入了一個。到語音朗讀設定再匯入幾個（語音包通常一個音色一筆），就能指派給不同角色。")
        }
    }

    /// Why the same character can end up with three voices, and what to do about it.
    ///
    /// The dialogue heuristic reads a name out of the prose; it cannot know that 張若塵,
    /// 若塵 and 塵哥 are one person. The AI character cards are the only thing that can tell
    /// it, so this is where that connection is made visible — including when the AI is not
    /// set up, which is the common case and must not look like a malfunction.
    @ViewBuilder
    private var aliasSection: some View {
        let aliasCount = cards.aliasMap(forBook: bookID).count
        let cardCount = cards.profiles(forBook: bookID).count
        Section {
            if !aiConfigured {
                Button {
                    showAISettings = true
                } label: {
                    LabeledContent(localized("設定 AI 助手")) {
                        Text(localized("未設定"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            NavigationLink {
                AICharacterListView(bookID: bookID, adapter: adapter, progress: progress)
            } label: {
                LabeledContent(localized("人物卡")) {
                    Text(
                        cardCount == 0
                            ? localized("還沒有人物卡")
                            : String(format: localized("%1$d 張人物卡、%2$d 個別名"), cardCount, aliasCount)
                    )
                    .foregroundStyle(DSColor.textSecondary)
                }
            }
        } header: {
            Text(localized("角色識別"))
        } footer: {
            Text(
                aiConfigured
                    ? localized("整理人物卡之後，同一個人的不同稱呼（張若塵／若塵／塵哥）會歸成同一個聲音。")
                    : localized("沒有 AI 也能用，只是同一個人的不同稱呼會各拿一個聲音。")
            )
            .dsSectionFooter()
        }
        .interfaceSectionSurface()
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
        case (.bookSource, .bookSource):
            return voice.importedSource()?.name ?? localized("語音已移除")
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
            case .bookSource: importedSourceSection
            }
        }
        .navigationTitle(speaker)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    /// Each imported voice source is one voice.
    ///
    /// A voice pack ships one entry per speaker, so the list the reader already sees under
    /// 語音朗讀設定 is exactly the cast they can draw from.
    private var importedSourceSection: some View {
        Section {
            ForEach(gs.importedTTSSources) { source in
                row(
                    title: source.name,
                    isSelected: current == .bookSource(sourceID: source.id)
                ) {
                    assign(.bookSource(sourceID: source.id))
                }
            }
        } header: {
            Text(localized("匯入的語音源"))
        } footer: {
            Text(localized("每個匯入的語音源就是一個聲音。想要更多音色，就到語音朗讀設定匯入更多來源。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
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
            detectedSpeakers: ["張若塵", "池瑤", "齊源老道"],
            adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
            progress: 0.42
        )
    }
}

#Preview("沒有偵測到對話") {
    NavigationStack {
        TTSRoleCastView(
            bookID: UUID(),
            detectedSpeakers: [],
            adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
            progress: 0.42
        )
    }
}
