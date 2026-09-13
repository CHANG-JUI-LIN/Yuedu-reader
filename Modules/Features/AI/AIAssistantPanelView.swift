import SwiftUI

/// Ask the assistant about the book you are reading.
///
/// A plain chat: the reader asks, the assistant answers from passages it retrieved, and the
/// thread is the record. 前情提要 was a tab of its own until it became obvious it is just one
/// of the questions — it lives in the suggestion row now.
///
/// 人物卡 is not here either. Its output is the alias table 多角色朗讀 casts voices against, so
/// it sits with 聽書 where it is used.
struct AIAssistantPanelView: View {
    let bookID: UUID
    let bookTitle: String
    let adapter: AIBookContentAdapter
    /// How far the reader has got, on the same 0…1 scale the chunks use.
    let progress: Double
    let onOpenCitation: (LLMCitation) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var session = AIChatSession()
    @State private var history: [AIChatSession] = []
    @State private var draft = ""
    @State private var isConfigured = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showStatus = false
    @GestureState(resetTransaction: Transaction(animation: DSAnimation.standard))
    private var drag = DrawerDrag()
    @State private var task: Task<Void, Never>?
    @State private var requestOwner: AIChatRequestOwner?
    @State private var questionStage: AIQuestionStage = .searching
    @FocusState private var inputFocused: Bool

    private var messages: [AIChatMessage] { session.messages }
    private var isBusy: Bool { messages.last?.isPending == true }
    /// The ceiling retrieval is allowed to reach.
    private var effectiveProgress: Double { gs.aiSpoilerSafe ? progress : 1.0 }

    private var currentBoundary: AIReadingBoundary { adapter.boundary(wholeBook: !gs.aiSpoilerSafe) }

    var body: some View {
        // The conversation list is the layer underneath; the chat sits on top of it and
        // slides aside to reveal it. Putting the list on top as a drawer was the wrong way
        // round — the chat is the thing you are in, not the thing being covered.
        ZStack(alignment: .leading) {
            AIChatHistoryView(
                sessions: history,
                currentID: session.id,
                onSelect: { open($0) },
                onDelete: { delete($0) },
                onNew: { startNewConversation() }
            )
            .frame(width: Self.drawerWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            foreground
                .offset(x: drawerOffset)
                .gesture(historyDrag)
        }
        .background(DSColor.groupedBackground.ignoresSafeArea())
    }

    /// The axis is decided once, on the first movement of each drag, and held for the rest
    /// of it — otherwise a scroll that wanders sideways starts dragging the chat open
    /// halfway down the gesture.
    struct DrawerDrag: Equatable {
        var width: CGFloat = 0
        var isHorizontal: Bool?
    }

    /// Dragging right opens the list, dragging left closes it — both directions, from
    /// anywhere on the chat, tracking the finger the whole way.
    private var historyDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                if state.isHorizontal == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard dx > 0 || dy > 0 else { return }
                    state.isHorizontal = dx > dy
                }
                guard state.isHorizontal == true else { return }
                state.width = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Flick or travel: a fast swipe commits on its own, a slow one has to cross
                // half the drawer.
                // `predictedEndTranslation` already contains the travel so far, plus the
                // momentum projection — it is where the finger was heading, not an extra.
                let travelled = value.predictedEndTranslation.width
                let opened = showHistory
                    ? travelled > -Self.drawerWidth / 2
                    : travelled > Self.drawerWidth / 2
                withAnimation(DSAnimation.standard) { showHistory = opened }
            }
    }

    /// Where the chat actually sits: its resting place plus however far the finger has
    /// carried it, never past either edge.
    private var drawerOffset: CGFloat {
        let resting = showHistory ? Self.drawerWidth : 0
        return min(max(resting + drag.width, 0), Self.drawerWidth)
    }

    private var drawerProgress: Double { Double(drawerOffset / Self.drawerWidth) }

    private var foreground: some View {
        NavigationStack {
            Group {
                if isConfigured {
                    chat
                } else {
                    notConfigured
                }
            }
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("AI 助手"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showStatus) { NavigationStack { AIStatusView(adapter: adapter) } }
            .onChange(of: adapter.contentFingerprint) { _, _ in
                cancel()
                AIAssistantService.shared.activate(adapter)
            }
            .onChange(of: currentBoundary) { _, boundary in
                if let owner = requestOwner, !boundary.contains(owner.boundary) { cancel() }
            }
            .onChange(of: bookID) { _, _ in cancel(); start() }
            .onAppear(perform: start)
            .onDisappear {
                cancel()
                persist()
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                isConfigured = AIAssistantService.shared.isConfigured
            }) {
                AISettingsView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xxl * drawerProgress))
        .shadow(color: .black.opacity(0.18 * drawerProgress), radius: 16, x: -4)
        // Tapping the chat while the list is showing brings it back, the way it does in a
        // chat app — without this the only way back is the toolbar button.
        .overlay {
            if showHistory {
                Color.black.opacity(0.001)
                    .onTapGesture { withAnimation(DSAnimation.standard) { showHistory = false } }
                    .accessibilityLabel(localized("回到對話"))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("關閉"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showStatus = true } label: {
                Image(systemName: "info.circle").accessibilityHidden(true)
            }.accessibilityLabel(localized("AI 狀態與診斷"))
        }
        if isConfigured {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AICharacterMemoryView(adapter: adapter, onOpenCitation: onOpenCitation)
                } label: { Image(systemName: "person.text.rectangle").accessibilityHidden(true) }
                .accessibilityLabel(localized("逐批人物建檔"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(DSAnimation.standard) { showHistory.toggle() }
                } label: {
                    Image(systemName: "list.bullet")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("對話列表"))
            }
        }
    }

    private static let drawerWidth: CGFloat = 300

    // MARK: - Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpacing.lg) {
                        if messages.isEmpty { emptyState }
                        ForEach(messages) { message in
                            bubble(message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.lg)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages) { _, _ in
                    withAnimation(DSAnimation.fast) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            inputBar
        }
    }

    private static let bottomAnchor = "ai.chat.bottom"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(String(format: localized("關於《%@》"), bookTitle))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
            Text(
                gs.aiSpoilerSafe
                    ? String(
                        format: localized("只讀你讀到 %d%% 為止的內容。搜不到東西時，把「防劇透」關掉。"),
                        Int((progress * 100).rounded())
                    )
                    : localized("會搜尋整本書，可能劇透。")
            )
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DSSpacing.sm)
    }

    @ViewBuilder
    private func bubble(_ message: AIChatMessage) -> some View {
        if message.role == .user {
            userBubble(message)
        } else {
            assistantBubble(message)
        }
    }

    private func userBubble(_ message: AIChatMessage) -> some View {
        HStack {
            Spacer(minLength: DSSpacing.xl)
            Text(message.text)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
                .background(DSColor.surfaceTertiary, in: RoundedRectangle(cornerRadius: DSRadius.lg))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func assistantBubble(_ message: AIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if let provenance = message.provenance, !currentBoundary.contains(provenance.boundary) {
                Text(localized("此回覆超出目前可確認的來源或閱讀範圍，已暫時隱藏。"))
                    .font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            } else if message.isPending, message.text.isEmpty {
                thinkingIndicator
            } else if let error = message.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.destructive)
                if message.id == messages.last?.id, message.provenance != nil {
                    Button(localized("重試這個問題")) { retry(message) }.disabled(isBusy)
                }
            } else if message.text.isEmpty {
                // An answer that came back empty is a failure, not a blank bubble with a
                // red warning under it.
                Label(localized("這次沒有回應，再試一次。"), systemImage: "exclamationmark.triangle")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.destructive)
            } else {
                answerBody(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Markdown, with line breaks kept — the default parser collapses them, which turns a
    /// numbered list into one paragraph.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }

    private var thinkingIndicator: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(questionStage.label)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    @ViewBuilder
    private func answerBody(_ message: AIChatMessage) -> some View {
        // Models answer in Markdown whether or not they were asked to — `**粗體**` and
        // numbered lists came through as literal asterisks.
        Text(Self.formatted(message.text))
            .font(DSFont.body)
            .foregroundStyle(DSColor.textPrimary)
            .textSelection(.enabled)
        if !message.hasEvidence {
            // An answer citing nothing is not sourced, whatever it asserts.
            Text(localized("這個回答沒有引用到書裡的片段，請當成參考而不是書中內容。"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.destructive)
        }
        ForEach(message.notices ?? [], id: \.self) { notice in
            Text(notice).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
        }
        ForEach(message.citations, id: \.chunkID) { citation in
            citationRow(citation)
        }
    }

    private func citationRow(_ citation: LLMCitation) -> some View {
        Button {
            onOpenCitation(citation)
        } label: {
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                Image(systemName: "quote.opening")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.sectionTitle ?? String(format: localized("第 %d 章"), citation.spineIndex + 1))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                    if citation.sourceVersion != adapter.contentFingerprint {
                        Text(localized("來源已變更，需重新整理引用"))
                            .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                    }
                    Text(Self.quoteText(citation))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, DSSpacing.xs)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            citation.sourceVersion != adapter.contentFingerprint ? localized("來源已變更，需重新整理引用") :
                (citation.sectionTitle.map { String(format: localized("跳到 %@"), $0) } ?? localized("跳到原文"))
        )
        .accessibilityHint(citation.quote)
        .disabled(citation.sourceVersion != adapter.contentFingerprint)

    }

    /// The excerpt, minus a leading copy of the chapter title — a chunk that starts a
    /// chapter contains it, so the card printed `Preface` twice.
    static func quoteText(_ citation: LLMCitation) -> String {
        var quote = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = citation.sectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           quote.hasPrefix(title) {
            quote = String(quote.dropFirst(title.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return quote
    }

    // MARK: - Input

    /// One glass container: the question on top, the chips inside it below, and the send
    /// button on the right edge of the same surface.
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                TextField(localized("問一個問題"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .frame(minHeight: Self.inputMinHeight, alignment: .leading)
                suggestionRow
            }
            sendButton
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.md)
        .floatingSurface(in: RoundedRectangle(cornerRadius: DSRadius.xxl))
        .padding(.horizontal, DSSpacing.md)
        .padding(.bottom, DSSpacing.sm)
    }

    /// One empty line of the field is still a finger-sized target.
    private static let inputMinHeight: CGFloat = 40

    private var sendButton: some View {
        Button {
            if isBusy { cancel() } else { send(draft) }
        } label: {
            Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textOnAccent)
                .frame(width: 34, height: 34)
                .background(canSend || isBusy ? DSColor.accent : DSColor.textDisabled, in: Circle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBusy ? localized("停止") : localized("送出"))
        .disabled(!isBusy && !canSend)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                spoilerToggle
                ForEach(AIChatSuggestion.all) { suggestion in
                    Button {
                        run(suggestion)
                    } label: {
                        chip(localized(suggestion.title), systemImage: suggestion.symbol, active: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(DSFont.subheadline)
            .foregroundStyle(active ? DSColor.accent : DSColor.textPrimary)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.xs)
            .overlay(
                Capsule().stroke(
                    active ? DSColor.accent.opacity(0.55) : DSColor.border,
                    lineWidth: 1
                )
            )
    }

    /// Reading-range limit, where the question is asked rather than in settings.
    private var spoilerToggle: some View {
        Button {
            gs.aiSpoilerSafe.toggle()
        } label: {
            chip(
                gs.aiSpoilerSafe
                    ? String(format: localized("讀到 %d%%"), Int((progress * 100).rounded()))
                    : localized("全書"),
                systemImage: gs.aiSpoilerSafe ? "eyeglasses" : "chevron.left.forwardslash.chevron.right",
                active: gs.aiSpoilerSafe
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("防劇透"))
        .accessibilityValue(gs.aiSpoilerSafe ? localized("開") : localized("關"))
        .accessibilityHint(localized("關掉就會搜尋整本書"))
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label(localized("尚未設定 AI 服務"), systemImage: "sparkles")
        } description: {
            Text(localized("填入你自己的 API 位址與金鑰後，就能問書、產生前情提要、整理人物卡。"))
        } actions: {
            Button(localized("前往設定")) { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Sessions

    private func start() {
        isConfigured = AIAssistantService.shared.isConfigured
        history = AIChatStore.shared.sessions(forBook: bookID)
        // A fresh thread each time the panel opens. Resuming yesterday's conversation about
        // a chapter the reader has since passed is rarely what they meant.
        session = AIChatSession()
    }

    private func startNewConversation() {
        cancel()
        persist()
        session = AIChatSession()
        withAnimation(DSAnimation.standard) { showHistory = false }
    }

    private func open(_ selected: AIChatSession) {
        cancel()
        persist()
        session = selected
        withAnimation(DSAnimation.standard) { showHistory = false }
    }

    private func delete(_ id: UUID) {
        AIChatStore.shared.delete(sessionID: id, forBook: bookID)
        history = AIChatStore.shared.sessions(forBook: bookID)
        if session.id == id { cancel(); session = AIChatSession() }
    }

    private func persist() {
        AIChatStore.shared.save(session, forBook: bookID)
        history = AIChatStore.shared.sessions(forBook: bookID)
    }

    // MARK: - Actions

    private func run(_ suggestion: AIChatSuggestion) {
        switch suggestion.kind {
        case .recap:
            askRecap()
        case let .prompt(text):
            send(text)
        }
    }

    private func retry(_ message: AIChatMessage) {
        guard let i = messages.firstIndex(where: { $0.id == message.id }), i > 0,
              messages[i - 1].role == .user else { return }
        let user = messages[i - 1]
        send(user.text, existingUserID: user.id)
    }

    private func send(_ text: String, existingUserID: UUID? = nil) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        draft = ""
        inputFocused = false
        let context = AIQuestionContext(bookID: bookID, conversationID: session.id, question: question,
            source: adapter, boundary: currentBoundary, history: messages.filter { $0.id != existingUserID })
        let owner = AIChatRequestOwner(requestID: context.requestID, conversationID: session.id, bookID: bookID, boundary: currentBoundary)
        let metadata = AIChatProvenance(requestID: context.requestID, bookID: bookID, conversationID: session.id,
            boundary: currentBoundary, status: .pending)
        guard let turn = session.prepareQuestion(question, metadata: metadata, retrying: existingUserID) else { return }
        let userID = turn.user
        let pendingID = turn.assistant
        persist()
        task?.cancel()
        requestOwner = owner
        questionStage = .searching
        task = Task {
            do {
                let result = try await AIAssistantService.shared.answer(context: context) { stage in
                    if requestOwner == owner { questionStage = stage }
                }
                guard !Task.isCancelled, owns(owner) else { return }
                if let i = session.messages.firstIndex(where: { $0.id == userID }) { session.messages[i].provenance = result.provenance }
                resolve(pendingID, text: result.content, citations: result.citations, hasEvidence: result.hasEvidence,
                    provenance: result.provenance, notices: result.notices)
                AIDiagnosticStore.shared.recordPresentation(requestID: owner.requestID, status: "displayed")
                requestOwner = nil
            } catch {
                guard !Task.isCancelled, owns(owner) else { return }
                var failed = metadata; failed.status = error is CancellationError ? .cancelled : .failed
                if let i = session.messages.firstIndex(where: { $0.id == userID }) { session.messages[i].provenance = failed }
                resolve(pendingID, error: error.localizedDescription, provenance: failed)
                AIDiagnosticStore.shared.recordPresentation(requestID: owner.requestID, status: "failed")
                requestOwner = nil
            }
        }
    }

    private func owns(_ owner: AIChatRequestOwner) -> Bool {
        owner.canPublish(requestID: requestOwner?.requestID, conversationID: session.id, bookID: bookID, boundary: currentBoundary)
    }

    /// 前情提要 does not go through retrieval: it is seeded from the most recent already-read
    /// passages, so it reads forwards instead of answering a query.
    private func askRecap() {
        guard !isBusy else { return }
        let snapshot = adapter
        let boundary = currentBoundary
        let owner = AIChatRequestOwner(requestID: UUID(), conversationID: session.id, bookID: bookID, boundary: boundary)
        requestOwner = owner
        questionStage = .answering
        append(AIChatMessage(role: .user, text: localized("最近已讀片段提要")))
        let pending = AIChatMessage(role: .assistant, text: "", isPending: true)
        append(pending)

        task?.cancel()
        task = Task {
            do {
                let stored = AIRecapStore.shared.recap(forBook: bookID)
                let recap = try await AIAssistantService.shared.recap(
                    bookID: bookID,
                    bookTitle: bookTitle,
                    adapter: snapshot,
                    progress: effectiveProgress,
                    stored: stored,
                    boundary: boundary
                )
                guard !Task.isCancelled, owns(owner) else { return }
                guard let recap else {
                    resolve(pending.id, error: localized("已讀範圍還太少，無法產生提要。"))
                    return
                }
                AIRecapStore.shared.save(recap, forBook: bookID)
                resolve(pending.id, text: recap.text, citations: [], hasEvidence: true,
                    provenance: .init(requestID: owner.requestID, bookID: bookID, conversationID: owner.conversationID, boundary: boundary, status: .completed))
                requestOwner = nil
            } catch is CancellationError {
                if owns(owner) { remove(pending.id) }
            } catch {
                guard !Task.isCancelled, owns(owner) else { return }
                resolve(pending.id, error: error.localizedDescription)
            }
        }
    }

    private func cancel() {
        task?.cancel()
        if let owner = requestOwner { AIDiagnosticStore.shared.recordPresentation(requestID: owner.requestID, status: "cancelledOrScopeChanged") }
        requestOwner = nil
        if let last = messages.last, last.isPending {
            if let i = session.messages.indices.last {
                session.messages[i].isPending = false
                session.messages[i].errorMessage = localized("已停止本次問答。")
                session.messages[i].provenance?.status = .cancelled
            }
            persist()
        }
    }

    // MARK: - Message bookkeeping

    private func append(_ message: AIChatMessage) {
        session.messages.append(message)
        persist()
    }

    private func resolve(
        _ id: UUID,
        text: String = "",
        citations: [LLMCitation] = [],
        hasEvidence: Bool = true,
        error: String? = nil,
        provenance: AIChatProvenance? = nil,
        notices: [String] = []
    ) {
        guard let index = session.messages.firstIndex(where: { $0.id == id }) else { return }
        session.messages[index].isPending = false
        session.messages[index].text = text
        session.messages[index].citations = citations
        session.messages[index].hasEvidence = hasEvidence
        session.messages[index].errorMessage = error
        session.messages[index].provenance = provenance
        session.messages[index].notices = notices
        persist()
    }

    private func remove(_ id: UUID) {
        session.messages.removeAll { $0.id == id }
        persist()
    }
}

/// The conversation list that slides over the chat.
struct AIChatHistoryView: View {
    let sessions: [AIChatSession]
    let currentID: UUID
    let onSelect: (AIChatSession) -> Void
    let onDelete: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localized("對話列表"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新對話"))
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.md)

            if sessions.isEmpty {
                Text(localized("還沒有紀錄"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .padding(.horizontal, DSSpacing.lg)
                Spacer()
            } else {
                List {
                    ForEach(sessions) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(DSFont.body)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .lineLimit(2)
                                Text(item.createdAt, style: .date)
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                        }
                        .listRowBackground(
                            item.id == currentID ? DSColor.surfaceTertiary : Color.clear
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                onDelete(item.id)
                            } label: {
                                Label(localized("刪除"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.groupedBackground)
        .ignoresSafeArea(edges: .bottom)
    }
}

#Preview {
    AIAssistantPanelView(
        bookID: UUID(),
        bookTitle: "我師兄實在太穩健了",
        adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
        progress: 0.42,
        onOpenCitation: { _ in }
    )
}
