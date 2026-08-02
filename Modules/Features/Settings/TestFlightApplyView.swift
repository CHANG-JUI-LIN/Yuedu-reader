import FirebaseFunctions
import SwiftUI

/// Collects an email from users who want to join the TestFlight beta. The
/// request is written to Firestore `testflightRequests` by the
/// `requestTestFlightAccess` callable, which adds the tester to the configured
/// App Store Connect beta group and lets Apple send the invite email.
struct TestFlightApplyView: View {
    @State private var email = ""
    @State private var state: TestFlightApplyState = .idle
    @State private var submissionStatus: String?
    @State private var wasAlreadySubmitted = false
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
            .interfaceSectionSurface()

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
                .interfaceSectionSurface()
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.destructive)
                        .accessibilityLabel(errorMessage)
                }
                .interfaceSectionSurface()
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
                Text(submittedTitle)
                    .font(DSFont.title3.weight(.semibold))
                Text(submittedMessage)
                    .font(DSFont.footnote)
                    .foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.lg)
        }
        .interfaceSectionSurface()
    }

    private var submittedTitle: String {
        if wasAlreadySubmitted {
            return localized("已申請過 TestFlight")
        }
        if submissionStatus == "failed" {
            return localized("申請已記錄")
        }
        return localized("申請已送出")
    }

    private var submittedMessage: String {
        if wasAlreadySubmitted {
            return localized("每個 Pro 帳號只能申請一次；如果尚未收到邀請，請聯絡管理員。")
        }
        if submissionStatus == "failed" {
            return localized("申請已記錄，但邀請尚未完成，請聯絡管理員。")
        }
        return localized("我們會將 TestFlight 邀請寄到你的郵箱，請留意收件匣。")
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
                let result = try await TestFlightAccessService.requestAccess(email: email)
                submissionStatus = result.status
                wasAlreadySubmitted = result.alreadySubmitted
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

struct TestFlightAccessResult {
    let alreadySubmitted: Bool
    let status: String
}

/// Single entry point for submitting a TestFlight access request. Goes through
/// the Firebase callable so email validation and idempotency stay server-side.
enum TestFlightAccessService {
    private static let functionsRegion = "asia-east1"

    static func requestAccess(email: String) async throws -> TestFlightAccessResult {
        let result = try await Functions.functions(region: functionsRegion)
            .httpsCallable("requestTestFlightAccess")
            .call(["email": email])
        guard let payload = result.data as? [String: Any],
              let alreadySubmitted = payload["alreadySubmitted"] as? Bool,
              let status = payload["status"] as? String else {
            throw TestFlightAccessServiceError.invalidResponse
        }
        return TestFlightAccessResult(alreadySubmitted: alreadySubmitted, status: status)
    }
}

#Preview {
    NavigationStack {
        TestFlightApplyView()
    }
}
