import FirebaseFunctions
import SwiftUI

/// Collects an email from users who want to join the TestFlight beta. The
/// request is written to Firestore `testflightRequests` by the
/// `requestTestFlightAccess` callable; the developer adds the tester in App
/// Store Connect and Apple sends the invite email.
struct TestFlightApplyView: View {
    private let testFlightJoinURL = URL(string: "https://testflight.apple.com/join/7hvbzYC1")

    @State private var email = ""
    @State private var state: TestFlightApplyState = .idle
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: DSSpacing.sm) {
                    Image(systemName: "testtube.2")
                        .font(DSFont.fixed(size: 40))
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                    Text(localized("搶先體驗新功能"))
                        .font(DSFont.title3.weight(.semibold))
                    Text(localized("加入 TestFlight 測試版，搶先體驗新功能並協助我們改善 Yuedu Reader。申請後我們會寄邀請郵件到你填寫的郵箱。"))
                        .font(DSFont.footnote)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
            }

            if state == .submitted {
                submittedRow
            } else {
                Section {
                    TextField(localized("輸入你的郵箱"), text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        .disabled(state == .submitting)

                    Button {
                        submit()
                    } label: {
                        Group {
                            if state == .submitting {
                                ProgressView()
                            } else {
                                Text(localized("申請加入"))
                                    .font(DSFont.bodyBold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .submitting)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.destructive)
                        .accessibilityLabel(errorMessage)
                }
            }

            Section {
                Link(destination: testFlightJoinURL) {
                    HStack {
                        Label(localized("使用公開連結加入"), systemImage: "arrow.up.right.square")
                            .foregroundColor(DSColor.textPrimary)
                            .labelStyle(IconConsistentLabelStyle())
                        Spacer(minLength: 12)
                        Text("testflight.apple.com/join/7hvbzYC1")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
            } footer: {
                Text(localized("不需要申請郵箱的話，也可以直接用公開連結加入測試。"))
            }
        }
        .navigationTitle(localized("加入 TestFlight"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    private var submittedRow: some View {
        Section {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(DSFont.fixed(size: 44))
                    .foregroundStyle(DSColor.success)
                    .accessibilityHidden(true)
                Text(localized("申請已送出"))
                    .font(DSFont.title3.weight(.semibold))
                Text(localized("我們會將 TestFlight 邀請寄到你的郵箱，請留意收件匣。"))
                    .font(DSFont.footnote)
                    .foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.lg)
        }
    }

    private func submit() {
        guard isValidEmail(email) else {
            errorMessage = localized("請輸入有效的郵箱地址")
            return
        }
        errorMessage = nil
        state = .submitting
        Task {
            do {
                try await TestFlightAccessService.requestAccess(email: email)
                state = .submitted
            } catch {
                state = .idle
                errorMessage = localized("無法送出申請，請檢查網路後再試")
            }
        }
    }

    /// Mirrors the backend `normalizeTestFlightEmail` check so a clearly
    /// invalid address never leaves the device. The server remains the
    /// authority; this is a UX guard, not a security boundary.
    private func isValidEmail(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 254
            && trimmed.range(of: #"^[^\s@/]+@[^\s@/]+\.[^\s@/]+$"#, options: .regularExpression) != nil
    }
}

private enum TestFlightApplyState {
    case idle
    case submitting
    case submitted
}

enum TestFlightAccessServiceError: Error {
    case invalidResponse
}

/// Single entry point for submitting a TestFlight access request. Goes through
/// the Firebase callable so email validation and idempotency stay server-side.
enum TestFlightAccessService {
    private static let functionsRegion = "asia-east1"

    static func requestAccess(email: String) async throws {
        let result = try await Functions.functions(region: functionsRegion)
            .httpsCallable("requestTestFlightAccess")
            .call(["email": email])
        guard let payload = result.data as? [String: Any],
              payload["alreadySubmitted"] is Bool else {
            throw TestFlightAccessServiceError.invalidResponse
        }
    }
}

#Preview {
    NavigationStack {
        TestFlightApplyView()
    }
}
