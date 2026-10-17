import Foundation

/// A module's `hosts`, the one place they are matched (Open Library module plan, OL1b).
///
/// A name written out (`openlibrary.org`) is a host its requests may go to, and a redirect may
/// follow to. A `*.example.org` entry (format 3.0) is a domain a redirect may follow into, itself
/// and every name under it, and never a request's own host: Open Library's covers answer 302 to
/// `archive.org`, which answers 302 to a numbered `iaNNNNNN.us.archive.org` (2026-10-17).
struct RuleModuleHosts: Sendable {
    private let exact: Set<String>
    private let domains: [String]

    nonisolated init(_ hosts: [String]) {
        var exact = Set<String>()
        var domains: [String] = []
        for host in hosts.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            if let domain = Self.wildcardDomain(host) { domains.append(domain) } else { exact.insert(host) }
        }
        self.exact = exact
        self.domains = domains
    }

    /// A request's own address: its host written out.
    nonisolated func allowsRequest(to host: String) -> Bool {
        exact.contains(host.lowercased())
    }

    /// A redirect's (or a page's meta refresh's) target: written out, or in a `*.` domain.
    nonisolated func allowsRedirect(to host: String) -> Bool {
        let host = host.lowercased()
        return exact.contains(host) || domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Any entry with a `*`; only a leading `*.` is a valid one (`wildcardDomain`).
    nonisolated static func isWildcard(_ entry: String) -> Bool {
        entry.contains("*")
    }

    /// The domain of a `*.` entry: two labels or more of letters, digits and hyphens
    /// (`*.org` would be a whole top-level domain). Nil for anything else.
    nonisolated static func wildcardDomain(_ entry: String) -> String? {
        let entry = entry.trimmingCharacters(in: .whitespaces).lowercased()
        guard entry.hasPrefix("*.") else { return nil }
        let domain = String(entry.dropFirst(2))
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return domain
    }
}
