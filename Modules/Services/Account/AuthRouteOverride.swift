import Foundation

/// Debug-only launch-argument override for the account route. It exists so an
/// integration build can be pinned to the Gateway and cannot silently fall back
/// to the direct Firebase path (a "pass" on a network where Firebase is
/// reachable would otherwise prove nothing).
///
/// Compiled only into DEBUG builds; a shipped app has no way to trigger it.
enum AuthRouteOverride {
    static let forcedGatewayArgument = "-gateway-route-forced"
    static let forcedDirectArgument = "-direct-route-forced"

    static func forcedRoute(
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AuthRoute? {
        if launchArguments.contains(forcedGatewayArgument) { return .gateway }
        if launchArguments.contains(forcedDirectArgument) { return .direct }
        return nil
    }
}
