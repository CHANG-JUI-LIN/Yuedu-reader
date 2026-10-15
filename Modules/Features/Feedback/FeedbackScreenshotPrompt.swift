import SwiftUI
import UIKit

/// 截圖後顯示意見回饋入口: after a screenshot, a 問題回報 capsule floats over the bottom of the
/// screen, and opens 回饋與改進 with the screen already attached.
///
/// The capsule lives in a window of its own and the form is presented from the topmost view
/// controller, so both appear over every screen, the full-screen reader included. Reading
/// the screenshot itself would need photo-library access, so the app draws its own window
/// at the moment of the notification — the same pixels, minus the status bar.
@MainActor
final class FeedbackScreenshotPrompt {
    static let shared = FeedbackScreenshotPrompt()
    static let enabledKey = "feedbackScreenshotPromptEnabled"

    /// How long the capsule waits for a tap before it goes away by itself, as the system's
    /// own screenshot thumbnail does. A UI lifetime, not a wait for state to settle.
    private static let visibleDuration: Duration = .seconds(6)

    private var observer: NSObjectProtocol?
    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { FeedbackScreenshotPrompt.shared.screenshotTaken() }
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func screenshotTaken() {
        guard isEnabled,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let keyWindow = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return }
        // A screenshot of the report form itself is not a new report.
        if topmostViewController(in: keyWindow) is FeedbackComposeHostingController { return }

        let renderer = UIGraphicsImageRenderer(bounds: keyWindow.bounds)
        let image = renderer.image { _ in
            keyWindow.drawHierarchy(in: keyWindow.bounds, afterScreenUpdates: false)
        }
        show(image, in: scene)
    }

    private func show(_ image: UIImage, in scene: UIWindowScene) {
        hide()
        let host = UIHostingController(rootView: FeedbackScreenshotCapsule(
            onReport: { [weak self] in self?.report(image) },
            onClose: { [weak self] in self?.hide() }
        ))
        host.view.backgroundColor = .clear
        // The window covers the capsule and nothing else, so the rest of the screen keeps
        // taking touches. Sized by SwiftUI, so a larger text size grows it. It sits centred
        // on the bottom edge of the safe area, over the tab bar on a tab root.
        let bounds = scene.coordinateSpace.bounds
        let insets = scene.windows.first?.safeAreaInsets ?? .zero
        let size = host.sizeThatFits(in: CGSize(
            width: bounds.width - insets.left - insets.right,
            height: .greatestFiniteMagnitude
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - insets.bottom - size.height,
            width: size.width,
            height: size.height
        )
        window.windowLevel = .alert + 1
        window.traitOverrides[AppThemesTrait.self] = AppearanceThemePreset.activeAppThemes
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        UIAccessibility.post(notification: .announcement, argument: localized("已截圖。可以回報這個畫面的問題。"))

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            // VoiceOver users need longer than a glance; the capsule stays until dismissed
            // with the escape gesture.
            guard !UIAccessibility.isVoiceOverRunning else { return }
            self?.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        window?.isHidden = true
        window = nil
    }

    private func report(_ image: UIImage) {
        hide()
        let attachment: FeedbackDraftAttachment
        do {
            attachment = try FeedbackDraftAttachment.image(image)
        } catch {
            AppLogger.error("Screenshot could not be attached to feedback", error: error)
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let keyWindow = scene.windows.first(where: \.isKeyWindow),
              let presenter = topmostViewController(in: keyWindow)
        else {
            AppLogger.error("⟐ feedback form: no window to present from")
            attachment.discard()
            return
        }
        let host = FeedbackComposeHostingController(rootView: AnyView(
            NavigationStack {
                FeedbackComposeView(isSheet: true, initialAttachments: [attachment])
            }
        ))
        presenter.present(host, animated: true)
    }

    private func topmostViewController(in window: UIWindow) -> UIViewController? {
        guard var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// The form as presented by the prompt, recognisable so a screenshot of it is ignored.
final class FeedbackComposeHostingController: UIHostingController<AnyView> {}

/// The capsule: an info mark and 問題回報. Tapping anywhere on it reports; it goes away by
/// itself, or with VoiceOver's escape gesture.
private struct FeedbackScreenshotCapsule: View {
    let onReport: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onReport) {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "info")
                    .font(DSFont.title3.weight(.bold))
                    .foregroundStyle(DSColor.textOnAccent)
                    .frame(width: DSLayout.feedbackScreenshotPromptIconSide, height: DSLayout.feedbackScreenshotPromptIconSide)
                    .background(DSColor.accent, in: Circle())
                    .accessibilityHidden(true)
                Text(localized("問題回報"))
                    .font(DSFont.title3)
                    .foregroundStyle(DSColor.textPrimary)
            }
            .padding(.leading, DSSpacing.sm)
            .padding(.trailing, DSSpacing.xl)
            .padding(.vertical, DSSpacing.sm)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .floatingSurfaceBackground(in: Capsule())
        .accessibilityHint(localized("以這張截圖開啟回饋與改進"))
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("feedback_screenshot_prompt")
        .padding(DSSpacing.lg)
    }
}

#Preview {
    FeedbackScreenshotCapsule(onReport: {}, onClose: {})
}
