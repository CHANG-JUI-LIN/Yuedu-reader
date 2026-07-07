import SwiftUI
import UIKit

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
    @State private var showNetworkSettings = false
    private let feedbackEmail = "r3212239269@gmail.com"
    private let officialQQGroupID = "1107613783"
    private let telegramGroupURL = URL(string: "https://t.me/+ZWmmgMwwJ3JiN2Rl")
    private let privacyPolicyURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/privacy.html")
    private let userAgreementURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/terms.html")
    private let paidTermsURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/paid-terms.html")

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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
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

                    Section(header: Text(localized("書架顯示"))) {
                        Picker(selection: $gs.bookshelfGridColumnCount) {
                            ForEach(GlobalSettings.bookshelfGridColumnCountOptions, id: \.self) { columnCount in
                                Text(String(format: localized("%d 欄"), columnCount))
                                    .tag(columnCount)
                            }
                        } label: {
                            Label(localized("每列欄數"), systemImage: "square.grid.3x3.fill")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .pickerStyle(.menu)
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


                        DSSettingsRow(
                            icon: "network",
                            title: localized("網路設定"),
                            action: { showNetworkSettings = true }
                        )
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
                        NavigationLink {
                            AboutSupportView(
                                appVersion: appVersion,
                                feedbackEmail: feedbackEmail,
                                officialQQGroupID: officialQQGroupID,
                                feedbackMailURL: feedbackMailURL,
                                telegramGroupURL: telegramGroupURL,
                                privacyPolicyURL: privacyPolicyURL,
                                userAgreementURL: userAgreementURL,
                                paidTermsURL: paidTermsURL
                            )
                        } label: {
                            HStack {
                                Label(localized("關於 Yuedu Reader"), systemImage: "info.circle.fill")
                                    .foregroundColor(DSColor.textPrimary)
                                    .labelStyle(IconConsistentLabelStyle())
                                Spacer(minLength: 12)
                                Text(appVersion)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    }
                }
            .navigationTitle(localized("設定"))
            .toolbarTitleDisplayModeInlineLarge()
            .sheet(isPresented: $showSourceList) {
                BookSourceListView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showDownloadManager) {
                DownloadManagementView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showNetworkSettings) {
                NetworkSettingsView()
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

private struct AboutSupportView: View {
    @Environment(\.openURL) private var openURL
    @State private var showCopiedQQGroup = false
    let appVersion: String
    let feedbackEmail: String
    let officialQQGroupID: String
    let feedbackMailURL: URL?
    let telegramGroupURL: URL?
    let privacyPolicyURL: URL?
    let userAgreementURL: URL?
    let paidTermsURL: URL?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("YueduLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 82, height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)

                    Text(localized("閱讀"))
                        .font(.title3.weight(.semibold))

                    Text(localized("聯絡方式、版本資訊與政策協議"))
                        .font(.footnote)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Section(header: Text(localized("版本資訊"))) {
                HStack {
                    Label(localized("版本"), systemImage: "number")
                        .foregroundColor(DSColor.textPrimary)
                        .labelStyle(IconConsistentLabelStyle())
                    Spacer(minLength: 12)
                    Text(appVersion)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }

            Section(header: Text(localized("聯絡方式"))) {
                actionRow(
                    icon: "envelope.fill",
                    title: localized("電子郵件"),
                    detail: feedbackEmail,
                    trailingIcon: "arrow.up.right"
                ) {
                    if let url = feedbackMailURL {
                        openURL(url)
                    }
                }

                actionRow(
                    icon: "number.circle.fill",
                    title: localized("官方 QQ 群"),
                    detail: officialQQGroupID,
                    trailingIcon: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = officialQQGroupID
                    showCopiedQQGroup = true
                }

                actionRow(
                    icon: "paperplane.fill",
                    title: localized("Telegram 群"),
                    detail: "t.me",
                    trailingIcon: "arrow.up.right"
                ) {
                    if let url = telegramGroupURL {
                        openURL(url)
                    }
                }
            }

            Section(
                header: Text(localized("政策與協議")),
                footer: Text(localized("使用書源、第三方服務與未來付費功能前，請先閱讀相關條款。"))
            ) {
                actionRow(
                    icon: "hand.raised.fill",
                    title: localized("隱私權政策"),
                    detail: localized("本機資料、同步與第三方來源說明"),
                    trailingIcon: "arrow.up.right"
                ) {
                    if let url = privacyPolicyURL {
                        openURL(url)
                    }
                }

                actionRow(
                    icon: "doc.text.fill",
                    title: localized("使用者協議"),
                    detail: localized("使用規則、第三方內容與責任邊界"),
                    trailingIcon: "arrow.up.right"
                ) {
                    if let url = userAgreementURL {
                        openURL(url)
                    }
                }

                actionRow(
                    icon: "creditcard.fill",
                    title: localized("付費服務條款"),
                    detail: localized("未來付費功能、訂閱、退款與 Apple 付款規則"),
                    trailingIcon: "arrow.up.right"
                ) {
                    if let url = paidTermsURL {
                        openURL(url)
                    }
                }
            }
        }
        .navigationTitle(localized("關於 Yuedu Reader"))
        .toolbarTitleDisplayMode(.inline)
        .alert(localized("已複製"), isPresented: $showCopiedQQGroup) {
            Button(localized("好"), role: .cancel) {}
        } message: {
            Text(String(format: localized("已複製 QQ 群號：%@"), officialQQGroupID))
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        detail: String,
        trailingIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundColor(DSColor.textPrimary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundColor(DSColor.textPrimary)
                    Text(detail)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Image(systemName: trailingIcon)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView()
        .environmentObject(BookStore())
        .environmentObject(SubscriptionStore.shared)
}
