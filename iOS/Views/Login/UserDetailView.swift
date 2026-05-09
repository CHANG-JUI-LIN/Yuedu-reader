import SwiftUI
import PhotosUI
import UIKit

struct UserDetailView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var gs = GlobalSettings.shared
    @State private var showLogin = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarErrorMessage: String?
    @State private var showSignOutConfirmation = false
    @State private var isSigningOut = false

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
                            Image(systemName: gs.isLoggedIn ? "icloud.fill" : "icloud.slash")
                            Text(gs.isLoggedIn ? localized("iCloud 同步已開啟") : localized("尚未開啟同步"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())

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

            if gs.isLoggedIn {
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
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localized("個人資料"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog(
            localized("登出帳號"),
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("登出"), role: .destructive) {
                performSignOut(revokeGoogleAccess: false)
            }

            if gs.accountProvider == "Google" {
                Button(localized("解除 Google 授權並登出"), role: .destructive) {
                    performSignOut(revokeGoogleAccess: true)
                }
            }

            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("登出後此裝置會停止使用目前帳號同步。"))
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView {
                showLogin = false
            }
        }
        .onChange(of: selectedAvatarItem) { _, newItem in
            Task {
                await updateAvatar(from: newItem)
            }
        }
    }

    private func performSignOut(revokeGoogleAccess: Bool) {
        isSigningOut = true
        gs.signOut(revokeGoogleAccess: revokeGoogleAccess) { _ in
            isSigningOut = false
            dismiss()
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
    }
}
