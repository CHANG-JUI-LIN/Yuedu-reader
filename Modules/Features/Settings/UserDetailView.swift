import CloudKit
import SwiftUI
import PhotosUI
import UIKit

struct UserDetailView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var gs = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var firestoreSync = FirestoreSyncManager.shared
    @State private var showLogin = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarErrorMessage: String?
    @State private var showSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountErrorMessage: String?
    @State private var showReadingStats = false
    @State private var showPaywall = false
    @State private var showRenameAlert = false
    @State private var draftDisplayName = ""
    @State private var showDeletePasswordAlert = false
    @State private var deletePassword = ""
    @ObservedObject private var auth = FirebaseAuthManager.shared
    @State private var isLinking = false
    @State private var linkErrorMessage: String?
    @State private var showLinkEmailAlert = false
    @State private var linkEmail = ""
    @State private var linkPassword = ""

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    AccountAvatarView(size: 100)

                    if gs.isLoggedIn {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            Label(localized("修改頭像"), systemImage: "photo")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .disabled(isSigningOut)
                    }

                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: syncStatusIcon)
                            Text(gs.isLoggedIn ? firestoreSync.statusTitle : localized("登入後可同步進度"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(syncStatusColor.opacity(0.1))
                        .foregroundColor(syncStatusColor)
                        .clipShape(Capsule())

                        if gs.isLoggedIn, let date = firestoreSync.lastSyncDate {
                            Text("\(localized("上次同步")) \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        if !gs.isLoggedIn {
                            Text(localized("登入後可跨設備同步書籍與進度"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            Button {
                                showLogin = true
                            } label: {
                                Text(localized("登入 / 註冊"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.top, 8)
                        }

                        if let avatarErrorMessage {
                            Text(avatarErrorMessage)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.white)
            }

            Section {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(DSColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Yuedu Pro")
                                .foregroundColor(.primary)
                            Text(subscriptionStore.isProActive
                                 ? localized("已訂閱，感謝支持")
                                 : localized("解鎖高級個人化"))
                                .font(DSFont.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        if subscriptionStore.isProActive {
                            Text(localized("已啟用"))
                                .font(DSFont.caption.weight(.semibold))
                                .foregroundStyle(DSColor.success)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section(header: Text(localized("閱讀工具"))) {
                Button {
                    showReadingStats = true
                } label: {
                    HStack {
                        Label(localized("閱讀統計"), systemImage: "chart.bar.fill")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }

            if gs.isLoggedIn {
                Section(header: Text(localized("帳號資訊"))) {
                    Button {
                        draftDisplayName = gs.accountDisplayName
                        showRenameAlert = true
                    } label: {
                        HStack {
                            Text(localized("用戶名"))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(gs.accountDisplayName.isEmpty ? localized("未設定") : gs.accountDisplayName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                    .disabled(isSigningOut || isDeletingAccount)

                    if !gs.accountEmail.isEmpty {
                        HStack {
                            Text(localized("帳號"))
                            Spacer()
                            Text(gs.accountEmail)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section {
                    linkRow(title: "Google", providerID: "google.com")
                    linkRow(title: "Apple", providerID: "apple.com")
                    linkRow(title: localized("電子郵件"), providerID: "password")

                    if let linkErrorMessage {
                        Text(linkErrorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text(localized("連結登入方式"))
                } footer: {
                    Text(localized("連結後可用任一方式登入同一個帳號"))
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirmation = true
                    } label: {
                        HStack {
                            Text(localized("退出當前帳號"))
                            Spacer()
                            if isSigningOut {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSigningOut)
                    .confirmationDialog(
                        localized("登出帳號"),
                        isPresented: $showSignOutConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(localized("登出"), role: .destructive) {
                            performSignOut(revokeGoogleAccess: true)
                        }

                        Button(localized("取消"), role: .cancel) {}
                    } message: {
                        Text(localized("登出後此裝置會停止使用目前帳號同步。"))
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteAccountConfirmation = true
                    } label: {
                        HStack {
                            Text(localized("刪除帳號"))
                            Spacer()
                            if isDeletingAccount {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isDeletingAccount || isSigningOut)
                    .confirmationDialog(
                        localized("刪除帳號"),
                        isPresented: $showDeleteAccountConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(localized("永久刪除帳號"), role: .destructive) {
                            performAccountDeletion()
                        }

                        Button(localized("取消"), role: .cancel) {}
                    } message: {
                        Text(localized("刪除帳號將登出此裝置，並永久刪除已同步的書庫、書源、替換規則、RSS 與頭像資料。此操作無法復原。"))
                    }

                    if let deleteAccountErrorMessage {
                        Text(deleteAccountErrorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                } footer: {
                    Text(localized("刪除帳號會移除您的登入資訊並清除已上傳的同步資料，且無法復原。儲存在本機的內容檔不會被刪除。"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localized("個人資料"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showReadingStats) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReadingStatsView()
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionStore)
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView {
                showLogin = false
            }
        }
        .alert(localized("修改用戶名"), isPresented: $showRenameAlert) {
            TextField(localized("用戶名"), text: $draftDisplayName)
            Button(localized("儲存")) {
                gs.updateAccountDisplayName(draftDisplayName)
                Task {
                    try? await firestoreSync.upsertCurrentProfile()
                }
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("這個名稱只會顯示在此裝置上。"))
        }
        .onChange(of: selectedAvatarItem) { _, newItem in
            Task {
                await updateAvatar(from: newItem)
            }
        }
        .alert(localized("確認刪除帳號"), isPresented: $showDeletePasswordAlert) {
            SecureField(localized("請輸入密碼"), text: $deletePassword)
                .textInputAutocapitalization(.never)
            Button(localized("永久刪除帳號"), role: .destructive) {
                let password = deletePassword
                deletePassword = ""
                runAccountDeletion(emailPassword: password)
            }
            Button(localized("取消"), role: .cancel) { deletePassword = "" }
        } message: {
            Text(localized("請輸入密碼以確認刪除帳號"))
        }
        .alert(localized("連結電子郵件"), isPresented: $showLinkEmailAlert) {
            TextField(localized("請輸入您的 Email"), text: $linkEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            SecureField(localized("請輸入密碼"), text: $linkPassword)
                .textInputAutocapitalization(.never)
            Button(localized("連結")) {
                let email = linkEmail
                let password = linkPassword
                linkEmail = ""
                linkPassword = ""
                performLink { try await auth.linkEmail(email: email, password: password) }
            }
            Button(localized("取消"), role: .cancel) {
                linkEmail = ""
                linkPassword = ""
            }
        } message: {
            Text(localized("連結後可用任一方式登入同一個帳號"))
        }
    }

    @ViewBuilder
    private func linkRow(title: String, providerID: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if auth.linkedProviderIDs.contains(providerID) {
                Label(localized("已連結"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)
            } else if isLinking {
                ProgressView()
            } else {
                Button(localized("連結")) { startLink(providerID) }
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private func startLink(_ providerID: String) {
        if providerID == "password" {
            linkErrorMessage = nil
            showLinkEmailAlert = true
            return
        }
        performLink {
            if providerID == "google.com" {
                try await auth.linkGoogle()
            } else {
                try await auth.linkApple()
            }
        }
    }

    private func performLink(_ operation: @escaping () async throws -> Void) {
        isLinking = true
        linkErrorMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                linkErrorMessage = AuthErrorReporter.describe(error)
            }
            isLinking = false
        }
    }

    private var syncStatusIcon: String {
        guard gs.isLoggedIn else { return "cloud.slash" }
        if case .failed = firestoreSync.state {
            return "exclamationmark.icloud"
        }
        return "cloud.fill"
    }

    private var syncStatusColor: Color {
        guard gs.isLoggedIn else { return .blue }
        switch firestoreSync.state {
        case .synced, .syncing:
            return .blue
        case .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func performSignOut(revokeGoogleAccess: Bool) {
        isSigningOut = true
        Task {
            do {
                try await FirebaseAuthManager.shared.signOut(revokeGoogleAccess: revokeGoogleAccess)
                dismiss()
            } catch {
                avatarErrorMessage = error.localizedDescription
            }
            isSigningOut = false
        }
    }

    private func performAccountDeletion() {
        // Email accounts need the password to re-authenticate before deletion;
        // Google/Apple re-authenticate interactively inside deleteAccount().
        if FirebaseAuthManager.shared.deletionRequiresPassword {
            showDeletePasswordAlert = true
        } else {
            runAccountDeletion(emailPassword: nil)
        }
    }

    private func runAccountDeletion(emailPassword: String?) {
        isDeletingAccount = true
        deleteAccountErrorMessage = nil

        Task {
            do {
                try await FirebaseAuthManager.shared.deleteAccount(emailPassword: emailPassword)
                dismiss()
            } catch {
                deleteAccountErrorMessage = error.localizedDescription
            }
            isDeletingAccount = false
        }
    }

    @MainActor
    private func updateAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let avatarData = normalizedAvatarData(from: data) else {
                avatarErrorMessage = localized("無法讀取頭像圖片")
                return
            }
            avatarErrorMessage = nil
            gs.updateAccountAvatar(data: avatarData)
            _ = try await firestoreSync.uploadAvatar(data: avatarData)
        } catch {
            avatarErrorMessage = error.localizedDescription
        }
    }

    private func normalizedAvatarData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 512
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longestSide, 1))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

struct AccountAvatarView: View {
    @ObservedObject private var gs = GlobalSettings.shared
    let size: CGFloat

    var body: some View {
        Group {
            if let data = gs.accountAvatarData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = URL(string: gs.accountPhotoURL), !gs.accountPhotoURL.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.blue)
                            .padding(size * 0.08)
                    }
                }
            } else {
                Image(systemName: gs.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(gs.isLoggedIn ? .blue : .secondary)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        UserDetailView()
            .environmentObject(SubscriptionStore.shared)
    }
}
