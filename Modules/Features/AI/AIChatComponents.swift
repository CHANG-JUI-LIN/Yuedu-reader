import SwiftUI

// MARK: - Reading assistant chat kit
//
// The conversation surfaces of the reading assistant, after OpenMinis's chat layout:
//
// - The answer is plain prose on the page under a small assistant header. Only the
//   reader's own turn sits in a bubble, on the trailing side.
// - Secondary facts about an answer (its scope notes, a missing citation) stay one tap
//   away in a single footer control instead of stacking under every answer.
// - The composer is the only floating layer. It carries the model and reading-scope
//   pickers itself and sits on the app's floating surface (Liquid Glass on iOS 26,
//   the 界面效果 material before that) without the 光暈, with the transcript
//   scrolling underneath.

/// One selectable model: the service it belongs to and the model name on that service.
struct AIChatModelChoice: Hashable {
    let serviceID: UUID
    let model: String
}

// MARK: - Reader's turn

struct AIChatUserBubble: View {
    let text: String
    /// The passage the question was asked about, when it came from a text selection.
    var quote: String? = nil

    var body: some View {
        HStack {
            Spacer(minLength: DSLayout.aiChatBubbleLeadingInset)
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                if let quote { AIChatQuote(text: quote, lineLimit: 3) }
                Text(text)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        }
    }
}

/// A quoted passage with a leading accent bar — the selection a question refers to.
struct AIChatQuote: View {
    let text: String
    var lineLimit: Int? = 3

    var body: some View {
        Text(text)
            .font(DSFont.footnote)
            .foregroundStyle(DSColor.textSecondary)
            .lineLimit(lineLimit)
            .padding(.leading, DSSpacing.sm + DSLayout.readerNoteQuoteBarWidth)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(DSColor.accent)
                    .frame(width: DSLayout.readerNoteQuoteBarWidth)
            }
    }
}

// MARK: - Assistant's turn

struct AIChatAssistantMessage: View {
    let message: AIChatMessage
    /// The answer was produced from a wider source or reading range than is confirmable now.
    var isHiddenByScope = false
    var stageLabel = ""
    /// Offered only on the failed last turn, and nil while another request is running.
    var onRetry: (() -> Void)? = nil
    var onOpenCitation: (Int, LLMCitation) -> Void = { _, _ in }

    @State private var showsNotes = false
    @State private var copyCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            if isHiddenByScope {
                Label(localized("此回覆超出目前可確認的來源或閱讀範圍，已暫時隱藏。"), systemImage: "eye.slash")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                if !message.text.isEmpty { AIAnswerMarkdownView(text: message.text) }
                if message.isPending { pendingRow }
                if let error = message.errorMessage { errorRow(error) }
                if !message.citations.isEmpty { citationRow }
                if !message.isPending && !message.text.isEmpty { footer }
                if showsNotes { notesCard }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        Label {
            Text(localized("AI 助手"))
        } icon: {
            Image(systemName: "sparkles").foregroundStyle(DSColor.accent)
        }
        .font(DSFont.subheadline.weight(.semibold))
        .foregroundStyle(DSColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
    }

    private var pendingRow: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView().controlSize(.small)
            Text(stageLabel)
        }
        .font(DSFont.footnote)
        .foregroundStyle(DSColor.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
            if let onRetry {
                Button(localized("重試這個問題"), systemImage: "arrow.clockwise", action: onRetry)
                    .font(DSFont.footnote)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
    }

    private var citationRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(Array(message.citations.enumerated()), id: \.element.chunkID) { index, citation in
                    Button { onOpenCitation(index, citation) } label: {
                        Label("\(index + 1) · \(citation.sectionTitle ?? localized("原文"))", systemImage: "quote.opening")
                            .lineLimit(1)
                    }
                    .font(DSFont.footnote)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("ai.citation.\(index)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Everything the reader should be able to check lives behind one control. When the
    /// answer cites nothing from the book, that is the label — it is the caveat that
    /// matters most — and the scope notes open under it.
    private var notes: [String] { message.notices ?? [] }
    private var notesTitle: String { message.hasEvidence ? localized("回答範圍") : localized("未附書中引用") }

    private var footer: some View {
        HStack(spacing: DSSpacing.sm) {
            Button {
                UIPasteboard.general.string = message.text
                copyCount += 1
                AccessibilityNotification.Announcement(localized("已複製")).post()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(localized("複製"))
            .sensoryFeedback(.success, trigger: copyCount)

            if !notes.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : DSAnimation.fast) { showsNotes.toggle() }
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: message.hasEvidence ? "info.circle" : "exclamationmark.circle")
                            .accessibilityHidden(true)
                        Text(notesTitle)
                        Image(systemName: "chevron.down")
                            .font(DSFont.caption2)
                            .rotationEffect(.degrees(showsNotes ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityValue(showsNotes ? localized("已展開") : localized("已收合"))
            } else if !message.hasEvidence {
                Label(notesTitle, systemImage: "exclamationmark.circle")
            }
            Spacer(minLength: 0)
        }
        .font(DSFont.footnote)
        .foregroundStyle(DSColor.textSecondary)
        .buttonStyle(.plain)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            ForEach(notes, id: \.self) { note in
                Text(note)
            }
        }
        .font(DSFont.footnote)
        .foregroundStyle(DSColor.textSecondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .transition(.opacity)
    }
}

/// Block Markdown for answers. Block boundaries stay stable while text streams in; inline
/// Markdown inside each block is rendered by SwiftUI.
struct AIAnswerMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = AIAnswerMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : gap(between: blocks[index - 1], and: block))
            }
        }
        .textSelection(.enabled)
    }

    /// Consecutive list items read as one list; every other boundary is a paragraph break.
    private func gap(between previous: AIAnswerMarkdown.Block, and block: AIAnswerMarkdown.Block) -> CGFloat {
        previous.kind == .list && block.kind == .list ? DSSpacing.xs : DSSpacing.md
    }

    @ViewBuilder private func blockView(_ block: AIAnswerMarkdown.Block) -> some View {
        switch block.kind {
        case .heading:
            Text(Self.formatted(block.text))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            prose(block.text)
        case .list:
            let item = AIAnswerMarkdown.listItem(block.text)
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text(item.marker)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
                prose(item.text)
            }
            .padding(.leading, CGFloat(item.depth) * DSSpacing.lg)
            .accessibilityElement(children: .combine)
        case .quote:
            prose(block.text, color: DSColor.textSecondary)
                .padding(.leading, DSSpacing.md + DSLayout.readerNoteQuoteBarWidth)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DSColor.separator)
                        .frame(width: DSLayout.readerNoteQuoteBarWidth)
                }
        case .code, .table:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(DSFont.footnote.monospaced())
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(DSSpacing.md)
                    .foregroundStyle(DSColor.textPrimary)
            }
            .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
    }

    private func prose(_ text: String, color: Color = DSColor.textPrimary) -> some View {
        Text(Self.formatted(text))
            .font(DSFont.body)
            .foregroundStyle(color)
            .lineSpacing(DSSpacing.xs)
    }

    /// Inline Markdown; text the parser rejects is shown as written, which is what the
    /// model sent.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Suggestions

/// Quick actions shown above the composer, each on its own floating capsule.
struct AIChatSuggestionBar: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let run: () -> Void
    }

    let items: [Item]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(items) { item in
                    Button(action: item.run) { AIChatSuggestionLabel(title: item.title) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.md)
        }
        .scrollIndicators(.hidden)
        // The capsules' glass edge extends past their frames.
        .scrollClipDisabled()
    }
}

private struct AIChatSuggestionLabel: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font(DSFont.subheadline)
            .foregroundStyle(isEnabled ? DSColor.textPrimary : DSColor.textDisabled)
            .lineLimit(1)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .floatingSurfaceBackground(in: Capsule())
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }
}

// MARK: - Composer

/// The floating input card: an optional quoted selection, the question field, and one
/// control row with the model picker, the reading-scope picker and send/stop.
struct AIChatComposer: View {
    @Binding var draft: String
    var inputFocused: FocusState<Bool>.Binding
    var selectionText: String? = nil
    var onClearSelection: () -> Void = {}
    let wholeBook: Bool
    let onSetWholeBook: (Bool) -> Void
    let profiles: [AIServiceProfile]
    let modelChoice: AIChatModelChoice?
    let modelTitle: String
    let onSelectModel: (AIChatModelChoice) -> Void
    let isBusy: Bool
    let isSourceReady: Bool
    let onSubmit: () -> Void
    let onStop: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var canSend: Bool {
        isSourceReady && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if let selectionText {
                HStack(alignment: .top, spacing: DSSpacing.sm) {
                    AIChatQuote(text: selectionText, lineLimit: 2)
                        .padding(.top, DSSpacing.md)
                    Spacer(minLength: 0)
                    Button(action: onClearSelection) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DSColor.textSecondary)
                            .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized("移除選文"))
                }
            }
            if wholeBook {
                Label {
                    Text(localized("全書模式可能包含尚未讀到的情節。"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DSColor.warning)
                }
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.top, DSSpacing.sm)
            }
            if !isSourceReady {
                HStack(spacing: DSSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(localized("準備閱讀內容…"))
                }
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.top, DSSpacing.sm)
                .accessibilityElement(children: .combine)
            }
            TextField(localized("問一個問題"), text: $draft, axis: .vertical)
                .accessibilityIdentifier("ai.chat.input")
                .font(DSFont.body)
                .lineLimit(1...6)
                .focused(inputFocused)
                .padding(.horizontal, DSSpacing.xs)
                .frame(minHeight: DSLayout.minimumTapTarget)
            HStack(alignment: .bottom, spacing: 0) {
                // At accessibility sizes the two pickers no longer fit beside each other
                // and the send button; they stack instead of truncating to icons.
                let pickers = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(spacing: 0))
                pickers {
                    modelMenu
                    scopeMenu.layoutPriority(1)
                }
                Spacer(minLength: DSSpacing.sm)
                sendButton.layoutPriority(2)
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.top, DSSpacing.xs)
        .floatingSurfaceBackground(in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
    }

    private var modelMenu: some View {
        let selection = Binding<AIChatModelChoice?>(
            get: { modelChoice },
            set: { if let choice = $0 { onSelectModel(choice) } }
        )
        // A menu shows neither section titles around an inline picker nor the picker's
        // own label, so several services each get a submenu named after the service.
        // One service — the usual setup — lists its models directly, one tap to switch.
        return Menu {
            if profiles.count == 1, let profile = profiles.first {
                modelPicker(for: profile, selection: selection)
                    .pickerStyle(.inline)
            } else {
                ForEach(profiles) { profile in
                    modelPicker(for: profile, selection: selection)
                        .pickerStyle(.menu)
                }
            }
        } label: {
            AIChatComposerMenuLabel(systemImage: "cpu", title: modelTitle)
        }
        .accessibilityLabel(localized("選擇模型"))
        .accessibilityValue(modelTitle)
    }

    private func modelPicker(for profile: AIServiceProfile, selection: Binding<AIChatModelChoice?>) -> some View {
        Picker(profile.name, selection: selection) {
            ForEach(Self.models(of: profile), id: \.self) { model in
                Text(model).tag(Optional(AIChatModelChoice(serviceID: profile.id, model: model)))
            }
        }
    }

    private var scopeMenu: some View {
        let title = wholeBook ? localized("全書") : localized("已讀")
        return Menu {
            Picker(localized("閱讀範圍"), selection: Binding(get: { wholeBook }, set: { onSetWholeBook($0) })) {
                Label(localized("已讀"), systemImage: "book").tag(false)
                Label(localized("全書"), systemImage: "books.vertical").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            AIChatComposerMenuLabel(systemImage: wholeBook ? "books.vertical" : "book", title: title)
        }
        .accessibilityLabel(localized("閱讀範圍"))
        .accessibilityValue(title)
    }

    private var sendButton: some View {
        Button {
            if isBusy { onStop() } else if canSend { onSubmit() }
        } label: {
            Image(systemName: isBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(DSFont.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(DSColor.textOnAccent, isBusy || canSend ? DSColor.accent : DSColor.textDisabled)
                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
        }
        .buttonStyle(.plain)
        .disabled(!isBusy && !canSend)
        .accessibilityLabel(isBusy ? localized("停止") : localized("送出"))
    }

    /// Every model the service lists, plus its default, once each.
    static func models(of profile: AIServiceProfile) -> [String] {
        Array(Set(profile.models + [profile.configuration.defaultModel]))
            .filter { !$0.isEmpty }
            .sorted()
    }
}

private struct AIChatComposerMenuLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(DSFont.caption2)
                .accessibilityHidden(true)
        }
        .font(DSFont.footnote)
        .foregroundStyle(DSColor.textSecondary)
        .padding(.horizontal, DSSpacing.xs)
        .frame(minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

#Preview("Messages") {
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            AIChatUserBubble(text: "這段在說什麼？", quote: "他注入真氣激活銘紋，鐵球展開成三米高的鋼鐵巨人。")
            AIChatAssistantMessage(message: {
                var message = AIChatMessage(role: .assistant, text: "## 煉器戰士\n張若塵接到大師兄所贈的鐵球。\n\n- 第一點\n- 第二點",
                    citations: [LLMCitation(chunkID: "a", quote: "…", spineIndex: 0, charOffset: 0, sectionTitle: "第561章 炼器战士")])
                message.notices = [localized("本次只搜尋可確認的已讀範圍。")]
                return message
            }())
        }
        .padding(DSSpacing.lg)
    }
    .softScrollEdges()
    .background(DSColor.groupedBackground)
}
