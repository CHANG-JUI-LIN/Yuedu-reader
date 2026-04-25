import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.openURL) private var openURL
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showSourceList = false
    @State private var showDownloadManager = false
    @State private var showReplaceRules = false
    @State private var showReadingStats = false
    @State private var showWebDAVSync = false
    @State private var showLanServer = false
    @State private var showRSSReader = false
    @State private var showLegadoMigration = false
    @State private var showTTSSettings = false

    private let feedbackEmail = "r3212239269@gmail.com"

    private var feedbackMailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "yuedu app 反饋")
        ]
        return components.url
    }

    private var appLanguageFooter: String? {
        guard gs.appLanguage == .systemLanguage else { return nil }
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let template = gs.t("跟隨系統語言。可在「設定 → %@ → 語言」單獨設定")
        return String(format: template, appName)
    }

    var body: some View {
        NavigationView {
            AdaptiveContentContainer(maxWidth: 760) {
                Form {
                    // ── App 語言 ──
                    Section(
                        header: Text(gs.t("App 語言")),
                        footer: appLanguageFooter.map {
                            Text($0)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    ) {
                        HStack {
                            Text(gs.t("語言"))
                            Spacer()
                            Picker("", selection: $gs.appLanguage) {
                                ForEach(AppLanguage.allCases, id: \.self) { lang in
                                    Text(lang.rawValue).tag(lang)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    // ── 書源管理 ──
                    Section(header: Text(gs.t("書源管理"))) {
                        DSSettingsRow(
                            icon: "books.vertical.fill",
                            title: gs.t("管理書源"),
                            action: { showSourceList = true }
                        )

                        DSSettingsRow(
                            icon: "arrow.down.circle.fill",
                            title: gs.t("下載管理"),
                            detail: "\(downloadedBooksCount) \(gs.t("本"))",
                            action: { showDownloadManager = true }
                        )

                        DSSettingsRow(
                            icon: "text.magnifyingglass",
                            title: gs.t("替換規則"),
                            action: { showReplaceRules = true }
                        )
                    }

                    // ── 閱讀工具 ──
                    Section(header: Text(gs.t("閱讀工具"))) {
                        DSSettingsRow(
                            icon: "chart.bar.fill",
                            title: gs.t("閱讀統計"),
                            action: { showReadingStats = true }
                        )
                        DSSettingsRow(
                            icon: "dot.radiowaves.left.and.right",
                            title: gs.t("RSS 訂閱"),
                            action: { showRSSReader = true }
                        )
                        DSSettingsRow(
                            icon: "waveform",
                            title: gs.t("語音朗讀設定"),
                            action: { showTTSSettings = true }
                        )
                    }

                    // ── 資料管理 ──
                    Section(header: Text(gs.t("資料管理"))) {
                        DSSettingsRow(
                            icon: "icloud.and.arrow.up.fill",
                            title: gs.t("WebDAV 同步"),
                            action: { showWebDAVSync = true }
                        )
                        DSSettingsRow(
                            icon: "wifi",
                            title: gs.t("局域網服務"),
                            action: { showLanServer = true }
                        )
                        DSSettingsRow(
                            icon: "arrow.down.doc.fill",
                            title: gs.t("Legado 資料遷移"),
                            action: { showLegadoMigration = true }
                        )
                    }

                    // ── 關於 ──
                    Section(header: Text(gs.t("關於"))) {
                        HStack {
                            Text(gs.t("版本"))
                            Spacer()
                            Text("1.0.0").foregroundColor(DSColor.textSecondary)
                        }
                        HStack {
                            Text(gs.t("支援格式"))
                            Spacer()
                            Text(gs.t("TXT、EPUB、Web、書源")).foregroundColor(DSColor.textSecondary)
                        }
                        Button {
                            if let url = feedbackMailURL {
                                openURL(url)
                            }
                        } label: {
                            HStack {
                                Text(gs.t("反饋"))
                                Spacer()
                                Image(systemName: "envelope.fill")
                                    .font(.caption)
                                    .foregroundColor(DSColor.accent)
                                Text(feedbackEmail)
                                    .foregroundColor(DSColor.accent)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(gs.t("設定"))
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showSourceList) {
                AdaptiveSheetContainer(maxWidth: 820) {
                    BookSourceListView()
                        .environmentObject(store)
                }
            }
            .sheet(isPresented: $showDownloadManager) {
                AdaptiveSheetContainer(maxWidth: 820) {
                    DownloadManagementView()
                        .environmentObject(store)
                }
            }
            .sheet(isPresented: $showReplaceRules) {
                ReplaceRuleListView()
            }
            .sheet(isPresented: $showReadingStats) {
                AdaptiveSheetContainer(maxWidth: 760) {
                    ReadingStatsView()
                }
            }
            .sheet(isPresented: $showRSSReader) {
                AdaptiveSheetContainer(maxWidth: 820) {
                    RSSListView()
                }
            }
            .sheet(isPresented: $showWebDAVSync) {
                AdaptiveSheetContainer(maxWidth: 640) {
                    WebDAVSyncView()
                }
            }
            .sheet(isPresented: $showLanServer) {
                AdaptiveSheetContainer(maxWidth: 640) {
                    LanServerView().environmentObject(store)
                }
            }
            .sheet(isPresented: $showLegadoMigration) {
                AdaptiveSheetContainer(maxWidth: 760) {
                    LegadoMigrationView().environmentObject(store)
                }
            }
            .sheet(isPresented: $showTTSSettings) {
                NavigationView {
                    TTSSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button(gs.t("完成")) { showTTSSettings = false }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var downloadedBooksCount: Int {
        store.books.filter { $0.isOnline && $0.offlineDownloadState == .available }.count
    }
}
