import Foundation

/// Where one source's script state lives and runs: its parser bridge (and, through it, the
/// JS engine and the book/chapter context a parse sets before evaluating).
///
/// The resident is actor state, so it is reachable only on the host — the compiler, not a
/// comment, keeps two threads off it. Every stage that touches it runs here: a parse (`run`),
/// and the script halves of a fetch on either side of its network round trip (the
/// `ModernParserBridge` stages in the extension below, which suspend at the network and let
/// other work for the source run meanwhile).
///
/// The executor is a GCD serial queue, not the cooperative pool, for the reason
/// `SourceScriptThread` exists: a script can stop for the reader (`java.startBrowserAwait`,
/// `java.getVerificationCode`) for as long as the reader takes, and GCD adds threads when its
/// own are blocked while the pool has one per CPU. While such a script waits, the rest of
/// that source's work waits behind it — exactly as all of its JS already did on the engine's
/// one queue — and other sources are untouched.
///
/// The host does not order its callers. Parses queue for their turn by task priority in
/// `BookSourceSession` first, so a reader's chapter is not stuck behind prefetches; the host
/// only runs what reaches it, one job at a time.
actor SourceScriptHost<Resident: AnyObject> {
    let resident: Resident
    private let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(_ resident: sending Resident, label: String) {
        self.resident = resident
        self.queue = DispatchSerialQueue(label: "com.yuedu.sourceScriptHost.\(label)")
    }

    /// Runs `body` with the resident on the host, in one piece.
    func run<T: Sendable>(_ body: sending (Resident) throws -> T) rethrows -> T {
        try body(resident)
    }
}

extension SourceScriptHost where Resident == ModernParserBridge {
    /// A host for a fresh bridge over `source`. `requestSession` carries a test's URLProtocol.
    init(bridgeFor source: BookSource, requestSession: URLSession = LegadoJSBridge.requestSession) {
        self.init(
            ModernParserBridge(source: source, requestSession: requestSession),
            label: source.bookSourceName
        )
    }

    func fetch(ruleUrl: String, key: String? = nil, page: Int? = nil) async throws -> (String, String) {
        try await resident.fetch(ruleUrl: ruleUrl, key: key, page: page, on: self)
    }

    func searchBooks(keyword: String, page: Int = 1) async throws -> [OnlineBook] {
        try await resident.searchBooks(keyword: keyword, page: page, on: self)
    }

    func searchBooksStreaming(
        keyword: String,
        page: Int = 1,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async throws -> (books: [OnlineBook], streamed: Bool) {
        try await resident.searchBooksStreaming(keyword: keyword, page: page, onBatch: onBatch, on: self)
    }

    func getBookInfo(url: String) async throws -> OnlineBook {
        try await resident.getBookInfo(url: url, on: self)
    }

    func getChapterList(url: String) async throws -> [OnlineChapterRef] {
        try await resident.getChapterList(url: url, on: self)
    }

    func getContent(url: String) async throws -> String {
        try await resident.getContent(url: url, on: self)
    }

    func getExploreItems(
        page: Int = 1, variableOverlay: [String: String] = [:]
    ) -> [ModernParserBridge.DiscoverItem] {
        resident.exploreItems(page: page, variableOverlay: variableOverlay)
    }

    func primeDiscoverCookiesIfNeeded() async {
        await resident.primeDiscoverCookiesIfNeeded(on: self)
    }

    /// The rule-debug view's pipeline observer, attached for the length of one stage.
    func setDebugObserver(_ observer: sending ((RuleDebugEvent) -> Void)?) {
        resident.debugObserver = observer
    }
}
