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

    private enum CodingKeys: String, CodingKey {
        case uid
        case email
        case displayName
        case photoURL
        case providerIds
        case emailVerified
    }

    /// Lenient decoding: Firebase reports `displayName` (and occasionally
    /// `email`) as null for brand-new or provider-hidden accounts. The model
    /// keeps those fields non-optional for UI, so null/missing becomes "".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        email = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? ""
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        photoURL = try? container.decodeIfPresent(String.self, forKey: .photoURL)
        providerIds = (try? container.decodeIfPresent([String].self, forKey: .providerIds)) ?? []
        emailVerified = (try? container.decodeIfPresent(Bool.self, forKey: .emailVerified)) ?? false
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
