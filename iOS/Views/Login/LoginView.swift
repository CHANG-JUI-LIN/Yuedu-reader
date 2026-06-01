import SwiftUI
import AuthenticationServices
import GoogleSignInSwift

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var emailMode: EmailAuthMode = .signIn
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared
    let onSignedIn: () -> Void

    init(onSignedIn: @escaping () -> Void = {}) {
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                        .padding(.top, 20)
                    Text(localized("歡迎回來"))
                        .font(.largeTitle.bold())

                    Text(localized("使用帳號同步書庫、進度與偏好"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(localized("取消")) {
                            dismiss()
                        }
                    }
                }

                VStack(spacing: 20) {
                    Picker(localized("帳號模式"), selection: $emailMode) {
                        Text(localized("登入")).tag(EmailAuthMode.signIn)
                        Text(localized("註冊")).tag(EmailAuthMode.signUp)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("電子郵件"))
                            .font(.caption.bold())
                            .foregroundColor(.secondary)

                        TextField(localized("請輸入您的 Email"), text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("密碼"))
                            .font(.caption.bold())
                            .foregroundColor(.secondary)

                        SecureField(localized("請輸入密碼"), text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }

                    Button {
                        signInWithEmail()
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(localized(emailMode.primaryButtonTitle))
                        }
                            .bold()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(!canSubmitEmail || isLoading ? Color.gray : Color.blue)
                            .cornerRadius(12)
                    }
                    .disabled(!canSubmitEmail || isLoading)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(spacing: 20) {
                    HStack {
                        Rectangle().frame(height: 0.5).foregroundColor(.secondary.opacity(0.5))
                        Text(localized("或使用以下方式")).font(.footnote).foregroundColor(.secondary)
                        Rectangle().frame(height: 0.5).foregroundColor(.secondary.opacity(0.5))
                    }

                    VStack(spacing: 20) {
                        Button {
                            handleGoogleSignIn()
                        } label: {
                            HStack(spacing: 0) {
                                Image("google_logo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 45, height: 45)
                                Text(localized("使用 Google 帳號登錄"))
                                    .font(.body.bold())
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .disabled(isLoading)

                        SignInWithAppleButton(.continue) { request in
                            FirebaseAuthManager.shared.prepareAppleRequest(request)
                        } onCompletion: { result in
                            handleAppleSignIn(result)
                        }
                            .signInWithAppleButtonStyle(.black)
                            .frame(height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .disabled(isLoading)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private var canSubmitEmail: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && password.count >= 6
    }

    private func signInWithEmail() {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return }
        guard normalizedEmail.contains("@") else {
            errorMessage = localized("請輸入有效的 Email")
            return
        }
        guard password.count >= 6 else {
            errorMessage = localized("密碼至少需要 6 個字元")
            return
        }

        errorMessage = nil
        isLoading = true
        Task {
            do {
                switch emailMode {
                case .signIn:
                    _ = try await FirebaseAuthManager.shared.signInWithEmail(email: normalizedEmail, password: password)
                case .signUp:
                    _ = try await FirebaseAuthManager.shared.signUpWithEmail(email: normalizedEmail, password: password)
                }
                completeSignIn()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            errorMessage = localized("無法取得登入視窗")
            return
        }

        errorMessage = nil
        isLoading = true
        Task {
            do {
                _ = try await FirebaseAuthManager.shared.signInWithGoogle(presenting: rootViewController)
                completeSignIn()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = localized("Apple 登入失敗")
                return
            }

            errorMessage = nil
            isLoading = true
            Task {
                do {
                    _ = try await FirebaseAuthManager.shared.signInWithApple(credential: credential)
                    completeSignIn()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        case .failure(let error):
            errorMessage = appleAuthorizationMessage(for: error)
            return
        }
    }

    private func completeSignIn() {
        onSignedIn()
        Task {
            await FirestoreSyncManager.shared.syncAfterSignIn()
        }
        dismiss()
    }

    private func appleAuthorizationMessage(for error: Error) -> String {
        guard let authorizationError = error as? ASAuthorizationError else {
            return error.localizedDescription
        }

        switch authorizationError.code {
        case .canceled:
            return localized("已取消 Apple 登錄")
        case .failed:
            return localized("Apple 登錄失敗，請稍後再試")
        case .invalidResponse:
            return localized("Apple 登錄回應無效")
        case .notHandled:
            return localized("Apple 登錄未完成，請重試")
        case .unknown:
            return localized("無法完成 Apple 登錄，請確認已開啟 Sign in with Apple 並使用支援的 Apple ID")
        default:
            return localized("Apple 登錄失敗")
        }
    }
}

private enum EmailAuthMode: String {
    case signIn
    case signUp

    var primaryButtonTitle: String {
        switch self {
        case .signIn: return "登入"
        case .signUp: return "註冊"
        }
    }
}


#Preview {
    LoginView()
}
