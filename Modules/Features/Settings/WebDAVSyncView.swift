import SwiftUI
import Combine

struct WebDAVSyncView: View {

    @StateObject private var manager = WebDAVManager.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showConflictAlert = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                actionsSection
                statusSection
            }
            .navigationTitle(localized("WebDAV 同步"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
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
                Button(localized("使用雲端備份"), role: .destructive) {
                    Task { try? await manager.resolveConflict(keepRemote: true) }
                }
                Button(localized("保留本地資料"), role: .cancel) {
                    Task { try? await manager.resolveConflict(keepRemote: false) }
                }
            } message: {
                if let c = manager.pendingConflict {
                    Text(conflictMessage(c))
                }
            }
        }
    }

    private func conflictMessage(_ c: SyncConflict) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short; fmt.timeStyle = .short
        let remoteDate = fmt.string(from: c.remote.backupDate)
        let localDate  = fmt.string(from: c.localLastSync)
        return localized("雲端備份來自裝置「\(c.remote.deviceName)」（\(remoteDate)）。本裝置上次同步：\(localDate)。請選擇要使用哪個版本。")
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section(header: Text(localized("伺服器設定"))) {
            HStack {
                Text(localized("網址"))
                    .foregroundColor(DSColor.textSecondary)
                TextField("https://example.com/dav", text: $manager.serverUrl)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }
            HStack {
                Text(localized("帳號"))
                    .foregroundColor(DSColor.textSecondary)
                TextField(localized("使用者名稱"), text: $manager.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            HStack {
                Text(localized("密碼"))
                    .foregroundColor(DSColor.textSecondary)
                SecureField(localized("密碼"), text: $manager.password)
            }
        }
    }

    private var actionsSection: some View {
        Section(header: Text(localized("操作"))) {
            Button {
                Task { await testConnection() }
            } label: {
                Label(localized("測試連線"), systemImage: "network")
                    .foregroundColor(DSColor.accent)
            }

            Button {
                Task { await runBackup() }
            } label: {
                Label(localized("備份到雲端"), systemImage: "icloud.and.arrow.up")
                    .foregroundColor(DSColor.accent)
            }

            Button {
                Task { await runRestore() }
            } label: {
                Label(localized("從雲端還原"), systemImage: "icloud.and.arrow.down")
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
                    .font(DSFont.footnote)
            }
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

    // MARK: - Actions

    private func testConnection() async {
        guard validateSettings() else { return }
        let ok = await manager.testConnection()
        await MainActor.run {
            alertTitle   = ok ? localized("連線成功") : localized("連線失敗")
            alertMessage = ok
                ? localized("已成功連線至 WebDAV 伺服器")
                : localized("無法連線，請確認網址、帳號及密碼")
            showAlert = true
        }
    }

    private func runBackup() async {
        guard validateSettings() else { return }
        do {
            try await manager.backup()
            await MainActor.run {
                alertTitle   = localized("備份成功")
                alertMessage = localized("資料已成功備份至雲端")
                showAlert    = true
            }
        } catch {
            presentError(error)
        }
    }

    private func runRestore() async {
        guard validateSettings() else { return }
        do {
            try await manager.restore()
            await MainActor.run {
                alertTitle   = localized("還原成功")
                alertMessage = localized("書源已立即更新，書庫和替換規則將在重啟 App 後完全生效")
                showAlert    = true
            }
        } catch {
            presentError(error)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func validateSettings() -> Bool {
        guard !manager.serverUrl.isEmpty else {
            alertTitle   = localized("設定不完整")
            alertMessage = localized("請填寫伺服器網址")
            showAlert    = true
            return false
        }
        return true
    }

    private func presentError(_ error: Error) {
        Task { @MainActor in
            alertTitle   = localized("操作失敗")
            alertMessage = error.localizedDescription
            showAlert    = true
        }
    }
}
