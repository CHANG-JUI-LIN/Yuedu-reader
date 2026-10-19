import SwiftUI
import UIKit

/// A tapped 回饋中心 notification (`onFeedbackThreadUpdated`, payload key `feedbackThread`):
/// the conversation it is about, over whatever is on screen.
///
/// Presented from the top view controller rather than pushed into 設定 › 回饋中心: the tap can
/// arrive while the reader or another sheet covers the app, and a root sheet cannot show
/// over them (`RuleModuleLinkPresenter` does the same for module links).
@MainActor
enum FeedbackNotificationPresenter {
    /// The `userInfo` key `feedbackPushPolicy.ts` (`threadPayloadKey`) puts the thread id under.
    nonisolated static let threadKey = "feedbackThread"

    static func open(threadID: String) {
        Task {
            let thread: FeedbackThread?
            do {
                thread = try await FeedbackService.shared.thread(id: threadID)
            } catch {
                AppLogger.network("Feedback notification: the thread failed to load", error: error)
                return
            }
            guard let thread else {
                AppLogger.network("Feedback notification: the thread is not in this inbox", context: ["thread": threadID])
                return
            }
            guard let top = BookSourceFormLoginView.topViewController() else {
                AppLogger.error("Feedback notification: nowhere to present", context: ["thread": threadID], level: .warning)
                return
            }
            top.present(UIHostingController(rootView: FeedbackNotificationThreadSheet(thread: thread)), animated: true)
        }
    }
}

private struct FeedbackNotificationThreadSheet: View {
    let thread: FeedbackThread
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FeedbackThreadView(thread: thread)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(localized("關閉"))
                    }
                }
        }
    }
}

#Preview {
    FeedbackNotificationThreadSheet(thread: FeedbackThread(
        id: "preview",
        number: 25743,
        kind: .bug,
        title: "海報牆資源顯示有問題",
        status: .done,
        createdAt: Date(),
        updatedAt: Date(),
        lastMessagePreview: "已修好，下一版上線",
        lastMessageAuthor: .developer,
        lastReplyAt: Date(),
        userLastReadAt: nil
    ))
}
