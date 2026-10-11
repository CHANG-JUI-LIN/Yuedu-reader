import SwiftUI

// MARK: - A custom explore page

/// One of the reader's custom explore pages: its blocks top to bottom, each loading as it
/// scrolls on. 編輯 opens the blocks as a list to change, reorder and delete; an empty
/// page offers 新增元件 at once. Its ⋯ menu renames or deletes it: since unified library 5d-1
/// it is opened from 範圍, and no tile is left to long-press.
struct CustomExplorePageView: View {
    let pageID: UUID

    @ObservedObject private var store = CustomExplorePageStore.shared
    @StateObject private var model = CustomExplorePageModel()
    @State private var isAddingComponent = false
    @State private var prompt: CustomExplorePagePrompt?
    @Environment(\.dismiss) private var dismiss

    private var page: CustomExplorePage? { store.page(id: pageID) }

    var body: some View {
        Group {
            if let page {
                if page.components.isEmpty {
                    emptyState
                } else {
                    blocks
                }
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("這一頁已被刪除"), systemImage: "rectangle.stack")
                }
            }
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .navigationTitle(page?.name ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let page, !page.components.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(localized("編輯"), value: ExploreNavigationRoute.customPageEditor(id: pageID))
                }
            }
            if let page {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        CustomExplorePageMenuItems(page: page, prompt: $prompt)
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("更多"))
                }
            }
        }
        .customExplorePagePrompts($prompt)
        .sheet(isPresented: $isAddingComponent) {
            CustomExploreComponentSheet(pageID: pageID, editing: nil)
        }
        .onAppear {
            if let page { model.sync(with: page) }
        }
        .onChange(of: page) { previous, page in
            if let page {
                model.sync(with: page)
            } else if previous != nil {
                // Deleted from its own ⋯ menu: nothing is left to show here.
                dismiss()
            }
        }
    }

    private var blocks: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.lg) {
                ForEach(model.blocks) { block in
                    CustomExploreBlockView(
                        block: block,
                        waterfallPaging: model.waterfallPaging,
                        onLoad: { model.load($0) },
                        onRetry: { model.retry($0) },
                        onLoadMore: { model.loadMoreWaterfall() }
                    )
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .softScrollEdges()
        .refreshable { model.reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("還沒有元件"), systemImage: "rectangle.3.group")
        } description: {
            Text(localized("加入元件，選來源配置的分類和版面，組出自己的探索頁。"))
                .foregroundStyle(DSColor.textSecondary)
        } actions: {
            Button(localized("新增元件")) { isAddingComponent = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("自訂頁（空）") {
    NavigationStack {
        CustomExplorePageView(pageID: UUID())
    }
}
