import FirebaseAuth
import Foundation

/// Route-neutral account model. Both the Firebase SDK path and the Gateway path
/// produce this; business code must not depend on `FirebaseAuth.User`.
struct AccountUser: Equatable, Codable {
    let uid: String
    let email: String
    let displayName: String
    let photoURL: String?
    let providerIds: [String]
    let emailVerified: Bool

    var providerDisplayName: String {
        Self.providerDisplayName(for: providerIds)
    }

    /// Mirrors `FirebaseAuthManager.providerDisplayName(from:)` so both routes
    /// label providers identically.
    static func providerDisplayName(for providerIds: [String]) -> String {
        switch providerIds.first {
        case "google.com":
            return "Google"
        case "apple.com":
            return "Apple"
        case "password":
            return "Email"
        default:
            return providerIds.first ?? "Firebase"
        }
    }

    init(
        uid: String,
        email: String,
        displayName: String,
        photoURL: String?,
        providerIds: [String],
        emailVerified: Bool
    ) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.providerIds = providerIds
        self.emailVerified = emailVerified
    }

    /// Maps the Firebase SDK user into the shared model (direct route).
    @MainActor
    init(firebaseUser user: User) {
        self.init(
            uid: user.uid,
            email: user.email ?? "",
            displayName: user.displayName ?? "",
            photoURL: user.photoURL?.absoluteString,
            providerIds: user.providerData.map(\.providerID),
            emailVerified: user.isEmailVerified
        )
    }
}
