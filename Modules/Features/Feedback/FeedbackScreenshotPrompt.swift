import SwiftUI
import UIKit

/// 截圖後顯示意見回饋入口: after a screenshot, a small card in the corner offers to report
/// it, and opens 回饋與改進 with the screen already attached.
///
/// The card lives in a window of its own and the form is presented from the topmost view
/// controller, so both appear over every screen, the full-screen reader included. Reading
/// the screenshot itself would need photo-library access, so the app draws its own window
/// at the moment of the notification — the same pixels, minus the status bar.
@MainActor
final class FeedbackScreenshotPrompt {
    static let shared = FeedbackScreenshotPrompt()
    static let enabledKey = "feedbackScreenshotPromptEnabled"

    /// How long the card waits for a tap before it goes away by itself, as the system's
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
        let host = UIHostingController(rootView: FeedbackScreenshotCard(
            image: image,
            onReport: { [weak self] in self?.report(image) },
            onClose: { [weak self] in self?.hide() }
        ))
        host.view.backgroundColor = .clear
        // The window covers the card and nothing else, so the rest of the screen keeps
        // taking touches. Sized by SwiftUI, so a larger text size grows it.
        let size = host.sizeThatFits(in: CGSize(
            width: DSLayout.feedbackScreenshotCardWidth + DSSpacing.xxl * 2,
            height: .greatestFiniteMagnitude
        ))
        let bounds = scene.coordinateSpace.bounds
        let insets = scene.windows.first?.safeAreaInsets ?? .zero
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(
            x: bounds.maxX - size.width - insets.right,
            y: bounds.maxY - size.height - insets.bottom - DSSpacing.xxl,
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
            // VoiceOver users need longer than a glance; the card stays until dismissed.
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

/// The corner card: the screenshot, 回報問題, and a close button.
private struct FeedbackScreenshotCard: View {
    let image: UIImage
    let onReport: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: DSLayout.feedbackScreenshotCardWidth)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .accessibilityHidden(true)
            Button(action: onReport) {
                Label(localized("回報問題"), systemImage: "exclamationmark.bubble")
                    .font(DSFont.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(localized("以這張截圖開啟回饋與改進"))
        }
        .padding(DSSpacing.sm)
        .frame(width: DSLayout.feedbackScreenshotCardWidth + DSSpacing.sm * 2)
        .floatingSurfaceBackground(in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(DSFont.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(DSColor.textOnAccent, DSColor.cardCarouselDim.opacity(DSLayout.feedbackRemoveButtonBackdropOpacity))
                    .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .offset(x: -DSSpacing.lg, y: -DSSpacing.lg)
            .accessibilityLabel(localized("關閉"))
        }
        .padding(DSSpacing.lg)
    }
}

#Preview {
    FeedbackScreenshotCard(image: UIImage(systemName: "book")!, onReport: {}, onClose: {})
}
