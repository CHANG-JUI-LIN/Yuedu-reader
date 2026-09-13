import SwiftUI

/// Where the reader points Yuedu at their own AI service.
///
/// BYOK by design: there is no Yuedu-operated backend, the key is the user's, and it is
/// billed to them. The screen says so, because a reader who does not know that will not
/// understand why anything costs money.
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var embedding = AIEmbeddingModelStore.shared

    @State private var endpoint = AIProviderConfiguration.default.endpoint
    @State private var model = AIProviderConfiguration.default.defaultModel
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var testResult: AIConnectionTest.Outcome?
    @State private var loadFailed = false
    @State private var showClearKeyConfirmation = false
    @ObservedObject private var catalog = AIModelCatalog.shared

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                keySection
                testSection
                retrievalSection
                if hasStoredKey { removeSection }
            }
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("AI 助手設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("儲存"))
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
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
    }

    // MARK: - Sections

    private var serviceSection: some View {
        Section {
            providerRow
            LabeledContent(localized("Base URL")) {
                TextField(AIProviderConfiguration.default.endpoint, text: $endpoint)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            modelRow
        } header: {
            Text(localized("AI 服務"))
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
        } footer: {
            Text(localized("會同時送 system 與 user 兩段訊息，和實際使用一致。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// The opt-in vector tier.
    ///
    /// Keyword retrieval is the default and is not a crippled mode — exact hits on names and
    /// terms are most of what readers ask about, which is why it is weighted above vectors
    /// even when both are running. The model is an addition, not a requirement.
    private var retrievalSection: some View {
        Section {
            LabeledContent(localized("檢索方式")) {
                Text(embedding.isInstalled ? localized("關鍵詞 + 語意") : localized("關鍵詞"))
                    .foregroundStyle(DSColor.textSecondary)
            }
            if !embedding.isInstalled {
                LabeledContent(localized("模型下載位址")) {
                    TextField(localized("貼上模型網址"), text: $embedding.sourceURLString)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            switch embedding.state {
            case .absent:
                Button(localized("下載語意檢索模型（約 258 MB）")) {
                    Task { await embedding.download() }
                }
                .disabled(embedding.sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case let .downloading(fraction):
                ProgressView(value: fraction) {
                    Text(localized("下載中…"))
                }
                .accessibilityLabel(localized("下載語意檢索模型"))
                .accessibilityValue("\(Int(fraction * 100))%")
            case .verifying:
                HStack(spacing: DSSpacing.sm) {
                    ProgressView()
                    Text(localized("驗證中…"))
                }
            case .installed:
                Button(localized("驗證已安裝模型契約")) { _ = embedding.readyProvider() }
            case .ready:
                Button(role: .destructive) {
                    Task { await embedding.remove() }
                } label: {
                    Text(localized("移除語意檢索模型"))
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DSColor.destructive)
                Button(localized("重試下載")) {
                    Task { await embedding.download() }
                }
            }
        } header: {
            Text(localized("語意檢索"))
        } footer: {
            Text(localized("不下載也能用。關鍵詞檢索對人名、術語本來就更準。"))
                .dsSectionFooter()
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
            apiKey: key.isEmpty ? (AIAPIKeyStore.load() ?? "") : key,
            forceRefresh: force
        )
    }

    private func load() {
        hasStoredKey = AIAPIKeyStore.hasKey
        do {
            guard let stored = try AIProviderStore.shared.load() else { return }
            endpoint = stored.endpoint
            model = stored.defaultModel
            refreshModels(force: false)
        } catch {
            // Never fall back to the default endpoint silently: that would send the user's
            // book text to a service they did not choose.
            loadFailed = true
        }
    }

    private func save() {
        // Normalised on the way in, so a pasted completions URL becomes a base once rather
        // than being re-derived at every call site.
        endpoint = AIEndpoint.normalizedBase(endpoint)
        AIProviderStore.shared.save(
            AIProviderConfiguration(
                endpoint: endpoint,
                defaultModel: model.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            _ = AIAPIKeyStore.save(trimmedKey)
            hasStoredKey = true
            apiKey = ""
        }
    }

    private func clearKey() {
        AIAPIKeyStore.clear()
        hasStoredKey = false
        apiKey = ""
        testResult = nil
    }

    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedKey.isEmpty ? (AIAPIKeyStore.load() ?? "") : trimmedKey
        isTesting = true
        testResult = nil
        Task {
            let outcome = await AIConnectionTest.run(endpoint: endpoint, apiKey: key, model: model)
            await MainActor.run {
                testResult = outcome
                isTesting = false
                // Only a working configuration is written, so a failed edit cannot replace a
                // working one the user still depends on.
                if case .success = outcome { save() }
            }
        }
    }
}

#Preview {
    AISettingsView()
}
