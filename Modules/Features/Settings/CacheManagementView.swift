import Combine
import SwiftUI

@MainActor
final class CacheManagementViewModel: ObservableObject {
    @Published private(set) var snapshot = CacheStorageSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: CacheManagementService

    init(service: CacheManagementService = CacheManagementService()) {
        self.service = service
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let service = service
        snapshot = await Task.detached(priority: .utility) {
            service.snapshot()
        }.value
        isLoading = false
    }

    func clear(_ category: CacheCategory) async {
        isLoading = true
        errorMessage = nil
        let service = service
        do {
            try await Task.detached(priority: .utility) {
                try service.clear(category)
            }.value
            snapshot = await Task.detached(priority: .utility) {
                service.snapshot()
            }.value
        } catch {
            AppLogger.error("CacheManagementView clear failed", error: error)
            errorMessage = localized("快取操作失敗")
        }
        isLoading = false
    }

    func clearAll() async {
        isLoading = true
        errorMessage = nil
        let service = service
        do {
            try await Task.detached(priority: .utility) {
                try service.clearAll()
            }.value
            snapshot = CacheStorageSnapshot()
        } catch {
            AppLogger.error("CacheManagementView clear-all failed", error: error)
            errorMessage = localized("快取操作失敗")
            snapshot = await Task.detached(priority: .utility) {
                service.snapshot()
            }.value
        }
        isLoading = false
    }
}

struct CacheManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CacheManagementViewModel
    @State private var pendingCategory: CacheCategory?
    @State private var showClearAllConfirmation = false
    @State private var showError = false

    init(service: CacheManagementService = CacheManagementService()) {
        _viewModel = StateObject(
            wrappedValue: CacheManagementViewModel(service: service)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading && viewModel.snapshot.total == 0 {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView(localized("正在讀取快取大小…"))
                            Spacer()
                        }
                    }
                    .interfaceSectionSurface()
                }

                if viewModel.errorMessage != nil {
                    Section {
                        Label(
                            localized("快取操作失敗"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundColor(DSColor.warning)

                        Button(localized("重試")) {
                            Task { await viewModel.refresh() }
                        }
                        .foregroundColor(DSColor.accent)
                    }
                    .interfaceSectionSurface()
                }

                ForEach(CacheCategory.allCases) { category in
                    cacheSection(for: category)
                }

                Section {
                    Button {
                        showClearAllConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(localized("清除全部快取"))
                                .foregroundColor(DSColor.destructive)
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.snapshot.total == 0)
                    .accessibilityHint(localized("將清除所有可重新下載的快取內容"))
                } footer: {
                    Text(localized("書籍、設定與備份同步資料不會受影響。"))
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(localized("快取管理"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
            }
            .task {
                await viewModel.refresh()
            }
            .refreshable {
                await viewModel.refresh()
            }
            .alert(
                localized("清除快取？"),
                isPresented: Binding(
                    get: { pendingCategory != nil },
                    set: { if !$0 { pendingCategory = nil } }
                ),
                presenting: pendingCategory
            ) { category in
                Button(localized(category.clearTitleKey), role: .destructive) {
                    pendingCategory = nil
                    Task { await viewModel.clear(category) }
                }
                Button(localized("取消"), role: .cancel) {
                    pendingCategory = nil
                }
            } message: { category in
                Text(localized(category.detailKey))
            }
            .alert(
                localized("清除全部快取？"),
                isPresented: $showClearAllConfirmation
            ) {
                Button(localized("清除全部快取"), role: .destructive) {
                    Task { await viewModel.clearAll() }
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("將刪除所有可重新下載的快取內容。書籍、設定與備份同步資料不會受影響。"))
            }
            .onChange(of: viewModel.errorMessage) { _, message in
                showError = message != nil
            }
            .alert(localized("操作失敗"), isPresented: $showError) {
                Button(localized("確定"), role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? localized("快取操作失敗"))
            }
        }
    }

    private func cacheSection(for category: CacheCategory) -> some View {
        Section {
            HStack {
                Label(localized(category.titleKey), systemImage: category.systemImage)
                    .foregroundColor(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(formattedByteCount(viewModel.snapshot[category]))
                    .font(DSFont.body)
                    .foregroundColor(DSColor.textSecondary)
                    .monospacedDigit()
            }

            Button {
                pendingCategory = category
            } label: {
                Text(localized(category.clearTitleKey))
                    .foregroundColor(DSColor.textPrimary)
            }
            .disabled(viewModel.isLoading || viewModel.snapshot[category] == 0)
        } footer: {
            Text(localized(category.detailKey))
        }
        .interfaceSectionSurface()
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    CacheManagementView()
}
