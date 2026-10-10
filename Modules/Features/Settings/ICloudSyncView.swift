import CloudKit
import SwiftUI

struct ICloudSyncView: View {
    @StateObject private var manager = ICloudSyncManager.shared
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showDeleteConfirmation = false

    private var iCloudReady: Bool { manager.accountStatus == .available }

    var body: some View {
        Form {
            accountSection
            autoSyncSection
            actionsSection
            statusSection
            deleteSection
        }
        .softScrollEdges()
        .navigationTitle(localized("iCloud 同步"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .disabled(manager.isSyncing)
        .overlay {
            if manager.isSyncing {
                syncingOverlay
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .task {
            _ = await manager.refreshAccountStatus()
        }
    }

    private var accountSection: some View {
        Section {
            HStack {
                Label(manager.statusTitle(isAppSignedIn: true), systemImage: statusIcon)
                    .foregroundColor(statusColor)
                Spacer()
                if iCloudReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        } header: {
            Text(localized("帳號狀態"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if !iCloudReady {
                Text(localized("請確認系統設定中已登入 iCloud，且 iCloud Drive/CloudKit 可用"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private var autoSyncSection: some View {
        Section {
            Toggle(localized("自動同步"), isOn: $gs.iCloudAutoSync)
                .tint(DSColor.accent)
                .onChange(of: gs.iCloudAutoSync) { _, on in
                    if on, iCloudReady { Task { try? await manager.sync(reason: "toggle-on") } }
                }
        } footer: {
            Text(localized("啟動與切背景時自動同步書庫、來源配置、替換規則、書檔、閱讀設定、氣泡樣式與自訂閱讀背景。多台裝置會合併，不會互相覆蓋。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var actionsSection: some View {
        Section(header: Text(localized("操作")).foregroundStyle(DSColor.textSecondary)) {
            Button {
                Task { await runSync() }
            } label: {
                Label(localized("立即同步"), systemImage: "arrow.triangle.2.circlepath.icloud")
                    .foregroundColor(DSColor.accent)
            }
            .disabled(!iCloudReady)

            Button {
                Task { await refreshStatus() }
            } label: {
                Label(localized("檢查 iCloud 狀態"), systemImage: "checkmark.icloud")
                    .foregroundColor(DSColor.accent)
            }
        }
        .interfaceSectionSurface()
    }

    private var statusSection: some View {
        Section(header: Text(localized("狀態")).foregroundStyle(DSColor.textSecondary)) {
            if let date = manager.lastSyncDate {
                HStack {
                    Text(localized("上次同步"))
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                    Text(date, style: .relative)
                        .foregroundColor(DSColor.textPrimary)
                }
            }

            if !manager.statusMessage.isEmpty {
                Text(manager.statusMessage)
                    .foregroundColor(DSColor.textSecondary)
                    .font(DSFont.footnote)
            }
        }
        .interfaceSectionSurface()
    }

    /// Apart from the other actions, at the bottom: it cannot be undone.
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(localized("刪除 iCloud 上的資料"), systemImage: "trash")
            }
            .disabled(!iCloudReady)
        }
        .interfaceSectionSurface()
        .alert(localized("刪除 iCloud 上的資料？"), isPresented: $showDeleteConfirmation) {
            Button(localized("刪除"), role: .destructive) {
                Task { await runDeleteRemoteData() }
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("會刪除 iCloud 上的書庫、來源配置、替換規則、書檔、閱讀設定、氣泡樣式與閱讀背景，並關閉這台裝置的自動同步。這台裝置上的資料不受影響；其他裝置開著自動同步時，會再上傳它們的資料。"))
        }
    }

    private var statusIcon: String {
        iCloudReady ? "icloud.fill" : "exclamationmark.icloud"
    }

    private var statusColor: Color {
        switch manager.accountStatus {
        case .available:
            return DSColor.accent
        case .noAccount, .restricted, .temporarilyUnavailable:
            return .orange
        default:
            return .secondary
        }
    }

    private var syncingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text(manager.statusMessage)
                    .foregroundColor(.white)
                    .font(DSFont.subheadline)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private func refreshStatus() async {
        let status = await manager.refreshAccountStatus()
        await MainActor.run {
            alertTitle = status == .available ? localized("iCloud 可用") : localized("iCloud 無法使用")
            alertMessage = manager.statusTitle(isAppSignedIn: true)
            showAlert = true
        }
    }

    private func runSync() async {
        do {
            try await manager.sync(reason: "manual")
            await MainActor.run {
                alertTitle = localized("同步成功")
                alertMessage = localized("書庫、來源配置與替換規則已更新")
                showAlert = true
            }
        } catch {
            presentError(error)
        }
    }

    private func runDeleteRemoteData() async {
        // Off first: a sync on the way to the background would upload it all again,
        // mid-deletion or right after.
        await MainActor.run { gs.iCloudAutoSync = false }
        do {
            try await manager.deleteRemoteData()
            await MainActor.run {
                alertTitle = localized("已刪除 iCloud 上的同步資料")
                alertMessage = localized("這台裝置的自動同步已關閉。")
                showAlert = true
            }
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        Task { @MainActor in
            alertTitle = localized("操作失敗")
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

#Preview {
    NavigationStack {
        ICloudSyncView()
    }
}
