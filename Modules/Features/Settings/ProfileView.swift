import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.openURL) private var openURL
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showSourceList = false
    @State private var showDownloadManager = false
    @State private var showReplaceRules = false
    @State private var showICloudSync = false
    @State private var showWebDAVSync = false
    @State private var showLanServer = false
    @State private var showLegadoMigration = false
    @State private var showTTSSettings = false
    private let feedbackEmail = "r3212239269@gmail.com"

    private var feedbackMailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: localized("yuedu app 反饋"))
        ]
        return components.url
    }

    private var appLanguageFooter: String {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let template = localized("跟隨系統語言。可在「設定 → %@ → 語言」單獨設定")
        return String(format: template, appName)
    }

    var body: some View {
        NavigationStack {
                Form {
                    Section {
                        NavigationLink(destination: UserDetailView()) {
                            AccountRowContent()
                        }
                    }
                    // ── App Language ──
                    Section(
                        header: Text(localized("App 語言")),
                        footer: Text(appLanguageFooter)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    ) {
                        DSSettingsRow(
                            icon: "globe",
                            title: localized("語言"),
                            action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        )
                    }

                    // ── Book Source Management ──
                    Section(header: Text(localized("書源管理"))) {
                        DSSettingsRow(
                            icon: "books.vertical.fill",
                            title: localized("管理書源"),
                            action: { showSourceList = true }
                        )

                        DSSettingsRow(
                            icon: "arrow.down.circle.fill",
                            title: localized("下載管理"),
                            detail: "\(downloadedBooksCount) \(localized("本"))",
                            action: { showDownloadManager = true }
                        )


                        NavigationLink(destination: NetworkSettingsView()) {
                            Label(localized("網路設定"), systemImage: "network")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                    }

                    // ── Reading Tools ──
                    Section(header: Text(localized("閱讀工具"))) {
                        DSSettingsRow(
                            icon: "waveform",
                            title: localized("語音朗讀設定"),
                            action: { showTTSSettings = true }
                        )
                        
                        DSSettingsRow(
                            icon: "text.magnifyingglass",
                            title: localized("替換規則"),
                            action: { showReplaceRules = true }
                        )

                    }

                    // ── Data Management ──
                    Section(header: Text(localized("資料管理"))) {
                        DSSettingsRow(
                            icon: "icloud.fill",
                            title: localized("iCloud 同步"),
                            action: { showICloudSync = true }
                        )
                        DSSettingsRow(
                            icon: "icloud.and.arrow.up.fill",
                            title: localized("WebDAV 同步"),
                            action: { showWebDAVSync = true }
                        )
                        DSSettingsRow(
                            icon: "wifi",
                            title: localized("局域網服務"),
                            action: { showLanServer = true }
                        )
                        DSSettingsRow(
                            icon: "arrow.down.doc.fill",
                            title: localized("Legado 資料遷移"),
                            action: { showLegadoMigration = true }
                        )
                    }

                    // ── About ──
                    Section(header: Text(localized("關於"))) {
                        HStack {
                            Text(localized("版本"))
                            Spacer()
                            Text("1.0.0").foregroundColor(DSColor.textSecondary)
                        }
                        HStack {
                            Text(localized("支援格式"))
                            Spacer()
                            Text(localized("TXT、EPUB、Web、書源")).foregroundColor(DSColor.textSecondary)
                        }
                        Button {
                            if let url = feedbackMailURL {
                                openURL(url)
                            }
                        } label: {
                            HStack {
                                Text(localized("反饋"))
                                Spacer()
                                    .foregroundColor(DSColor.accent)
                                Image(systemName: "envelope.fill")
                                    .font(.caption)
                                    .foregroundColor(DSColor.accent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            .navigationTitle(localized("設定"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .sheet(isPresented: $showSourceList) {
                BookSourceListView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showDownloadManager) {
                DownloadManagementView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showReplaceRules) {
                ReplaceRuleListView()
            }
            .sheet(isPresented: $showICloudSync) {
                ICloudSyncView()
            }
            .sheet(isPresented: $showWebDAVSync) {
                WebDAVSyncView()
            }
            .sheet(isPresented: $showLanServer) {
                LanServerView().environmentObject(store)
            }
            .sheet(isPresented: $showLegadoMigration) {
                LegadoMigrationView().environmentObject(store)
            }
            .sheet(isPresented: $showTTSSettings) {
                TTSSettingsView()
            }
        }
    }

    private var downloadedBooksCount: Int {
        store.books.filter { $0.isOnline && $0.offlineDownloadState == .available }.count
    }

    @ViewBuilder func AccountRowContent() -> some View {
        HStack(spacing: 15) {
            AccountAvatarView(size: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(gs.isLoggedIn ? (gs.accountDisplayName.isEmpty ? localized("已登入") : gs.accountDisplayName) : localized("尚未登入"))
                    .font(.headline)
                Text(gs.accountSubtitle)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }

}

#Preview {
    SettingsView()
        .environmentObject(BookStore())
}
