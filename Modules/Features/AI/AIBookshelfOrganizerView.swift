import SwiftUI

/// AI 整理書架. The model proposes a group for each book; the reader switches off any move
/// they disagree with, renames groups, and applies. Nothing on the shelf changes before that.
struct AIBookshelfOrganizerView: View {
    @EnvironmentObject private var store: BookStore
    @StateObject private var model: AIBookshelfOrganizerModel
    @ObservedObject private var subscription = SubscriptionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showsPaywall = false
    @State private var scope: AIBookshelfOrganizer.Scope = .ungrouped
    @State private var shelf: [AIBookshelfOrganizer.Book]?

    init(model: AIBookshelfOrganizerModel? = nil, shelf: [AIBookshelfOrganizer.Book]? = nil) {
        _model = StateObject(wrappedValue: model ?? AIBookshelfOrganizerModel())
        _shelf = State(initialValue: shelf)
    }

    private var candidates: [AIBookshelfOrganizer.Book] {
        AIBookshelfOrganizer.books(shelf ?? [], in: scope)
    }

    var body: some View {
        List {
            switch model.phase {
            case .idle, .failed: setup
            case let .running(completed, total): running(completed: completed, total: total)
            case .review: review
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("AI 整理書架"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if model.phase == .review, let proposal = model.proposal, !proposal.groups.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("套用")) {
                        model.apply(to: store)
                        dismiss()
                    }
                    .disabled(!proposal.canApply)
                }
            }
        }
        .task { if shelf == nil { shelf = await AIBookshelfOrganizerModel.shelfBooks(store: store) } }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showsPaywall) {
            PaywallView(highlightedFeature: .aiReading)
                .environmentObject(subscription)
        }
    }

    // MARK: - Setup

    @ViewBuilder private var setup: some View {
        if !ReaderPremiumVisibilityPolicy(isProActive: subscription.isProActive).allowsAI {
            // Reached without Pro only on iOS 17, where the bookshelf menu pushes this page
            // instead of opening the paywall straight from the menu. No service details and
            // no way into AI 助手設定, which is Pro as well.
            ContentUnavailableView {
                UnavailableLabel(localized("需要 Pro"), systemImage: "lock.fill")
            } description: {
                Text(localized("問書、整章翻譯、查詞與整理書架")).foregroundStyle(DSColor.textSecondary)
            } actions: {
                Button(localized("升級")) { showsPaywall = true }
                    .buttonStyle(.onAccentProminent)
            }
            .listRowBackground(Color.clear)
        } else {
            scopePicker
            proSetup
        }
    }

    private var scopePicker: some View {
        Section {
            Picker(localized("範圍"), selection: $scope) {
                Text(localized("未分組的書")).tag(AIBookshelfOrganizer.Scope.ungrouped)
                Text(localized("全部的書")).tag(AIBookshelfOrganizer.Scope.all)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
        } footer: {
            if scope == .all {
                Text(localized("已分組的書也可能被建議換到別的分組。"))
                    .dsSectionFooter()
            }
        }
    }

    @ViewBuilder private var proSetup: some View {
        if shelf == nil {
            Section { ProgressView(localized("載入中…")) }
                .interfaceSectionSurface()
        } else if candidates.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(scope == .ungrouped ? localized("沒有未分組的書") : localized("書架上沒有書"), systemImage: "books.vertical")
            }
                .listRowBackground(Color.clear)
        } else {
            switch model.service() {
            case let .success(active):
                Section {
                    ThemedLabeledContent(localized("要整理的書"), value: "\(candidates.count)")
                    ThemedLabeledContent(localized("生成服務"), value: active.name)
                    ThemedLabeledContent(localized("生成模型"), value: active.model)
                    ThemedLabeledContent(localized("預計模型呼叫"), value: "\(AIBookshelfOrganizer.batches(candidates).count)")
                } footer: {
                    Text(localized("會送出書名、作者，以及線上書已快取的分類、簡介和前幾章標題。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
                if case let .failed(message) = model.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DSColor.destructive)
                    }
                    .interfaceSectionSurface()
                }
                Section {
                    Button(model.phase == .idle ? localized("開始整理") : localized("重試")) {
                        model.start(books: candidates, existingGroups: store.allGroups)
                    }
                }
                .interfaceSectionSurface()
            case let .failure(reason):
                Section {
                    Text(reason.message)
                        .foregroundStyle(DSColor.textSecondary)
                    NavigationLink(localized("AI 助手設定")) { AISettingsView(embedded: true) }
                }
                .interfaceSectionSurface()
            }
        }
    }

    // MARK: - Running

    private func running(completed: Int, total: Int) -> some View {
        Section {
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text(localized("整理中…"))
                    .foregroundStyle(DSColor.textPrimary)
            } currentValueLabel: {
                Text(verbatim: "\(completed)/\(total)")
                    .foregroundStyle(DSColor.textSecondary)
            }
            Button(localized("停止"), role: .cancel) { model.cancel() }
        }
        .interfaceSectionSurface()
    }

    // MARK: - Review

    @ViewBuilder private var review: some View {
        if let proposal = model.proposal {
            if proposal.groups.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("不需要移動"), systemImage: "checkmark.circle")
                } description: {
                    Text(localized("每本書都已在建議的分組裡，或 AI 沒有把握。")).foregroundStyle(DSColor.textSecondary)
                }
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    Text(String(format: localized("將移動 %d 本書。關掉的書維持原樣，分組名稱可以直接改。"), proposal.includedCount))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(proposal.groups) { group in
                    groupSection(group)
                }
            }
            if proposal.unchangedCount + proposal.unassignedCount > 0 {
                Section {
                    Button(localized("重新產生建議")) { model.reset() }
                } footer: {
                    Text(String(format: localized("另有 %1$d 本已在建議的分組、%2$d 本 AI 沒有把握，維持不動。"),
                                proposal.unchangedCount, proposal.unassignedCount))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            } else {
                Section { Button(localized("重新產生建議")) { model.reset() } }
                    .interfaceSectionSurface()
            }
        }
    }

    private func groupSection(_ group: AIBookshelfProposal.Group) -> some View {
        let isNew = !store.allGroups.contains(AIBookshelfOrganizer.groupName(group.name))
        return Section {
            TextField(localized("分組名稱"), text: model.nameBinding(for: group))
                .font(DSFont.body.weight(.semibold))
                .accessibilityLabel(localized("分組名稱"))
            ForEach(group.moves) { move in
                Toggle(isOn: model.inclusionBinding(for: move, in: group)) {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(move.title)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(move.from.isEmpty ? localized("原本未分組") : String(format: localized("原本在「%@」"), move.from))
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
        } header: {
            Text(isNew ? localized("新分組") : localized("現有分組"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }
}

extension AIBookshelfOrganizerModel {
    // UIKit can read a surviving text field or switch while SwiftUI removes the
    // review after apply/reset. Resolve identity each time; never retain an array
    // subscript. The displayed snapshot remains readable after removal, while a
    // late write cannot recreate a discarded proposal or affect a new one.
    // Remove snapshot reads only when controls can no longer outlive a proposal.
    func nameBinding(for group: AIBookshelfProposal.Group) -> Binding<String> {
        Binding(
            get: { self.proposal?.groups.first { $0.id == group.id }?.name ?? group.name },
            set: { name in
                guard let index = self.proposal?.groups.firstIndex(where: { $0.id == group.id }) else { return }
                self.proposal?.groups[index].name = name
            }
        )
    }

    func inclusionBinding(for move: AIBookshelfProposal.Move, in group: AIBookshelfProposal.Group) -> Binding<Bool> {
        Binding(
            get: {
                self.proposal?.groups.first { $0.id == group.id }?.moves.first { $0.id == move.id }?.isIncluded
                    ?? move.isIncluded
            },
            set: { included in
                guard let groupIndex = self.proposal?.groups.firstIndex(where: { $0.id == group.id }),
                      let moveIndex = self.proposal?.groups[groupIndex].moves.firstIndex(where: { $0.id == move.id }) else { return }
                self.proposal?.groups[groupIndex].moves[moveIndex].isIncluded = included
            }
        )
    }
}

#Preview("Setup") {
    NavigationStack {
        AIBookshelfOrganizerView(model: AIBookshelfOrganizerModel(provider: AIWordLookupPreviewProvider()), shelf: [
            .init(id: UUID(), title: "萬古神帝", author: "飛天魚"),
            .init(id: UUID(), title: "三體", author: "劉慈欣"),
        ])
        .environmentObject(BookStore())
    }
}
