import FirebaseCore
import FirebaseFunctions
import Foundation

/// Asks Cloud Functions' `isBuildUnderReview` whether App Review has this build
/// open. Only a Sandbox Release build asks: see `SubscriptionPurchaseMode`.
@MainActor
struct SubscriptionReviewStatusService {
    private let functionsRegion = "asia-east1"

    /// Nil when there is no answer: Firebase not configured yet, the backend
    /// unreachable (mainland China without a VPN), or a reply it cannot read.
    /// Every one of those is logged, because a reviewer who meets the TestFlight
    /// notice is a rejection and the log is how it gets diagnosed.
    func isBuildUnderReview() async -> Bool? {
        guard FirebaseApp.app() != nil else {
            AppLogger.error("Review status not asked: Firebase is not configured yet")
            return nil
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        do {
            let result = try await Functions.functions(region: functionsRegion)
                .httpsCallable("isBuildUnderReview")
                .call(["version": version, "build": build])
            guard let data = result.data as? [String: Any],
                  let underReview = data["underReview"] as? Bool else {
                AppLogger.error(
                    "Review status reply unreadable",
                    context: ["version": version, "build": build]
                )
                return nil
            }
            return underReview
        } catch {
            AppLogger.error(
                "Review status unavailable",
                error: error,
                context: ["version": version, "build": build]
            )
            return nil
        }
    }
}
