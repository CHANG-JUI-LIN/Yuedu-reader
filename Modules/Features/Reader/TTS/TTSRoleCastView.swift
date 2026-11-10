import AVFoundation
import SwiftUI

/// 多角色朗讀 — reads a novel as a cast rather than by one narrator.
///
/// With AI: each chapter is analysed before it is read — who speaks every line, with what
/// emotion — and characters get voices matched to their gender and age. The reader can
/// override any of it. Without AI the speakers are read off 「某某說」 in the prose.
///
/// Scoped to the open book: the same name is a different person in a different novel.
struct TTSRoleCastView: View {
    let bookID: UUID
    let context: TTSRoleCastContext
    /// The book, for building character cards from here — the aliases they produce are what
    /// stop one person being cast as three.
    let adapter: AIBookContentAdapter
    /// How far the reader has got, so the character list can default to people who have
    /// actually appeared rather than spoiling the rest of the book.
    let progress: Double
    let onPreAnalyze: (Int) -> Void
    let onCastChanged: () -> Void

    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var cards = AICharacterCardStore.shared
    @ObservedObject private var subscription = SubscriptionStore.shared
    @State private var showAISettings = false
    @State private var showResetConfirmation = false
    /// Resolved on appear: `isConfigured` reads the Keychain, and `body` runs often.
    @State private var aiConfigured = false
    @State private var analysisError: String?
    @State private var fingerprintOnAppear: CastFingerprint?

    private var service: AIDialogueCastService { .shared }
    private var family: TTSVoiceFamily { .active() }
    private var allowsAI: Bool { ReaderPremiumVisibilityPolicy(isProActive: subscription.isProActive).allowsAI }
    private var explicitCast: [String: String] { TTSRoleVoiceCast.cast(forBook: bookID, in: gs.ttsRoleVoices) }
    private var autoCast: [String: String] {
        gs.ttsAutoCastEnabled ? service.autoVoices(forBook: bookID, family: family) : [:]
    }
    private var roster: TTSDialogueRoster { service.roster(forBook: bookID) }
    private var dialogue: TTSChapterDialogue? { context.request.flatMap(service.cachedChapter) }
    private var chapterState: AIDialogueCastService.ChapterState? { context.request.flatMap(service.state(of:)) }

    /// The chapter's speakers: the AI's when it has analysed the chapter, else the prose's.
    private var chapterSpeakers: [String] { dialogue?.speakers ?? context.heuristicSpeakers }

    /// Characters cast or met earlier that this chapter does not include. Only ones already
    /// reached: analysing ahead must not put next chapter's characters on this screen.
    private var castElsewhere: [String] {
        let here = Set(chapterSpeakers)
        let met = service.characters(forBook: bookID, through: context.chapterIndex).map(\.name)
        let names = Set(explicitCast.keys).union(met).subtracting(here)
        return names.sorted { lhs, rhs in
            let left = roster.character(named: lhs)?.lineCount ?? 0
            let right = roster.character(named: rhs)?.lineCount ?? 0
            return left == right ? lhs < rhs : left > right
        }
    }

    var body: some View {
        Form {
            enableSection
            if supportsMultiRole, gs.ttsMultiRoleEnabled, allowsAI {
                aiSection
            }
            // Outside the multi-role gate on purpose: character cards are worth having
            // before a second voice exists — they are a reading aid in their own right, and
            // the aliases have to be there the moment the reader does import one.
            if allowsAI {
                aliasSection
            }
            if supportsMultiRole {
                detectedSection
                if !castElsewhere.isEmpty { elsewhereSection }
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("多角色朗讀"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            aiConfigured = AIAssistantService.shared.isConfigured
            cards.loadIfNeeded(forBook: bookID)
            fingerprintOnAppear = currentFingerprint
        }
        .onDisappear {
            // Applied when the reader leaves this screen, not on every tap: each change
            // restarts the sentence being read.
            if let before = fingerprintOnAppear, before != currentFingerprint { onCastChanged() }
        }
        .task {
            await service.loadRoster(forBook: bookID)
            if family == .azure { AzureTTSVoiceCatalog.shared.loadIfNeeded() }
        }
        .sheet(isPresented: $showAISettings, onDismiss: {
            aiConfigured = AIAssistantService.shared.isConfigured
        }) {
            AISettingsView()
        }
        .alert(
            localized("AI 分析失敗"),
            isPresented: Binding(get: { analysisError != nil }, set: { if !$0 { analysisError = nil } })
        ) {
            Button(localized("好"), role: .cancel) { analysisError = nil }
        } message: {
            Text(analysisError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(localized("重設")) {
                    showResetConfirmation = true
                }
                .disabled(!hasAnythingToReset)
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
        }
    }

    private var currentFingerprint: CastFingerprint {
        CastFingerprint(
            multiRole: gs.ttsMultiRoleEnabled,
            ai: gs.ttsAIDialogueEnabled,
            auto: gs.ttsAutoCastEnabled,
            emotion: gs.ttsEmotionEnabled,
            cast: explicitCast,
            revision: service.revisions[bookID] ?? 0
        )
    }

    private var hasAnythingToReset: Bool {
        !explicitCast.isEmpty || !roster.characters.isEmpty || !cards.profiles(forBook: bookID).isEmpty
    }

    private func resetBook() {
        gs.ttsRoleVoices = TTSRoleVoiceCast.clearing(bookID: bookID, in: gs.ttsRoleVoices)
        for profile in cards.profiles(forBook: bookID) {
            cards.remove(name: profile.name, forBook: bookID)
        }
        Task { await service.clear(book: bookID) }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(localized("多角色朗讀"), isOn: $gs.ttsMultiRoleEnabled)
                .disabled(!supportsMultiRole)
        } footer: {
            if let text = enableFooterText {
                Text(text).dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    /// Re-read from the live source list rather than the default argument, so importing a
    /// second voice enables the toggle without leaving this screen.
    private var supportsMultiRole: Bool {
        family.supportsMultiRole(importedSourceCount: gs.importedTTSSources.count)
    }

    private var enableFooterText: String? {
        switch family {
        case .bookSource where !supportsMultiRole:
            // One source is one voice: a missing import, not an unsupported engine.
            return localized("匯入的語音源一個就是一個聲音，目前只匯入了一個。到語音朗讀設定再匯入幾個（語音包通常一個音色一筆），就能指派給不同角色。")
        case .edge, .system:
            return localized("這個語音源的語氣只能用語速和音高模擬；Azure、OpenAI 或小米 MiMo 語音能真正演出情緒。")
        default:
            return nil
        }
    }

    /// The AI part: who speaks, how, and the automatic voices.
    @ViewBuilder
    private var aiSection: some View {
        Section {
            if !aiConfigured {
                Button {
                    showAISettings = true
                } label: {
                    LabeledContent(localized("設定 AI 助手")) {
                        Text(localized("未設定")).foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            Toggle(localized("AI 判斷說話人與語氣"), isOn: $gs.ttsAIDialogueEnabled)
            if gs.ttsAIDialogueEnabled, aiConfigured {
                chapterAnalysisRow
                preAnalysisRow
            }
            Toggle(localized("依性別年齡自動配音"), isOn: $gs.ttsAutoCastEnabled)
            Toggle(localized("朗讀語氣"), isOn: $gs.ttsEmotionEnabled)
        } header: {
            Text(localized("AI 配音"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("每章開始朗讀前會先請 AI 分析一次（下一章會在播放時預先分析），費用由你的 AI 服務計算。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private var chapterAnalysisRow: some View {
        if let request = context.request {
            let analysing = chapterState == .analyzing
            Button {
                analyse(request, force: dialogue != nil)
            } label: {
                LabeledContent(localized(dialogue == nil ? "分析本章" : "重新分析本章")) {
                    if analysing {
                        ProgressView()
                    } else {
                        Text(chapterStatusText)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            .disabled(analysing)
            .accessibilityValue(analysing ? localized("分析中…") : chapterStatusText)
        }
    }

    private var chapterStatusText: String {
        if let dialogue {
            return String(
                format: localized("%1$d 句對白、%2$d 位角色"),
                dialogue.attributedLineCount,
                dialogue.speakers.count
            )
        }
        if case .failed = chapterState { return localized("分析失敗") }
        return localized("尚未分析")
    }

    @ViewBuilder
    private var preAnalysisRow: some View {
        if let batch = service.batchProgress[bookID] {
            HStack(spacing: DSSpacing.sm) {
                ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1)))
                    .accessibilityLabel(localized("預先分析"))
                    .accessibilityValue(String(format: localized("%1$d / %2$d 章"), batch.done, batch.total))
                Text(String(format: localized("%1$d / %2$d 章"), batch.done, batch.total))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
                Button(localized("停止")) { service.cancelBatch(bookID: bookID) }
                    .buttonStyle(.borderless)
            }
        } else {
            Menu {
                Button(localized("接下來 5 章")) { onPreAnalyze(5) }
                Button(localized("接下來 20 章")) { onPreAnalyze(20) }
            } label: {
                LabeledContent(localized("預先分析")) {
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func analyse(_ request: AIDialogueCastService.Request, force: Bool) {
        let aliases = context.knownAliases
        Task {
            do {
                try await service.analyze(request, knownAliases: aliases, force: force)
            } catch is CancellationError {
            } catch {
                analysisError = error.localizedDescription
            }
        }
    }

    /// Character cards: the names a reader confirmed are one person.
    @ViewBuilder
    private var aliasSection: some View {
        let safeProfiles = cards.profiles(forBook: bookID).filter { $0.isSafe(at: adapter.boundary()) }
        let aliasCount = AICharacterAliasTable.aliasMap(for: safeProfiles).count
        let cardCount = safeProfiles.count
        Section {
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
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("人物卡裡的別稱會告訴 AI 哪些稱呼是同一個人（張若塵／若塵／塵哥），讓他們共用一個聲音。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var detectedSection: some View {
        Section {
            if chapterSpeakers.isEmpty {
                Text(localized("這一章沒有偵測到對話。"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                ForEach(chapterSpeakers, id: \.self) { speaker in
                    speakerRow(speaker)
                }
            }
        } header: {
            Text(localized("本章角色"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if dialogue == nil {
                Text(localized("這一章還沒經過 AI 分析：角色是從「某某說道」這類敘述讀出來的，判斷不出來的對白會用旁白的聲音。"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private var elsewhereSection: some View {
        Section {
            ForEach(castElsewhere, id: \.self) { speaker in
                speakerRow(speaker)
            }
        } header: {
            Text(localized("本書其他角色"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    // MARK: - Rows

    private func speakerRow(_ speaker: String) -> some View {
        let character = roster.character(named: speaker)
        let chosen = explicitCast[speaker]
        let automatic = chosen == nil ? autoCast[speaker] : nil
        let voiceText = TTSRoleVoiceNames.label(chosen: chosen, automatic: automatic, family: family)
        let traits = character.map(TTSRoleVoiceNames.traits(of:))
        return NavigationLink {
            TTSRoleVoicePickerView(bookID: bookID, speaker: speaker, character: character, automatic: autoCast[speaker])
        } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(speaker)
                        .foregroundStyle(DSColor.textPrimary)
                    if let traits, !traits.isEmpty {
                        Text(traits)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                Text(voiceText)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        // One focus stop per character, reading the name, who they are and the voice together.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([speaker, traits ?? "", voiceText].filter { !$0.isEmpty }.joined(separator: "，"))
        .accessibilityHint(localized("選擇這個角色的聲音"))
    }
}

/// What the cast screen compares on leaving to decide whether the listener needs to hear the
/// change now.
private struct CastFingerprint: Equatable {
    let multiRole: Bool
    let ai: Bool
    let auto: Bool
    let emotion: Bool
    let cast: [String: String]
    let revision: Int
}

/// Names for voices and characters on the cast screens.
@MainActor
enum TTSRoleVoiceNames {
    static func displayName(for voice: TTSRoleVoice) -> String? {
        switch voice {
        case let .system(identifier):
            return AVSpeechSynthesisVoice(identifier: identifier)?.name
        case .edge:
            return voice.edgeVoice?.displayName
        case .bookSource:
            return voice.importedSource()?.name
        case let .azure(storage):
            let ref = AzureTTSVoiceRef(storage: storage)
            let name = AzureTTSVoiceCatalog.shared.voice(named: ref.shortName)?.localName ?? ref.shortName
            guard let role = ref.role else { return name }
            return String(format: localized("%1$@・扮演%2$@"), name, localized(AzureTTSRole.displayNameKey(role)))
        case let .openAI(id):
            return OpenAITTSVoices.all.first { $0.id == id }?.displayName ?? id
        case let .mimo(id):
            return MiMoTTSVoices.all.first { $0.id == id }?.displayName ?? id
        }
    }

    /// What a row says about a character's voice — including a voice the running engine
    /// cannot speak, which is why the cast stores which catalogue a voice came from.
    static func label(chosen: String?, automatic: String?, family: TTSVoiceFamily) -> String {
        if chosen == TTSRoleVoiceCast.narratorChoice { return localized("旁白") }
        if let stored = chosen ?? automatic, let voice = TTSRoleVoice(storageValue: stored) {
            guard voice.family == family else { return localized("目前的語音來源不支援") }
            let name = displayName(for: voice) ?? localized("語音已移除")
            return chosen == nil ? String(format: localized("自動・%@"), name) : name
        }
        return localized("旁白")
    }

    /// 「男・青年・42 句」.
    static func traits(of character: TTSDialogueCharacter) -> String {
        var parts: [String] = []
        switch character.gender {
        case .male: parts.append(localized("男"))
        case .female: parts.append(localized("女"))
        case .unknown: break
        }
        switch character.age {
        case .child: parts.append(localized("孩童"))
        case .young: parts.append(localized("青年"))
        case .adult: parts.append(localized("成年"))
        case .elder: parts.append(localized("年長"))
        case .unknown: break
        }
        if character.lineCount > 0 {
            parts.append(String(format: localized("%d 句"), character.lineCount))
        }
        return parts.joined(separator: "・")
    }
}

/// Picks one voice for one character, from whichever catalogue the running engine uses.
struct TTSRoleVoicePickerView: View {
    let bookID: UUID
    let speaker: String
    let character: TTSDialogueCharacter?
    /// The automatic pick, shown on the 自動 row.
    let automatic: String?

    @Bindable private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var family: TTSVoiceFamily { .active() }
    private var stored: String? { TTSRoleVoiceCast.cast(forBook: bookID, in: gs.ttsRoleVoices)[speaker] }
    private var current: TTSRoleVoice? { stored.flatMap(TTSRoleVoice.init(storageValue:)) }

    var body: some View {
        Form {
            Section {
                if gs.ttsAutoCastEnabled {
                    row(
                        title: localized("自動"),
                        detail: automatic.flatMap(TTSRoleVoice.init(storageValue:)).flatMap(TTSRoleVoiceNames.displayName(for:)),
                        isSelected: stored == nil
                    ) { assign(nil) }
                }
                row(
                    title: localized("旁白"),
                    isSelected: gs.ttsAutoCastEnabled ? stored == TTSRoleVoiceCast.narratorChoice : stored == nil
                ) {
                    assign(gs.ttsAutoCastEnabled ? TTSRoleVoiceCast.narratorChoice : nil)
                }
            } footer: {
                if let character {
                    Text(TTSRoleVoiceNames.traits(of: character)).dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            switch family {
            case .system: systemVoiceSections
            case .edge: edgeVoiceSection
            case .bookSource: importedSourceSection
            case .azure: azureVoiceSection
            case .openAI: cloudVoiceSection(OpenAITTSVoices.all) { .openAI(voice: $0) }
            case .mimo: cloudVoiceSection(MiMoTTSVoices.all) { .mimo(voice: $0) }
            }
        }
        .softScrollEdges()
        .navigationTitle(speaker)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            if family == .azure { AzureTTSVoiceCatalog.shared.loadIfNeeded() }
        }
    }

    /// Each imported voice source is one voice.
    private var importedSourceSection: some View {
        Section {
            ForEach(gs.importedTTSSources) { source in
                row(
                    title: source.name,
                    isSelected: current == .bookSource(sourceID: source.id)
                ) {
                    assign(TTSRoleVoice.bookSource(sourceID: source.id).storageValue)
                }
            }
        } header: {
            Text(localized("匯入的語音源"))
                .foregroundStyle(DSColor.textSecondary)
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
                        assign(TTSRoleVoice.system(identifier: voice.identifier).storageValue)
                    }
                }
            } header: {
                Text(group.displayName)
                    .foregroundStyle(DSColor.textSecondary)
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
                    assign(TTSRoleVoice.edge(voiceID: voice.id).storageValue)
                }
            }
        } header: {
            Text(localized("微軟線上語音"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    /// Azure voices in the narrator's language, each followed by the roles it can act.
    @ViewBuilder
    private var azureVoiceSection: some View {
        let narrator = AzureTTSVoiceRef(storage: CloudTTSService.voiceID(inSourceIdentifier: gs.httpTtsUrlTemplate))
        let group = TTSLanguageGroup.of(locale: narrator.locale)
        let voices = AzureTTSVoiceCatalog.shared.voices.filter { $0.languageGroup == group }
        Section {
            if voices.isEmpty {
                Text(localized("還沒有 Azure 聲音清單"))
                    .foregroundStyle(DSColor.textSecondary)
            }
            ForEach(voices) { voice in
                azureRow(AzureTTSVoiceRef(shortName: voice.shortName), title: voice.localName)
                ForEach(voice.roles, id: \.self) { role in
                    azureRow(
                        AzureTTSVoiceRef(shortName: voice.shortName, role: role),
                        title: String(format: localized("%1$@・扮演%2$@"), voice.localName, localized(AzureTTSRole.displayNameKey(role)))
                    )
                }
            }
        } header: {
            Text(localized("Azure 語音"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if voices.isEmpty {
                Text(localized("到語音源的 Azure 語音頁面取得聲音清單。"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private func azureRow(_ ref: AzureTTSVoiceRef, title: String) -> some View {
        let value = TTSRoleVoice.azure(voice: ref.storage).storageValue
        return row(title: title, isSelected: stored == value) { assign(value) }
    }

    private func cloudVoiceSection(
        _ options: [CloudTTSVoiceOption],
        make: @escaping (String) -> TTSRoleVoice
    ) -> some View {
        Section {
            ForEach(options) { option in
                let value = make(option.id).storageValue
                row(title: option.displayName, isSelected: stored == value) { assign(value) }
            }
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
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
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

    private func assign(_ value: String?) {
        gs.ttsRoleVoices = TTSRoleVoiceCast.setting(
            voiceIdentifier: value,
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
            context: TTSRoleCastContext(
                chapterIndex: 3,
                request: nil,
                heuristicSpeakers: ["張若塵", "池瑤", "齊源老道"],
                knownAliases: [:]
            ),
            adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
            progress: 0.42,
            onPreAnalyze: { _ in },
            onCastChanged: {}
        )
    }
}

#Preview("沒有偵測到對話") {
    NavigationStack {
        TTSRoleCastView(
            bookID: UUID(),
            context: .empty,
            adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
            progress: 0.42,
            onPreAnalyze: { _ in },
            onCastChanged: {}
        )
    }
}
