import SwiftUI

/// The book's people, and the two ways to build them. Everything character-related in the
/// assistant starts here and only goes one level down: the builders and the detail pages
/// do not link back into each other.
struct AIBookCharactersView: View {
    let adapter: AIBookContentAdapter
    let progress: Double
    var onOpenCitation: ((LLMCitation) -> Void)? = nil
    @State private var query = ""
    @State private var snapshot = AIBookCharactersSnapshot()
    @State private var error: String?
    @State private var loading = true
    @ObservedObject private var memory = AICharacterMemoryService.shared

    private var memoryCards: [AIMemoryCard] {
        snapshot.memory.cards.filter { query.isEmpty || $0.names.contains(where: { $0.localizedCaseInsensitiveContains(query) }) }
    }
    private var profiles: [AICharacterProfile] {
        snapshot.profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { AICharacterMemoryView(adapter: adapter, onOpenCitation: onOpenCitation) } label: {
                    Label(localized("整理已讀人物"), systemImage: "wand.and.stars")
                        .foregroundStyle(DSColor.textPrimary)
                        .labelStyle(IconConsistentLabelStyle())
                }
                NavigationLink { AIRelationshipMapView(adapter: adapter, onOpenCitation: onOpenCitation) } label: {
                    Label(localized("人物關係圖"), systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(DSColor.textPrimary)
                        .labelStyle(IconConsistentLabelStyle())
                }
                NavigationLink { AICharacterListView(bookID: adapter.chunkBookID, adapter: adapter, progress: progress) } label: {
                    Label(localized("人物卡與朗讀別稱"), systemImage: "person.text.rectangle")
                        .foregroundStyle(DSColor.textPrimary)
                        .labelStyle(IconConsistentLabelStyle())
                }
            }
            .interfaceSectionSurface()
            if loading {
                Section { ProgressView(localized("載入中…")) }
                    .interfaceSectionSurface()
            } else if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DSColor.destructive)
                }
                .interfaceSectionSurface()
            } else if snapshot.memory.cards.isEmpty && snapshot.profiles.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("尚無人物資料"), systemImage: "person.2")
                } description: {
                    Text(localized("整理已讀內容，查看人物與原文依據。")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
                }
                    .listRowBackground(Color.clear)
            }
            if !memoryCards.isEmpty {
                Section {
                    ForEach(memoryCards) { card in
                        NavigationLink {
                            AIMemoryCardView(entityID: card.entityIDs.sorted().first ?? card.id,
                                source: adapter, boundary: adapter.boundary(), onOpenCitation: onOpenCitation, showsDone: false)
                        } label: {
                            LabeledContent(card.names.joined(separator: "、"),
                                           value: String(format: localized("%d 筆經歷記錄"), card.facts.count))
                        }
                    }
                } header: { Text(localized("人物經歷")).foregroundStyle(DSColor.textSecondary) }
                .interfaceSectionSurface()
            }
            if !profiles.isEmpty {
                Section {
                    ForEach(profiles, id: \.name) { profile in
                        NavigationLink { AICharacterProfileView(profile: profile) } label: {
                            ThemedLabeledContent(profile.name, value: profile.role ?? "")
                        }
                    }
                } header: { Text(localized("已保存人物卡")).foregroundStyle(DSColor.textSecondary) }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .searchable(text: $query, prompt: localized("搜尋目前範圍的人物"))
        .navigationTitle(localized("書中人物"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .task(id: "\(adapter.contentFingerprint):\(memory.revisions[adapter.chunkBookID] ?? 0)") {
            loading = true
            do { snapshot = try await AIAssistantService.shared.characters(source: adapter); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

/// One saved character card, read-only. Editing and rebuilding live in 人物卡與朗讀別稱.
private struct AICharacterProfileView: View {
    let profile: AICharacterProfile

    var body: some View {
        List {
            if profile.role != nil || profile.firstAppearance != nil || !profile.aliasCandidates.isEmpty {
                Section {
                    if let role = profile.role { ThemedLabeledContent(localized("身分"), value: role) }
                    if let first = profile.firstAppearance { ThemedLabeledContent(localized("首次登場"), value: first) }
                    if !profile.aliasCandidates.isEmpty {
                        ThemedLabeledContent(localized("別稱"), value: profile.aliasCandidates.joined(separator: "、"))
                    }
                }
                .interfaceSectionSurface()
            }
            if !profile.summary.isEmpty {
                Section { Text(profile.summary).textSelection(.enabled).foregroundStyle(DSColor.textPrimary) }
                    .interfaceSectionSurface()
            }
            if !profile.relationships.isEmpty {
                Section {
                    ForEach(profile.relationships, id: \.self) { Text($0).foregroundStyle(DSColor.textPrimary) }
                } header: { Text(localized("關係記錄")).foregroundStyle(DSColor.textSecondary) }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(profile.name)
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview { NavigationStack { AIBookCharactersView(adapter: .init(bookID: UUID(), chapters: [], textForChapter: { _ in nil }), progress: 0) } }
