import SwiftUI

struct AIAssistantPanelView: View {
    let bookID: UUID
    let bookTitle: String
    let adapter: AIBookContentAdapter
    let progress: Double
    let onOpenCitation: (LLMCitation, AIReadingBoundary) -> Void
    var launch: AIReadingLaunch? = nil
    var sourceIdentity: String? = nil
    var isSourceReady = true
    var prepareContent: AIReadingConversation.Prepare = { $0 }
    var onSourcePrepared: (AIBookContentAdapter) -> Void = { _ in }
    /// This book's highlights and notes, and the rest of the shelf's, for the assistant to read.
    var bookAnnotations: @MainActor () -> [AIReaderAnnotation] = { [] }
    var libraryAnnotations: @MainActor () -> [AIReaderAnnotation] = { [] }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var conversation = AIReadingConversation()
    @ObservedObject private var prompts = AICustomPromptStore.shared
    @State private var draft = ""
    private enum SecondaryScreen: Hashable {
        case history, characters, summary, settings, prompts, status
    }
    @State private var showMore = false
    @State private var pendingScreen: SecondaryScreen?
    @State private var navigationPath: [SecondaryScreen] = []
    @State private var selectedCitation: LLMCitation?
    @State private var profiles: [AIServiceProfile] = []
    @State private var settingsError: String?
    @State private var launchedID: UUID?
    @State private var detent: PresentationDetent = .medium
    @State private var followsLatest = true
    @FocusState private var inputFocused: Bool

    private static let bottomAnchor = "ai.chat.bottom"

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if profiles.isEmpty {
                    ContentUnavailableView {
                        UnavailableLabel(localized("尚未設定 AI 服務"), systemImage: "sparkles")
                    } description: {
                        Text(settingsError ?? localized("填入自己的 API 服務，即可開始閱讀問答。")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
                    } actions: {
                        Button(localized("前往設定")) { openScreen(.settings) }
                    }
                } else {
                    transcript
                        .floatingComposer { composerArea }
                }
            }
            .themedAppSurface(for: .settings)
            .navigationTitle(bookTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // The chooser finishes dismissing before the shared navigation path changes.
            .sheet(isPresented: $showMore, onDismiss: {
                if let pendingScreen { openScreen(pendingScreen) }
                pendingScreen = nil
            }) {
                DismissalSequencedActionChooser(title: localized("更多"), actions: [
                    .init(route: SecondaryScreen.history, title: localized("對話列表"), systemImage: "clock.arrow.circlepath"),
                    .init(route: .characters, title: localized("書中人物"), systemImage: "person.2"),
                    .init(route: .summary, title: localized("全書與分卷摘要"), systemImage: "text.book.closed"),
                    .init(route: .prompts, title: localized("自訂提示詞"), systemImage: "text.badge.plus"),
                    .init(route: .settings, title: localized("AI 助手設定"), systemImage: "gearshape"),
                    .init(route: .status, title: localized("AI 狀態與診斷"), systemImage: "info.circle")
                ], onSelect: { pendingScreen = $0 })
            }
            .navigationDestination(for: SecondaryScreen.self) { screen in
                switch screen {
                case .history:
                    AIChatHistoryView(sessions: conversation.history, currentID: conversation.session.id,
                        onSelect: { conversation.select($0); navigationPath.removeAll() },
                        onDelete: { conversation.delete($0) },
                        onNew: { startNewConversation(); navigationPath.removeAll() })
                case .settings: AISettingsView(embedded: true)
                case .characters: AIBookCharactersView(adapter: currentSource, progress: progress, onOpenCitation: { onOpenCitation($0, currentSource.boundary()) })
                case .summary: AIBookSummaryView(adapter: currentSource)
                case .prompts: AICustomPromptListView()
                case .status: AIStatusView(adapter: currentSource)
                }
            }
            .sheet(isPresented: Binding(get: { selectedCitation != nil }, set: { if !$0 { selectedCitation = nil } })) {
                if let citation = selectedCitation { citationPreview(citation) }
            }
        }
        // Reader chrome uses the book's ink color; assistant controls follow app UI colors.
        .tint(DSColor.accent)
        .presentationDetents(sizeClass == .regular ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: inputFocused) { _, focused in if focused { detent = .large } }
        .onAppear {
            if sizeClass == .regular || dynamicTypeSize.isAccessibilitySize { detent = .large }
            reloadProfiles(); configure()
        }
        .onChange(of: navigationPath) { _, path in
            if path.isEmpty { reloadProfiles() }
        }
        .onChange(of: bookID) { _, _ in configure() }
        .onChange(of: sourceIdentity) { _, _ in configure() }
        .onChange(of: adapter.contentFingerprint) { _, _ in configure() }
        .onChange(of: adapter.boundary()) { _, _ in configure() }
        .onChange(of: isSourceReady) { _, _ in configure() }
        .onChange(of: conversation.source?.contentFingerprint) { _, _ in
            if let source = conversation.source { onSourcePrepared(source) }
        }
        .onDisappear { conversation.cancel() }
    }

    private func openScreen(_ screen: SecondaryScreen) {
        // Settings and reference lists need the full readable height, including when
        // returning from a service editor that displayed the keyboard.
        detent = .large
        navigationPath.append(screen)
    }

    private var currentSource: AIBookContentAdapter { conversation.source ?? adapter }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(localized("關閉"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button { startNewConversation() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(localized("新對話"))
        }
        ToolbarItem(placement: .primaryAction) {
            if #available(iOS 18.0, *) {
                Menu {
                    Button(localized("對話列表"), systemImage: "clock.arrow.circlepath") { openScreen(.history) }
                    Section {
                        Button(localized("書中人物"), systemImage: "person.2") { openScreen(.characters) }
                        Button(localized("全書與分卷摘要"), systemImage: "text.book.closed") { openScreen(.summary) }
                        Button(localized("自訂提示詞"), systemImage: "text.badge.plus") { openScreen(.prompts) }
                    }
                    Section {
                        Button(localized("AI 助手設定"), systemImage: "gearshape") { openScreen(.settings) }
                        Button(localized("AI 狀態與診斷"), systemImage: "info.circle") { openScreen(.status) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(localized("更多"))
            } else {
                Button { showMore = true } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(localized("更多"))
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        if conversation.session.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(localized("一起讀懂這本書"), systemImage: "sparkles")
            } description: {
                Text(localized("選取原文來解釋或翻譯，也可以直接提問。")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
            }
                .accessibilityIdentifier("ai.chat.transcript")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                        ForEach(conversation.session.messages) { message in
                            messageView(message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                            .onAppear { followsLatest = true }
                            .onDisappear { followsLatest = false }
                    }
                    .padding(DSSpacing.lg)
                }
                .softScrollEdges()
                .opensAtLatestMessage()
                .accessibilityIdentifier("ai.chat.transcript")
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest { jumpToLatestButton(proxy) }
                }
                .onChange(of: conversation.session.messages.count) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                .onChange(of: conversation.session.messages.last?.text) { _, _ in
                    if followsLatest { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
                .onChange(of: conversation.isBusy) { _, busy in
                    if !busy && followsLatest { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
        }
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .floatingSurfaceBackground(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("捲到最新"))
        .padding(DSSpacing.md)
        .transition(.opacity)
    }

    @ViewBuilder private func messageView(_ message: AIChatMessage) -> some View {
        if message.role == .user {
            AIChatUserBubble(text: message.text, quote: message.selection?.displayText)
        } else {
            AIChatAssistantMessage(
                message: message,
                isHiddenByScope: isOutsideCurrentScope(message),
                stageLabel: conversation.stage.label,
                onRetry: message.errorMessage != nil && message.id == conversation.session.messages.last?.id && !conversation.isBusy
                    ? { conversation.retry(prepare: prepareContent) } : nil,
                onOpenCitation: { _, citation in selectedCitation = citation }
            )
        }
    }

    private func isOutsideCurrentScope(_ message: AIChatMessage) -> Bool {
        guard let metadata = message.provenance, let boundary = conversation.boundary else { return false }
        return !boundary.contains(metadata.boundary)
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: DSSpacing.xs) {
            if draft.isEmpty && !suggestions.isEmpty {
                AIChatSuggestionBar(items: suggestions)
                    .disabled(conversation.isBusy || !isSourceReady)
            }
            AIChatComposer(
                draft: $draft,
                inputFocused: $inputFocused,
                selectionText: conversation.selection?.displayText,
                onClearSelection: { conversation.selection = nil },
                wholeBook: conversation.wholeBook,
                onSetWholeBook: { conversation.setWholeBook($0) },
                profiles: profiles,
                modelChoice: modelChoice,
                modelTitle: modelChoice?.model ?? conversation.session.model ?? localized("選擇模型"),
                onSelectModel: selectModel,
                isBusy: conversation.isBusy,
                isSourceReady: isSourceReady,
                onSubmit: submit,
                onStop: { conversation.cancel() }
            )
            .padding(.horizontal, DSSpacing.md)
        }
        .padding(.bottom, DSSpacing.sm)
    }

    private var suggestions: [AIChatSuggestionBar.Item] {
        let actions: [AIReadingAction] = conversation.selection == nil ? [.chapterSummary, .recap] : [.explain, .translate]
        var builtIn = actions.map { action in
            AIChatSuggestionBar.Item(id: "action.\(action)", title: action.title) { sendAction(action) }
        }
        // Not a chat turn: the book summary is its own page, built once and kept.
        if conversation.selection == nil {
            builtIn.append(AIChatSuggestionBar.Item(id: "screen.summary", title: localized("全書摘要")) { openScreen(.summary) })
            if !bookAnnotations().isEmpty {
                builtIn.append(AIChatSuggestionBar.Item(id: "action.annotationReview", title: AIReadingAction.annotationReview.title) {
                    sendAction(.annotationReview)
                })
            }
        }
        let custom = prompts.prompts
            .filter { $0.isEnabled && ($0.context != .selection || conversation.selection != nil) }
            .map { prompt in
                AIChatSuggestionBar.Item(id: "prompt.\(prompt.id)", title: prompt.title) {
                    conversation.send(prompt.title, action: .custom, custom: prompt, prepare: prepareContent)
                }
            }
        return builtIn + custom
    }

    /// The service and model the next question goes to, resolved the way
    /// `AIAssistantService.freezeProvider` resolves it.
    private var modelChoice: AIChatModelChoice? {
        let serviceID = conversation.session.serviceID ?? AIProviderStore.shared.activeID
        guard let profile = profiles.first(where: { $0.id == serviceID })
                ?? (conversation.session.serviceID == nil ? profiles.first : nil) else { return nil }
        return AIChatModelChoice(serviceID: profile.id,
                                 model: conversation.session.model ?? profile.configuration.defaultModel)
    }

    private func selectModel(_ choice: AIChatModelChoice) {
        guard let profile = profiles.first(where: { $0.id == choice.serviceID }) else { return }
        conversation.setModel(profile: profile, model: choice.model)
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        conversation.send(question, prepare: prepareContent)
        draft = ""
        if dynamicTypeSize.isAccessibilitySize { inputFocused = false }
    }

    private func startNewConversation() {
        conversation.startNew()
        draft = ""
    }

    private func citationPreview(_ citation: LLMCitation) -> some View {
        NavigationStack {
            List {
                Section { Text(citation.quote).textSelection(.enabled).foregroundStyle(DSColor.textPrimary) } header: { Text(citation.sectionTitle ?? localized("原文")).foregroundStyle(DSColor.textSecondary) }
            }
            .softScrollEdges()
            .navigationTitle(localized("原文引用"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(localized("跳到原文"), systemImage: "arrow.turn.down.right") {
                        selectedCitation = nil
                        onOpenCitation(citation, currentSource.boundary(wholeBook: conversation.wholeBook))
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { selectedCitation = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(localized("關閉"))
                }
            }
        }
    }

    private func reloadProfiles() {
        do { profiles = try AIProviderStore.shared.profiles(); settingsError = nil }
        catch { settingsError = error.localizedDescription }
    }
    private func configure() {
        conversation.bookAnnotations = bookAnnotations
        conversation.libraryAnnotations = libraryAnnotations
        guard isSourceReady else { conversation.cancel(); return }
        conversation.open(source: adapter, sourceIdentity: sourceIdentity)
        guard let launch, launchedID != launch.id else { return }
        launchedID = launch.id
        conversation.selection = launch.selection
        if launch.action != .question { sendAction(launch.action) }
    }
    private func sendAction(_ action: AIReadingAction) { conversation.send(action.title, action: action, prepare: prepareContent) }
}

struct AIChatHistoryView: View {
    let sessions: [AIChatSession]
    let currentID: UUID
    let onSelect: (AIChatSession) -> Void
    let onDelete: (UUID) -> Void
    let onNew: () -> Void
    var body: some View {
        List {
            Button(localized("新對話"), systemImage: "square.and.pencil", action: onNew)
            ForEach(sessions) { session in
                Button { onSelect(session) } label: {
                    LabeledContent(session.title) {
                        if session.id == currentID { Image(systemName: "checkmark").accessibilityLabel(localized("已選取")) }
                    }
                }
                .swipeActions { Button(localized("刪除"), role: .destructive) { onDelete(session.id) } }
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("對話列表"))
        .toolbarTitleDisplayMode(.inline)
    }
}

private extension View {
    /// The transcript scrolls under the floating composer. On iOS 26 the composer is a
    /// safe-area bar, so the system's soft scroll-edge effect sits under it and prose does
    /// not run sharply through the gaps between the glass controls. Earlier systems have
    /// no edge effect; the composer is a plain inset there.
    @ViewBuilder func floatingComposer<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
        #else
        safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        #endif
    }

    /// A reopened conversation starts at its latest turn. Only the initial offset: while an
    /// answer streams, following it is `followsLatest`'s decision, so a reader who scrolled
    /// back up is not pulled down by growing text.
    @ViewBuilder func opensAtLatestMessage() -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }
}

#Preview {
    AIAssistantPanelView(bookID: UUID(), bookTitle: "閱讀中的書", adapter: .init(bookID: UUID(), chapters: [], textForChapter: { _ in nil }), progress: 0.4, onOpenCitation: { _, _ in })
}
