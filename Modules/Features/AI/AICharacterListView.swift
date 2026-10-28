import SwiftUI

/// The book's character cards, and the names they also go by.
///
/// The aliases are not decoration: they are what 多角色朗讀 uses to give 張若塵, 若塵 and 塵哥
/// one voice instead of three.
struct AICharacterListView: View {
    let bookID: UUID
    let adapter: AIBookContentAdapter
    /// How far the reader has got, on the chunks' 0…1 scale.
    let progress: Double

    /// How much of the book the character list covers.
    ///
    /// Default is what has been read, for the same reason every other AI feature here stops
    /// at the reader's progress: a character who has not appeared yet is a spoiler, and
    /// seeing their name in a list is enough to be one. Scanning the whole book is a
    /// deliberate, one-tap choice.
    private enum Scope: Hashable {
        case read
        case wholeBook
    }

    @ObservedObject private var store = AICharacterCardStore.shared
    @State private var newName = ""
    @State private var buildingName: String?
    @State private var stepText: String?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmWholeBook = false
    @State private var scope: Scope = .read

    private var profiles: [AICharacterProfile] {
        store.profiles(forBook: bookID).filter { scope == .wholeBook || $0.isSafe(at: activeBoundary) }
    }

    private var activeBoundary: AIReadingBoundary { adapter.boundary(wholeBook: scope == .wholeBook) }
    private var scopeKey: String { "\(adapter.contentFingerprint)@\(activeBoundary)" }
    var body: some View {
        List {
            scopeSection
            if let errorMessage { errorSection(errorMessage) }
            if profiles.isEmpty, buildingName == nil {
                emptySection
            } else {
                ForEach(profiles, id: \.name) { profile in
                    profileSection(profile)
                }
            }
            addSection
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("人物卡"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            store.loadIfNeeded(forBook: bookID)
        }
        .task(id: scopeKey) {
            task?.cancel()
            buildingName = nil
            AIAssistantService.shared.activate(adapter)
        }
        .onDisappear { task?.cancel() }
        .confirmationDialog(localized("全書模式可能揭露身分、關係與結局"), isPresented: $confirmWholeBook, titleVisibility: .visible) {
            Button(localized("使用全書模式")) { scope = .wholeBook }
            Button(localized("取消"), role: .cancel) {}
        }
    }

    /// Selects the evidence scope for manually requested character cards. Whole book asks
    /// first; the control stays on 已讀 until the reader confirms.
    private var scopeSection: some View {
        Section {
            Picker(localized("範圍"), selection: Binding(get: { scope }, set: { value in
                if value == .wholeBook { confirmWholeBook = true } else { scope = .read }
            })) {
                Text(localized("已讀")).tag(Scope.read)
                Text(localized("全書")).tag(Scope.wholeBook)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(
                scope == .read
                    ? String(
                        format: localized("只列出你讀到 %d%% 為止出現過的角色。"),
                        Int((progress * 100).rounded())
                    )
                    : localized("包含你還沒讀到的角色。")
            )
            .dsSectionFooter()
            if scope == .read, store.profiles(forBook: bookID).count > profiles.count {
                Text(localized("部分卡片來源或範圍未驗證，已在安全模式隱藏；自訂設定仍保留。"))
                    .dsSectionFooter()
            }
        }
        .listRowBackground(Color.clear)
    }

    private var addSection: some View {
        Section {
            TextField(localized("人物名稱"), text: $newName)
                .disabled(buildingName != nil)
            Button {
                build(name: newName.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                HStack {
                    Text(buildingName == nil ? localized("整理人物卡") : (stepText ?? localized("整理中…")))
                    Spacer()
                    if buildingName != nil { ProgressView() }
                }
            }
            .disabled(
                buildingName != nil
                    || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text(localized("指定人物整理卡片"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            // The one place in the assistant that reads past the reader's progress. It is
            // opt-in, and the only thing holding spoilers back is a prompt rule — so the
            // reader is told, rather than finding out from a card.
            Text(localized("人物卡依目前範圍整理；全書及舊版未驗證卡片不會用於安全模式的別名或朗讀。"))
                .dsSectionFooter()
        }
        // An input on the bare page reads as a caption; the card makes it a field.
        .interfaceSectionSurface()
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                UnavailableLabel(localized("還沒有人物卡"), systemImage: "person.text.rectangle")
            } description: {
                Text(localized("整理之後，多角色朗讀也會用這裡的別名，把同一個人的不同稱呼歸成同一個聲音。")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(DSColor.destructive)
        }
        .listRowBackground(Color.clear)
    }

    private func profileSection(_ profile: AICharacterProfile) -> some View {
        Section {
            if let role = profile.role {
                ThemedLabeledContent(localized("身分"), value: role)
            }
            if let first = profile.firstAppearance {
                ThemedLabeledContent(localized("首次登場"), value: first)
            }
            if !profile.aliasCandidates.isEmpty {
                LabeledContent(
                    localized("別稱"),
                    value: profile.aliasCandidates.joined(separator: "、")
                )
            }
            ForEach(profile.relationships, id: \.self) { relationship in
                Text(relationship)
                    .font(DSFont.callout)
                    .foregroundStyle(DSColor.textSecondary)
            }
            if !profile.summary.isEmpty {
                Text(profile.summary)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .textSelection(.enabled)
            }
        } header: {
            Text(profile.name)
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(profile.citationChunkIDs.isEmpty ? localized("未提供可核對引用") : String(format: localized("引用 %d 筆原文"), profile.citationChunkIDs.count))
                .dsSectionFooter()
            if !profile.isSafe(at: adapter.boundary()) {
                Text(localized("全書或未驗證範圍，可能含劇透"))
                    .dsSectionFooter()
            }
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(name: profile.name, forBook: bookID)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
            Button {
                build(name: profile.name)
            } label: {
                Label(localized("重新整理"), systemImage: "arrow.clockwise")
            }
        }
    }

    private func build(name: String) {
        guard !name.isEmpty else { return }
        errorMessage = nil
        buildingName = name
        stepText = nil
        task?.cancel()
        task = Task {
            do {
                _ = try await AIAssistantService.shared.characterCard(
                    name: name,
                    bookID: bookID,
                    adapter: adapter,
                    boundary: activeBoundary,
                    onStep: { step, total in
                        Task { @MainActor in
                            stepText = String(
                                format: localized("整理中…（第 %1$d/%2$d 步）"),
                                step + 1,
                                total
                            )
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                newName = ""
            } catch is CancellationError {
                // The reader left.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            buildingName = nil
            stepText = nil
        }
    }
}

#Preview {
    NavigationStack {
        AICharacterListView(
            bookID: UUID(),
            adapter: AIBookContentAdapter(bookID: UUID(), chapters: [], textForChapter: { _ in nil }),
            progress: 0.42
        )
    }
}
