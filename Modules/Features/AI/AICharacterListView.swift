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
    private enum Scope: Equatable {
        case read
        case wholeBook
    }

    @ObservedObject private var store = AICharacterCardStore.shared
    @State private var newName = ""
    @State private var buildingName: String?
    @State private var stepText: String?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var isConfigured = false
    @State private var showSettings = false
    /// Everyone who speaks anywhere in the book, most talkative first.
    @State private var scanned: [AIBookSpeakerScan.Speaker] = []
    @State private var isScanning = false
    @State private var scope: Scope = .read
    @ObservedObject private var rosters = AISpeakerRosterStore.shared
    @State private var isVerifying = false

    private var profiles: [AICharacterProfile] {
        store.profiles(forBook: bookID)
    }

    private var roster: [String: String] { rosters.roster(forBook: bookID) }

    /// Scanned speakers that have no card yet, with the roster's verdict applied.
    ///
    /// Before the roster exists this is the raw heuristic output, artefacts and all — the
    /// 試探 / 一邊 / 劉癩子苦 problem. Once it exists, rejected candidates are gone and the
    /// survivors appear under their canonical name.
    private var uncarded: [AIBookSpeakerScan.Speaker] {
        let known = Set(profiles.flatMap(\.allNames))
        guard !roster.isEmpty else {
            return scanned.filter { !known.contains($0.name) }
        }
        var merged: [String: Int] = [:]
        for speaker in scanned {
            guard let canonical = roster[speaker.name] else { continue }
            merged[canonical, default: 0] += speaker.lineCount
        }
        return merged
            .filter { !known.contains($0.key) }
            .map { AIBookSpeakerScan.Speaker(name: $0.key, lineCount: $0.value) }
            .sorted {
                if $0.lineCount != $1.lineCount { return $0.lineCount > $1.lineCount }
                return $0.name < $1.name
            }
    }

    var body: some View {
        List {
            if isScanning { scanningSection }
            scopeSection
            if !scanned.isEmpty { verifySection }
            if !uncarded.isEmpty { detectedSection }
            if let errorMessage { errorSection(errorMessage) }
            if profiles.isEmpty, buildingName == nil, !isScanning, uncarded.isEmpty {
                emptySection
            } else {
                ForEach(profiles, id: \.name) { profile in
                    profileSection(profile)
                }
            }
            addSection
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("人物卡"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            store.loadIfNeeded(forBook: bookID)
            rosters.loadIfNeeded(forBook: bookID)
            isConfigured = AIAssistantService.shared.isConfigured
            scanBook()
        }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $showSettings, onDismiss: {
            isConfigured = AIAssistantService.shared.isConfigured
        }) {
            AISettingsView()
        }
    }

    /// One tap per name. The heuristic already found them; asking the reader to retype
    /// 張若塵 by hand was the whole problem.
    private var scanningSection: some View {
        Section {
            HStack(spacing: DSSpacing.sm) {
                ProgressView()
                Text(localized("正在掃描全書的角色…"))
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// One tap per name, and the names come from the book rather than from the reader's
    /// memory. Asking someone to type a character they already know, in order to be told
    /// who that character is, is a circle.
    private var detectedSection: some View {
        Section {
            if !isConfigured {
                Button {
                    showSettings = true
                } label: {
                    LabeledContent(localized("設定 AI 助手")) {
                        Text(localized("未設定"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            ForEach(uncarded) { speaker in
                Button {
                    build(name: speaker.name)
                } label: {
                    HStack {
                        Text(speaker.name)
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer()
                        Text(String(format: localized("%d 句"), speaker.lineCount))
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                        if buildingName == speaker.name {
                            ProgressView()
                        } else {
                            Image(systemName: "sparkles")
                                .foregroundStyle(DSColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .disabled(buildingName != nil || !isConfigured)
                .accessibilityLabel(String(format: localized("整理 %@ 的人物卡"), speaker.name))
            }
        } header: {
            Text(localized("書中的角色"))
        } footer: {
            // Says the one thing the rows cannot: that the un-verified list contains
            // things that are not people.
            if roster.isEmpty {
                Text(localized("自動抓的，會混進「試探」這種不是人的詞。"))
                    .dsSectionFooter()
            }
        }
        .listRowBackground(Color.clear)
    }

    /// The button that fixes the list itself.
    ///
    /// Stripping a speech verb off the end of a sentence is right often enough to be useful
    /// and wrong in ways a blocklist cannot fix — 試探道, 一邊道, 劉癩子苦笑道. One model call
    /// over the whole candidate list sorts out what is a person and what their real name is.
    private var verifySection: some View {
        Section {
            Button {
                verifyRoster()
            } label: {
                HStack {
                    Text(roster.isEmpty ? localized("用 AI 整理名單") : localized("重新整理名單"))
                    Spacer()
                    if isVerifying { ProgressView() }
                }
            }
            .disabled(isVerifying || isScanning || scanned.isEmpty || !isConfigured)
        }
        .listRowBackground(Color.clear)
    }

    private func verifyRoster() {
        let candidates = scanned.map {
            AISpeakerRoster.Candidate(name: $0.name, lineCount: $0.lineCount, sample: $0.sample)
        }
        guard !candidates.isEmpty else { return }
        errorMessage = nil
        isVerifying = true
        task?.cancel()
        task = Task {
            do {
                _ = try await AIAssistantService.shared.buildSpeakerRoster(
                    bookID: bookID,
                    adapter: adapter,
                    candidates: candidates
                )
            } catch is CancellationError {
                // The reader left.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isVerifying = false
        }
    }

    /// Chapters the reader has actually reached.
    ///
    /// Derived from the adapter's own progress, which is cumulative characters rather than
    /// chapter index — a 200-character preface followed by a 40,000-character chapter would
    /// otherwise look like half the book.
    private var sectionsInScope: [AIChunkableSection] {
        let all = adapter.chunkSections
        guard scope == .read else { return all }
        let readable = all.indices.filter { index in
            (adapter.chunkLocation(sectionIndex: index, characterOffset: 0)?.progress ?? 0) <= progress
        }
        // Always at least the chapter being read, so a reader at 0% still sees someone.
        guard let last = readable.last else { return Array(all.prefix(1)) }
        return Array(all[0...last])
    }

    /// Off the main thread: a long web novel is megabytes of text, and the heuristic walks
    /// all of it.
    private func scanBook(force: Bool = false) {
        guard force || (scanned.isEmpty && !isScanning) else { return }
        let sections = sectionsInScope
        guard !sections.isEmpty else { return }
        let aliases = store.aliasMap(forBook: bookID)
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AIBookSpeakerScan.scan(sections: sections, aliases: aliases)
            }.value
            await MainActor.run {
                scanned = found
                isScanning = false
            }
        }
    }

    /// Widens the scan to the whole book.
    private var scopeSection: some View {
        Section {
            if scope == .read {
                Button {
                    scope = .wholeBook
                    scanBook(force: true)
                } label: {
                    Label(localized("掃描整本書"), systemImage: "books.vertical")
                }
                .disabled(isScanning)
            } else {
                Button {
                    scope = .read
                    scanBook(force: true)
                } label: {
                    Label(localized("只看讀過的部分"), systemImage: "bookmark")
                }
                .disabled(isScanning)
            }
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
            Text(localized("掃不到的人物"))
        } footer: {
            // The one place in the assistant that reads past the reader's progress. It is
            // opt-in, and the only thing holding spoilers back is a prompt rule — so the
            // reader is told, rather than finding out from a card.
            Text(localized("人物卡會搜尋整本書（不只你讀到的地方），並要求不要透露結局。想完全避免劇透就先別整理主角。"))
                .dsSectionFooter()
        }
        .listRowBackground(Color.clear)
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label(localized("還沒有人物卡"), systemImage: "person.text.rectangle")
            } description: {
                Text(localized("整理之後，多角色朗讀也會用這裡的別名，把同一個人的不同稱呼歸成同一個聲音。"))
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
                LabeledContent(localized("身分"), value: role)
            }
            if let first = profile.firstAppearance {
                LabeledContent(localized("首次登場"), value: first)
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
