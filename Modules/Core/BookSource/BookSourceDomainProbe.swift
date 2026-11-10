import Foundation
import Network
import os

/// Legado-E's 檢查域名 (`CheckSourceService.isDomainReachable`): before a source is checked,
/// a TCP connection to the host of its `bookSourceUrl`, given two seconds.
///
/// One difference: Legado connects to port 80 whenever the URL names none, `https` included,
/// and so marked 域名失效 every site that answers on 443 alone. Here an `https` URL without a
/// port is tried on 443.
enum BookSourceDomainProbe {
    enum Outcome: Equatable, Sendable {
        case reachable
        /// Legado-E: "源地址不是http链接" — the check fails, with no group.
        case notHTTP
        case unreachable
    }

    /// Legado-E's `withTimeout(2000)`.
    static let timeoutSeconds = 2

    private static let queue = DispatchQueue(label: "yuedu.source-check.domain-probe")

    static func check(_ bookSourceURL: String) async -> Outcome {
        let raw = String(bookSourceURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("http") else { return .notHTTP }
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return .unreachable
        }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return .unreachable
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = timeoutSeconds
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let finish: @Sendable (Outcome) -> Void = { outcome in
                    let first = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.cancel()
                    continuation.resume(returning: outcome)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.reachable)
                    case .waiting(let error), .failed(let error):
                        // `.waiting`: no route, the name did not resolve, or the connection was
                        // refused or timed out — the socket Legado opens throws for each.
                        AppLogger.network("source check: domain unreachable", context: [
                            "host": host, "port": port, "error": error.localizedDescription,
                        ])
                        finish(.unreachable)
                    case .cancelled:
                        finish(.unreachable)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
