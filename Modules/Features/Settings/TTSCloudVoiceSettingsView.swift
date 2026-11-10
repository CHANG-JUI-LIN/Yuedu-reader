import SwiftUI

/// One cloud voice service — Azure, OpenAI or 小米 MiMo — with the reader's own key: where it
/// is, which voice narrates, and a test.
struct TTSCloudVoiceSettingsView: View {
    let service: CloudTTSService

    @Bindable private var gs = GlobalSettings.shared
    @StateObject private var testCoordinator = TTSCoordinator()
    @State private var keyDraft = ""
    /// Read on appear: the Keychain is not something `body` should touch.
    @State private var hasKey = false
    @State private var message: String?

    private var catalog: AzureTTSVoiceCatalog { .shared }
    private var isActive: Bool { gs.activeCloudTTSService == service }
    private var selectedVoice: String { gs.cloudTTSVoice(for: service) }

    var body: some View {
        Form {
            accountSection
            voiceSection
            testSection
        }
        .softScrollEdges()
        .navigationTitle(localized(service.displayNameKey))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            hasKey = CloudTTSCredentials.hasKey(service)
            if service == .azure { catalog.loadIfNeeded() }
        }
        .onDisappear { testCoordinator.stop() }
        .alert(
            localized(service.displayNameKey),
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button(localized("好"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            SecureField(hasKey ? localized("已儲存，輸入新的金鑰可取代") : localized("API Key"), text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            switch service {
            case .azure:
                LabeledContent(localized("區域")) {
                    TextField("eastasia", text: $gs.azureTtsRegion)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .openAI:
                LabeledContent("Base URL") {
                    TextField(OpenAICompatibleTTSConfiguration.defaultOpenAIBaseURL, text: $gs.openAITtsBaseURL)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent(localized("模型")) {
                    TextField(OpenAICompatibleTTSConfiguration.defaultOpenAIModel, text: $gs.openAITtsModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .mimo:
                LabeledContent("Base URL") {
                    TextField(OpenAICompatibleTTSConfiguration.defaultMiMoBaseURL, text: $gs.mimoTtsBaseURL)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Button(localized("儲存金鑰")) { saveKey() }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasKey {
                Button(localized("移除金鑰"), role: .destructive) {
                    CloudTTSCredentials.clear(service)
                    hasKey = false
                }
            }
        } header: {
            Text(localized("帳號"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("金鑰只存在這台裝置，語音費用由你的帳號計算。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func saveKey() {
        guard CloudTTSCredentials.save(keyDraft, for: service) else {
            message = localized("無法儲存金鑰，原設定未變更。")
            return
        }
        keyDraft = ""
        hasKey = true
        if service == .azure {
            Task { await refreshAzureVoices() }
        }
    }

    // MARK: - Voices

    @ViewBuilder
    private var voiceSection: some View {
        switch service {
        case .azure: azureSections
        case .openAI: optionSection(OpenAITTSVoices.all)
        case .mimo: optionSection(MiMoTTSVoices.all)
        }
    }

    private func optionSection(_ options: [CloudTTSVoiceOption]) -> some View {
        Section {
            ForEach(options) { option in
                voiceRow(id: option.id, title: option.displayName)
            }
        } header: {
            Text(localized("朗讀聲音"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    @ViewBuilder
    private var azureSections: some View {
        Section {
            Button {
                Task { await refreshAzureVoices() }
            } label: {
                LabeledContent(localized(catalog.voices.isEmpty ? "取得聲音清單" : "重新取得聲音清單")) {
                    if catalog.isRefreshing {
                        ProgressView()
                    } else {
                        Text(String(format: localized("%d 個聲音"), catalog.voices.count))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            .disabled(!hasKey || catalog.isRefreshing)
        } footer: {
            if let error = catalog.lastError {
                Text(error).dsSectionFooter(color: DSColor.destructive)
            }
        }
        .interfaceSectionSurface()

        ForEach(azureLocales, id: \.self) { locale in
            Section {
                ForEach(catalog.voices.filter { $0.locale == locale }) { voice in
                    voiceRow(
                        id: voice.shortName,
                        title: voice.localName,
                        detail: azureDetail(voice)
                    )
                }
            } header: {
                Text(SystemTTSVoiceCatalog.displayName(forLanguage: locale))
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()
        }
    }

    /// Chinese first: it is what this app reads most.
    private var azureLocales: [String] {
        let locales = Array(Set(catalog.voices.map(\.locale)))
        return locales.sorted { lhs, rhs in
            let left = lhs.hasPrefix("zh") ? 0 : 1
            let right = rhs.hasPrefix("zh") ? 0 : 1
            return left == right ? lhs < rhs : left < right
        }
    }

    private func azureDetail(_ voice: AzureTTSVoice) -> String? {
        var parts: [String] = []
        if !voice.styles.isEmpty { parts.append(String(format: localized("%d 種語氣"), voice.styles.count)) }
        if !voice.roles.isEmpty { parts.append(String(format: localized("可扮演 %d 種角色"), voice.roles.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    private func refreshAzureVoices() async {
        await catalog.refresh()
    }

    private func voiceRow(id: String, title: String, detail: String? = nil) -> some View {
        let isSelected = selectedVoice == id
        var traits: AccessibilityTraits = .isButton
        if isSelected { _ = traits.insert(.isSelected) }
        return Button {
            testCoordinator.stop(reason: "changed cloud voice")
            gs.selectCloudTTSVoice(id, service: service)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(title).foregroundStyle(DSColor.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            if isActive {
                Text(localized("使用中"))
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                Button(localized("設為朗讀語音源")) {
                    gs.selectCloudTTSVoice(selectedVoice, service: service)
                }
                .disabled(!hasKey)
            }
            Button(localized(testCoordinator.playbackState == .stopped ? "測試播放" : "停止試聽")) {
                if testCoordinator.playbackState == .stopped {
                    gs.selectCloudTTSVoice(selectedVoice, service: service)
                    testCoordinator.speak(
                        text: localized("你好，這是一段試聽文字。選一本喜歡的書，開始聆聽吧。"),
                        title: localized("測試播放")
                    )
                } else {
                    testCoordinator.stop(reason: "stopped cloud voice preview")
                }
            }
            .disabled(!hasKey)
        } footer: {
            if let error = testCoordinator.errorMessage {
                Text(error).dsSectionFooter(color: DSColor.destructive)
            }
        }
        .interfaceSectionSurface()
    }
}

#Preview("Azure") {
    NavigationStack { TTSCloudVoiceSettingsView(service: .azure) }
}

#Preview("MiMo") {
    NavigationStack { TTSCloudVoiceSettingsView(service: .mimo) }
}
