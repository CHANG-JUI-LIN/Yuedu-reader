import SwiftUI

/// Where the reader points Yuedu at their own AI service.
///
/// BYOK by design: there is no Yuedu-operated backend, the key is the user's, and it is
/// billed to them. The screen says so, because a reader who does not know that will not
/// understand why anything costs money.
struct AIServiceEditorView: View {
    let profile: AIServiceProfile?
    let onSaved: () -> Void
    @State private var profileID = UUID()
    @State private var serviceName = ""
    @State private var saveError: String?

    @State private var endpoint = AIProviderConfiguration.default.endpoint
    @State private var model = AIProviderConfiguration.default.defaultModel
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var testResult: AIConnectionTest.Outcome?
    @State private var loadFailed = false
    @State private var showClearKeyConfirmation = false
    @StateObject private var catalog = AIModelCatalog()

    var body: some View { editorContent }

    private var editorContent: some View {
            Form {
                Section { TextField(localized("服務名稱"), text: $serviceName).accessibilityIdentifier("ai.service.name") }
                serviceSection
                keySection
                testSection
                if hasStoredKey { removeSection }
            }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(localized("AI 服務"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if save() { onSaved() }
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("儲存"))
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .alert(localized("無法儲存"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button(localized("確定"), role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
            .confirmationDialog(
                localized("移除 API Key？"),
                isPresented: $showClearKeyConfirmation,
                titleVisibility: .visible
            ) {
                Button(localized("移除"), role: .destructive) { clearKey() }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("移除後 AI 功能會停用，閱讀與聽書不受影響。"))
            }
    }

    // MARK: - Sections

    private var serviceSection: some View {
        Section {
            providerRow
            LabeledContent(localized("Base URL")) {
                TextField(AIProviderConfiguration.default.endpoint, text: $endpoint)
                    .accessibilityIdentifier("ai.service.endpoint")
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            modelRow
        } header: {
            Text(localized("AI 服務"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(
                loadFailed
                    ? localized("先前的設定無法讀取，請重新填寫。")
                    : localized("相容 OpenAI /v1/chat/completions 的服務都可以。貼完整網址也行。")
            )
            .dsSectionFooter(color: loadFailed ? DSColor.destructive : DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    /// The provider menu. Picking one fills the Base URL in; the field stays editable so a
    /// self-hosted or proxied deployment of the same service still works.
    private var providerRow: some View {
        let current = AIProviderPreset.matching(baseURL: endpoint)
        return Menu {
            ForEach(AIProviderPreset.all) { preset in
                Button {
                    select(preset)
                } label: {
                    Label(localized(preset.displayName), systemImage: preset.symbol)
                }
            }
        } label: {
            LabeledContent(localized("供應商")) {
                HStack(spacing: DSSpacing.xs) {
                    Text(localized(current.displayName))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(DSFont.caption)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(DSColor.textSecondary)
            }
        }
        .accessibilityLabel(localized("供應商"))
        .accessibilityValue(localized(current.displayName))
    }

    /// The model menu, filled from the provider's own `/models`.
    ///
    /// Always leaves the typed field in place: a provider that does not expose `/models`, or a
    /// key that is not in yet, must not make the model unselectable.
    @ViewBuilder
    private var modelRow: some View {
        LabeledContent(localized("模型")) {
            HStack(spacing: DSSpacing.sm) {
                TextField(localized("模型名稱"), text: $model)
                    .accessibilityIdentifier("ai.service.model")
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if catalog.isLoading {
                    ProgressView()
                } else if !catalog.models.isEmpty {
                    Menu {
                        ForEach(catalog.models, id: \.self) { id in
                            Button(id) { model = id }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("選擇模型"))
                }
                Button {
                    refreshModels(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(localized("重新取得模型清單"))
            }
        }
        if let failure = catalog.lastFailure {
            Text(failure)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    private var keySection: some View {
        Section {
            SecureField(
                hasStoredKey ? localized("已儲存，輸入可覆蓋") : localized("貼上 API Key"),
                text: $apiKey
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(localized("API Key"))
        } header: {
            Text(localized("API Key"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("只留在本機鑰匙圈，不同步 iCloud。費用由服務商向你收取。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Text(localized("測試連線"))
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting || !canTest)

            if let testResult {
                switch testResult {
                case let .success(reply):
                    Label(
                        reply.isEmpty ? localized("連線成功") : String(format: localized("連線成功：%@"), reply),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(DSColor.textPrimary)
                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DSColor.destructive)
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                showClearKeyConfirmation = true
            } label: {
                Text(localized("移除 API Key"))
            }
        }
        .interfaceSectionSurface()
    }

    // MARK: - State

    private var canSave: Bool {
        AIProviderConfiguration(endpoint: endpoint, defaultModel: model).endpointURL != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        canSave && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Applies a preset without clobbering a model the reader already chose deliberately —
    /// only a model that belonged to the previous preset is replaced.
    private func select(_ preset: AIProviderPreset) {
        let previous = AIProviderPreset.matching(baseURL: endpoint)
        guard preset != previous else { return }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == previous.suggestedModel {
            model = preset.suggestedModel
        }
        endpoint = preset.baseURL
        catalog.clear()
        refreshModels(force: false)
    }

    private func refreshModels(force: Bool) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.load(
            baseURL: endpoint,
            apiKey: key.isEmpty ? (AIAPIKeyStore.load(providerID: profileID) ?? "") : key,
            forceRefresh: force
        )
    }

    private func load() {
        guard let profile else { return }
        profileID = profile.id
        serviceName = profile.name
        endpoint = profile.configuration.endpoint
        model = profile.configuration.defaultModel
        hasStoredKey = AIAPIKeyStore.load(providerID: profileID)?.isEmpty == false
        refreshModels(force: false)
    }

    @discardableResult
    private func save() -> Bool {
        endpoint = AIEndpoint.normalizedBase(endpoint)
        let configuration = AIProviderConfiguration(endpoint: endpoint, defaultModel: model.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = AIServiceProfile(id: profileID, name: name.isEmpty ? configuration.preset.displayName : name,
            configuration: configuration, models: Array(Set((profile?.models ?? []) + catalog.models + [configuration.defaultModel])).sorted())
        do {
            try AIProviderStore.shared.upsert(value, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch { saveError = error.localizedDescription; return false }
    }

    private func clearKey() {
        AIAPIKeyStore.clear(providerID: profileID)
        hasStoredKey = false
        apiKey = ""
        testResult = nil
    }

    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedKey.isEmpty ? (AIAPIKeyStore.load(providerID: profileID) ?? "") : trimmedKey
        isTesting = true
        testResult = nil
        Task {
            let outcome = await AIConnectionTest.run(endpoint: endpoint, apiKey: key, model: model)
            await MainActor.run {
                testResult = outcome
                isTesting = false
                // Testing a draft does not save it; Done is the commit boundary.
            }
        }
    }
}

#Preview { NavigationStack { AIServiceEditorView(profile: nil, onSaved: {}) } }

struct AISettingsView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    private let store = AIProviderStore.shared
    @ObservedObject private var prompts = AICustomPromptStore.shared
    @State private var profiles: [AIServiceProfile] = []
    @State private var activeID: UUID?
    private struct EditorRoute: Identifiable, Hashable {
        let id = UUID()
        let profile: AIServiceProfile?
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    @State private var editing: EditorRoute?
    @State private var failure: String?

    @ViewBuilder var body: some View {
        if embedded { settingsContent }
        else { NavigationStack { settingsContent } }
    }

    private var settingsContent: some View {
            List {
                Section {
                    ForEach(profiles) { profile in
                        serviceRow(profile)
                    }
                    Button { openEditor(nil) } label: {
                        Label(localized("新增 AI 服務"), systemImage: "plus")
                            .labelStyle(IconConsistentLabelStyle())
                    }
                } header: { Text(localized("AI 服務")).foregroundStyle(DSColor.textSecondary) }
                footer: { Text(localized("API Key 只保存在本機，各服務分開儲存。費用由服務商收取。")).dsSectionFooter() }
                .interfaceSectionSurface()
                Section {
                    NavigationLink { AICustomPromptListView() } label: {
                        LabeledContent {
                            if !prompts.prompts.isEmpty { Text("\(prompts.prompts.count)").foregroundStyle(DSColor.textSecondary) }
                        } label: {
                            Label(localized("自訂提示詞"), systemImage: "text.badge.plus")
                                .foregroundStyle(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                    }
                }
                .interfaceSectionSurface()
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DSColor.destructive)
                    }
                    .interfaceSectionSurface()
                }
            }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("AI 助手設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
                }
            }
            .onAppear(perform: reload)
            .navigationDestination(item: $editing) { route in
                AIServiceEditorView(profile: route.profile) {
                    // The owner clears the same binding that presented the editor.
                    editing = nil
                }
            }
    }
    /// One service: its provider's symbol, name and default model, and which one is the
    /// default. Setting the default is a swipe or long-press away instead of hidden.
    private func serviceRow(_ profile: AIServiceProfile) -> some View {
        let isDefault = profile.id == activeID
        return Button { openEditor(profile) } label: {
            HStack(spacing: DSSpacing.sm) {
                Label {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(profile.name)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(profile.configuration.defaultModel)
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } icon: {
                    Image(systemName: profile.configuration.preset.symbol)
                }
                .foregroundStyle(DSColor.textPrimary)
                .labelStyle(IconConsistentLabelStyle())
                Spacer(minLength: DSSpacing.sm)
                if isDefault {
                    Text(localized("預設"))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if !isDefault {
                Button(localized("設為預設"), systemImage: "checkmark") { makeDefault(profile) }
            }
        }
        .swipeActions {
            Button(localized("刪除"), role: .destructive) {
                do { try store.remove(profile.id); reload() } catch { failure = error.localizedDescription }
            }
            if !isDefault {
                Button(localized("設為預設")) { makeDefault(profile) }
                    .tint(DSColor.swipeAction)
            }
        }
    }
    private func makeDefault(_ profile: AIServiceProfile) {
        do { try store.select(profile.id); reload() } catch { failure = error.localizedDescription }
    }
    private func openEditor(_ profile: AIServiceProfile?) {
        editing = EditorRoute(profile: profile)
    }
    private func reload() {
        do {
            profiles = try store.profiles()
            // The same fallback `AIAssistantService.freezeProvider` uses when the stored
            // default no longer exists.
            activeID = profiles.first { $0.id == store.activeID }?.id ?? profiles.first?.id
            failure = nil
        }
        catch { failure = error.localizedDescription }
    }
}

#Preview { AISettingsView() }
