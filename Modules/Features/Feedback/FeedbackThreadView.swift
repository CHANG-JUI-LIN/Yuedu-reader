import AVKit
import PhotosUI
import SwiftUI

/// 我的回饋 › one report: the conversation with the AI 助手 and the developer, a reply
/// composer floating at the bottom (as `AIChatComposer` does), and 標記已解決 while the
/// report is open. Opening it marks the replies read.
struct FeedbackThreadView: View {
    @State private var thread: FeedbackThread
    @State private var messages: [FeedbackMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var draft = ""
    @State private var draftAttachments: [FeedbackDraftAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var preparingCount = 0
    @State private var isSending = false
    @State private var actionError: String?
    @State private var viewer: FeedbackAttachment?
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(thread: FeedbackThread) {
        _thread = State(initialValue: thread)
    }

    private var canSend: Bool {
        !isSending && preparingCount == 0
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.lg) {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let loadError {
                        ContentUnavailableView {
                            UnavailableLabel(localized("無法載入對話"), systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(loadError).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    ForEach(messages) { message in
                        FeedbackMessageBubble(message: message, onOpen: { viewer = $0 })
                            .id(message.id)
                    }
                    if !isLoading && thread.status != .done {
                        resolvePrompt
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        // As 我的回饋 under it: the composer has the bottom to itself.
        .hidesRootTabBar()
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(thread.displayTitle)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(thread.displayTitle)
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(thread.status.badgeTitle)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            addPicked(items)
        }
        .sheet(item: $viewer) { attachment in
            FeedbackAttachmentViewer(attachment: attachment)
        }
        .alert(
            localized("傳送失敗"),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button(localized("好"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await observeMessages() }
        .task { await observeThread() }
        .onDisappear {
            draftAttachments.forEach { $0.discard() }
        }
    }

    private static let bottomID = "feedback.thread.bottom"

    private var resolvePrompt: some View {
        HStack(spacing: DSSpacing.xs) {
            Text(localized("問題已經解決了嗎？"))
                .foregroundStyle(DSColor.textSecondary)
            Button(localized("標記已解決")) { markResolved() }
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .frame(minHeight: DSLayout.minimumTapTarget)
        }
        .font(DSFont.subheadline)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if !draftAttachments.isEmpty || preparingCount > 0 {
                FeedbackDraftAttachmentStrip(
                    attachments: draftAttachments,
                    preparingCount: preparingCount,
                    onRemove: { attachment in
                        draftAttachments.removeAll { $0.id == attachment.id }
                        attachment.discard()
                    }
                )
            }
            HStack(alignment: .bottom, spacing: DSSpacing.sm) {
                // Read here, on main: the picker's label closure is `@Sendable`.
                let pickerIconFont = DSFont.title3
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(1, FeedbackFirestoreSchema.attachmentLimit - draftAttachments.count - preparingCount),
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .compatible
                ) {
                    Image(systemName: "photo.on.rectangle")
                        .font(pickerIconFont)
                        .foregroundStyle(DSColor.textPrimary)
                        .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                }
                .disabled(draftAttachments.count + preparingCount >= FeedbackFirestoreSchema.attachmentLimit)
                .accessibilityLabel(localized("新增圖片或影片"))

                TextField(localized("回覆此回饋…"), text: $draft, axis: .vertical)
                    .font(DSFont.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .accessibilityIdentifier("feedback_thread_reply")

                Button {
                    send()
                } label: {
                    Group {
                        if isSending {
                            ProgressView()
                        } else {
                            Text(localized("傳送"))
                                .font(DSFont.bodyBold)
                        }
                    }
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .background(canSend ? DSColor.accent : DSColor.neutralControlFill, in: Capsule())
                    .foregroundStyle(canSend ? AnyShapeStyle(DSColor.textOnAccent) : AnyShapeStyle(DSColor.textTertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("feedback_thread_send")
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .floatingSurfaceBackground(in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        .padding(.horizontal, DSSpacing.md)
        .padding(.bottom, DSSpacing.xs)
    }

    // MARK: - Actions

    private func observeMessages() async {
        do {
            for try await update in FeedbackService.shared.messageUpdates(threadID: thread.id) {
                messages = update
                isLoading = false
                loadError = nil
            }
        } catch is CancellationError {
        } catch {
            isLoading = false
            loadError = FeedbackService.userMessage(for: error)
        }
    }

    /// Follows the thread's own status and read state, and marks new replies read while
    /// the conversation is on screen.
    private func observeThread() async {
        do {
            for try await threads in FeedbackService.shared.threadUpdates() {
                guard let current = threads.first(where: { $0.id == thread.id }) else { continue }
                thread = current
                if current.isUnread {
                    try await FeedbackService.shared.markRead(current)
                }
            }
        } catch is CancellationError {
        } catch {
            AppLogger.network("Feedback thread observer ended", error: error)
        }
    }

    private func addPicked(_ items: [PhotosPickerItem]) {
        let room = FeedbackFirestoreSchema.attachmentLimit - draftAttachments.count - preparingCount
        let accepted = Array(items.prefix(max(0, room)))
        preparingCount += accepted.count
        for item in accepted {
            Task {
                do {
                    draftAttachments.append(try await FeedbackDraftAttachment.prepare(item))
                } catch {
                    AppLogger.error("Feedback attachment could not be prepared", error: error)
                    actionError = FeedbackService.userMessage(for: error)
                }
                preparingCount -= 1
            }
        }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        let text = draft
        let attachments = draftAttachments
        Task {
            do {
                try await FeedbackService.shared.reply(to: thread, text: text, attachments: attachments)
                draft = ""
                draftAttachments = []
                attachments.forEach { $0.discard() }
                composerFocused = false
            } catch {
                AppLogger.network("Feedback reply failed", error: error)
                actionError = FeedbackService.userMessage(for: error)
            }
            isSending = false
        }
    }

    private func markResolved() {
        Task {
            do {
                try await FeedbackService.shared.markResolved(thread)
            } catch {
                AppLogger.network("Feedback mark-resolved failed", error: error)
                actionError = FeedbackService.userMessage(for: error)
            }
        }
    }
}

/// One message. The person's own messages sit on the trailing side; the AI 助手's and the
/// developer's on the leading side under a header naming who wrote them.
struct FeedbackMessageBubble: View {
    let message: FeedbackMessage
    let onOpen: (FeedbackAttachment) -> Void

    private var isMine: Bool { message.author == .user }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: DSLayout.aiChatBubbleLeadingInset) }
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                // One VoiceOver element for who wrote it, what, and when; the
                // attachments stay separate buttons.
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    if !isMine { header }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenText)
                if !message.attachments.isEmpty {
                    attachmentGrid
                }
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
                        .accessibilityHidden(true)
                }
            }
            .padding(DSSpacing.md)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
            .overlay {
                if isMine {
                    RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                        .fill(DSColor.accentLight)
                        .allowsHitTesting(false)
                }
            }
            if !isMine { Spacer(minLength: DSLayout.aiChatBubbleLeadingInset) }
        }
    }

    private var spokenText: String {
        var parts = [authorName]
        if !message.text.isEmpty { parts.append(message.text) }
        if let createdAt = message.createdAt {
            parts.append(createdAt.formatted(.dateTime.month().day().hour().minute()))
        }
        return parts.joined(separator: localized("，"))
    }

    private var authorName: String {
        switch message.author {
        case .user: localized("我")
        case .assistant: localized("AI 助手")
        case .developer: localized("開發者")
        }
    }

    private var header: some View {
        Label {
            Text(authorName)
        } icon: {
            Image(systemName: message.author == .assistant ? "sparkles" : "person.crop.circle")
                .foregroundStyle(DSColor.accent)
        }
        .font(DSFont.subheadline.weight(.semibold))
        .foregroundStyle(DSColor.textSecondary)
    }

    private var attachmentGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: DSLayout.feedbackBubbleAttachmentSide), spacing: DSSpacing.sm)],
            alignment: .leading,
            spacing: DSSpacing.sm
        ) {
            ForEach(message.attachments, id: \.path) { attachment in
                Button {
                    onOpen(attachment)
                } label: {
                    FeedbackAttachmentThumbnail(attachment: attachment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(attachment.kind == .video ? localized("影片") : localized("圖片"))
                .accessibilityHint(localized("點兩下以檢視"))
            }
        }
    }
}

/// A sent attachment's square: the image itself, or a play symbol for a video.
struct FeedbackAttachmentThumbnail: View {
    let attachment: FeedbackAttachment
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(DSColor.surfaceTertiary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if attachment.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(DSFont.title)
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }
        }
        .frame(width: DSLayout.feedbackBubbleAttachmentSide, height: DSLayout.feedbackBubbleAttachmentSide)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .task(id: attachment.path) {
            guard attachment.kind == .image, image == nil else { return }
            do {
                image = try await FeedbackService.shared.image(for: attachment)
            } catch {
                AppLogger.network("Feedback attachment image failed to load", error: error)
                failed = true
            }
        }
    }
}

/// An attachment full screen: the image, or the video in the system player.
struct FeedbackAttachmentViewer: View {
    let attachment: FeedbackAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(localized("圖片"))
                } else if let player {
                    VideoPlayer(player: player)
                } else if let error {
                    ContentUnavailableView {
                        UnavailableLabel(localized("無法載入附件"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error).foregroundStyle(DSColor.textSecondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DSColor.background)
            .navigationTitle(attachment.kind == .video ? localized("影片") : localized("圖片"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
        .task {
            do {
                switch attachment.kind {
                case .image:
                    image = try await FeedbackService.shared.image(for: attachment)
                case .video:
                    player = AVPlayer(url: try await FeedbackService.shared.playableFile(for: attachment))
                }
            } catch {
                AppLogger.network("Feedback attachment failed to open", error: error)
                self.error = FeedbackService.userMessage(for: error)
            }
        }
    }
}

extension FeedbackAttachment: Identifiable {
    var id: String { path }
}

#Preview {
    NavigationStack {
        FeedbackThreadView(thread: FeedbackThread(
            id: "preview",
            number: 25743,
            kind: .bug,
            title: "海報牆資源顯示有問題",
            status: .needsInfo,
            createdAt: Date(),
            updatedAt: Date(),
            lastMessagePreview: "",
            lastMessageAuthor: .assistant,
            lastReplyAt: nil,
            userLastReadAt: nil
        ))
    }
}
