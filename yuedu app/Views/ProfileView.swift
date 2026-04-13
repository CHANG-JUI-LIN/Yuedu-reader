import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.openURL) private var openURL
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showSourceList = false
    @State private var showDownloadManager = false

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

    var body: some View {
        NavigationView {
            AdaptiveContentContainer(maxWidth: 760) {
                Form {
                    // ── App 語言 ──
                    Section(header: Text(gs.t("App 語言"))) {
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
        }
        .navigationViewStyle(.stack)
    }

    private var downloadedBooksCount: Int {
        store.books.filter { $0.isOnline && $0.offlineDownloadState == .available }.count
    }
}
