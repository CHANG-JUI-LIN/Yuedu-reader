import CloudKit
import SwiftUI

struct ICloudSyncView: View {
    @StateObject private var manager = ICloudSyncManager.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private var iCloudReady: Bool { manager.accountStatus == .available }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                autoSyncSection
                actionsSection
                statusSection
            }
            .navigationTitle(localized("iCloud 同步"))
            .toolbarTitleDisplayMode(.inline)
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
    }

    private var accountSection: some View {
        Section(header: Text(localized("帳號狀態"))) {
            HStack {
                Label(manager.statusTitle(isAppSignedIn: true), systemImage: statusIcon)
                    .foregroundColor(statusColor)
                Spacer()
                if iCloudReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            if !iCloudReady {
                Text(localized("請確認系統設定中已登入 iCloud，且 iCloud Drive/CloudKit 可用"))
                    .font(.footnote)
                    .foregroundColor(DSColor.textSecondary)
            }
        }
    }

    private var autoSyncSection: some View {
        Section {
            Toggle(localized("自動同步"), isOn: $gs.iCloudAutoSync)
                .tint(DSColor.accent)
                .onChange(of: gs.iCloudAutoSync) { _, on in
                    if on, iCloudReady { Task { try? await manager.sync(reason: "toggle-on") } }
                }
        } footer: {
            Text(localized("開啟後，App 啟動與切到背景時會自動與 iCloud 合併同步（書庫、書源、替換規則與書檔）。多台裝置會智慧合併，不會互相覆蓋。"))
        }
    }

    private var actionsSection: some View {
        Section(header: Text(localized("操作"))) {
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
        iCloudReady ? "icloud.fill" : "exclamationmark.icloud"
    }

    private var statusColor: Color {
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
                alertMessage = localized("書庫、書源與替換規則已更新")
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
