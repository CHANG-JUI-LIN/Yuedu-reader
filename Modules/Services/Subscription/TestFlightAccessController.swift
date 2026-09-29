import Combine
import Foundation
import StoreKit

/// A foreground grant is deliberately memory-only. No StoreKit, Keychain or
/// iCloud Pro cache can substitute for this server check.
@MainActor
final class TestFlightAccessController: ObservableObject {
    enum State: Equatable {
        case checking, unrestricted, allowed, signInRequired, ineligible, unavailable

        var allowsUse: Bool { self == .unrestricted || self == .allowed }
    }

    static let shared = TestFlightAccessController()
    @Published private(set) var state: State
    private(set) var isTestFlight = false
    private let localDevelopment: Bool
    private let environment: () async throws -> AppStore.Environment
    private let uid: () -> String?
    private let verify: () async throws -> Bool
    private let didChange: () -> Void
    private var generation = 0

    convenience init() {
        // TestFlight membership verification is switched off: every build,
        // TestFlight included, starts `.unrestricted` and never runs the
        // server check, so no launch/foreground gate is shown.
        self.init(localDevelopment: true, environment: {
            let result = try await AppTransaction.shared
            guard case .verified(let transaction) = result else {
                throw AccountBackendError.invalidResponse
            }
            return transaction.environment
        }, uid: { FirebaseAuthManager.shared.uid }, verify: {
            try await AccountBackendRouter.shared.current.verifyTestFlightAccess()
        }, didChange: {
            SubscriptionStore.shared.testFlightAccessDidChange()
        })
    }

    init(
        localDevelopment: Bool,
        environment: @escaping () async throws -> AppStore.Environment,
        uid: @escaping () -> String?,
        verify: @escaping () async throws -> Bool,
        didChange: @escaping () -> Void = {}
    ) {
        self.localDevelopment = localDevelopment
        self.environment = environment
        self.uid = uid
        self.verify = verify
        self.didChange = didChange
        state = localDevelopment ? .unrestricted : .checking
    }

    /// Called synchronously on backgrounding/account changes, before starting
    /// async work. A late success from the previous foreground is discarded.
    func invalidate() {
        generation += 1
        guard !localDevelopment, state != .unrestricted else { return }
        state = .checking
        didChange()
    }

    func refresh() async {
        // The installed binary cannot change environment within this process.
        guard !localDevelopment, state != .unrestricted else { return }
        invalidate()
        let requestGeneration = generation
        let expectedUID = uid()
        do {
            let runningEnvironment = try await environment()
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if runningEnvironment == .production {
                isTestFlight = false
                state = .unrestricted
                didChange()
                return
            }
            guard runningEnvironment == .sandbox else { throw AccountBackendError.invalidResponse }
            isTestFlight = true
            guard expectedUID != nil, expectedUID == uid() else {
                state = .signInRequired
                didChange()
                return
            }
            let allowed = try await verify()
            guard requestGeneration == generation, expectedUID == uid(), !Task.isCancelled else { return }
            state = allowed ? .allowed : .ineligible
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            AppLogger.error("TestFlight membership verification failed", error: error)
            state = .unavailable
        }
        didChange()
    }
}
