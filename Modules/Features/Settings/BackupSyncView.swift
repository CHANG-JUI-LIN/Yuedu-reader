import SwiftUI

struct BackupSyncView: View {
    @StateObject private var iCloudManager = ICloudSyncManager.shared
    @StateObject private var webDAVManager = WebDAVManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ICloudSyncView()
                    } label: {
                        syncRow(
                            icon: "icloud.fill",
                            title: localized("iCloud 同步"),
                            detail: iCloudManager.statusTitle(isAppSignedIn: true)
                        )
                    }

                    NavigationLink {
                        WebDAVSyncView()
                    } label: {
                        syncRow(
                            icon: "icloud.and.arrow.up.fill",
                            title: localized("WebDAV 同步"),
                            detail: webDAVDetail
                        )
                    }
                } header: {
                    Text(localized("備份與同步方式"))
                } 
                .interfaceSectionSurface()
            }
            .navigationTitle(localized("備份與同步"))
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
                _ = await iCloudManager.refreshAccountStatus()
            }
        }
    }

    private var webDAVDetail: String {
        if webDAVManager.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized("尚未設定伺服器")
        }
        return webDAVManager.lastSyncDate == nil
            ? localized("已設定，尚未同步")
            : localized("已設定")
    }

    private func syncRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: icon)
                .foregroundColor(DSColor.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .foregroundColor(DSColor.textPrimary)
                Text(detail)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }
}

#Preview {
    BackupSyncView()
}

