import CloudKit
import SwiftUI

struct ICloudSyncView: View {
    @StateObject private var manager = ICloudSyncManager.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showConflictAlert = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                actionsSection
                statusSection
            }
            .navigationTitle(localized("iCloud 同步"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismiss() }
                }
            }
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
            .onChange(of: manager.pendingConflict != nil) { _, hasConflict in
                if hasConflict { showConflictAlert = true }
            }
            .alert(localized("偵測到備份衝突"), isPresented: $showConflictAlert) {
                Button(localized("使用 iCloud 備份"), role: .destructive) {
                    Task { try? await manager.resolveConflict(keepRemote: true) }
                }
                Button(localized("保留本地資料"), role: .cancel) {
                    Task { try? await manager.resolveConflict(keepRemote: false) }
                }
            } message: {
                if let conflict = manager.pendingConflict {
                    Text(conflictMessage(conflict))
                }
            }
            .task {
                _ = await manager.refreshAccountStatus()
            }
        }
    }

    private var accountSection: some View {
        Section(header: Text(localized("帳號狀態"))) {
            HStack {
                Label(
                    manager.statusTitle(isAppSignedIn: gs.isLoggedIn),
                    systemImage: statusIcon
                )
                .foregroundColor(statusColor)
                Spacer()
                if manager.accountStatus == .available {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            if !gs.isLoggedIn {
                Text(localized("請先登入帳號後再使用 iCloud 同步"))
                    .font(.footnote)
                    .foregroundColor(DSColor.textSecondary)
            } else if manager.accountStatus != .available {
                Text(localized("請確認系統設定中已登入 iCloud，且 iCloud Drive/CloudKit 可用"))
                    .font(.footnote)
                    .foregroundColor(DSColor.textSecondary)
            }
        }
    }

    private var actionsSection: some View {
        Section(header: Text(localized("操作"))) {
            Button {
                Task { await refreshStatus() }
            } label: {
                Label(localized("檢查 iCloud 狀態"), systemImage: "checkmark.icloud")
                    .foregroundColor(DSColor.accent)
            }

            Button {
                Task { await runBackup() }
            } label: {
                Label(localized("備份到 iCloud"), systemImage: "icloud.and.arrow.up")
                    .foregroundColor(DSColor.accent)
            }
            .disabled(!gs.isLoggedIn || manager.accountStatus != .available)

            Button {
                Task { await runRestore() }
            } label: {
                Label(localized("從 iCloud 還原"), systemImage: "icloud.and.arrow.down")
                    .foregroundColor(DSColor.accent)
            }
            .disabled(!gs.isLoggedIn || manager.accountStatus != .available)
        }
    }

    private var statusSection: some View {
        Section(header: Text(localized("狀態"))) {
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
                    .font(.footnote)
            }
        }
    }

    private var statusIcon: String {
        guard gs.isLoggedIn else { return "icloud.slash" }
        return manager.accountStatus == .available ? "icloud.fill" : "exclamationmark.icloud"
    }

    private var statusColor: Color {
        guard gs.isLoggedIn else { return .secondary }
        switch manager.accountStatus {
        case .available:
            return .blue
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
                    .font(.subheadline)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private func conflictMessage(_ conflict: ICloudSyncConflict) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let remoteDate = formatter.string(from: conflict.remote.backupDate)
        let localDate = conflict.localLastSync.map { formatter.string(from: $0) } ?? localized("從未同步")
        return String(
            format: localized("iCloud 備份來自裝置「%@」（%@）。本裝置上次同步：%@。請選擇要使用哪個版本。"),
            conflict.remote.deviceName,
            remoteDate,
            localDate
        )
    }

    private func refreshStatus() async {
        let status = await manager.refreshAccountStatus()
        await MainActor.run {
            alertTitle = status == .available ? localized("iCloud 可用") : localized("iCloud 無法使用")
            alertMessage = manager.statusTitle(isAppSignedIn: gs.isLoggedIn)
            showAlert = true
        }
    }

    private func runBackup() async {
        do {
            try await manager.backup()
            await MainActor.run {
                alertTitle = localized("備份成功")
                alertMessage = localized("資料已成功備份至 iCloud")
                showAlert = true
            }
        } catch {
            presentError(error)
        }
    }

    private func runRestore() async {
        do {
            try await manager.restore()
            await MainActor.run {
                alertTitle = localized("還原成功")
                alertMessage = localized("書源已立即更新，書庫和替換規則將在重啟 App 後完全生效")
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
    ICloudSyncView()
}
