import Foundation
import JavaScriptCore
import os

/// JavaScript execution engine wrapping JavaScriptCore.
/// Provides Legado-compatible `java.*` bridge functions so book source
/// rules written for Legado's Rhino engine run on iOS.
///
/// Usage:
/// ```
/// let engine = JSCoreEngine()
/// engine.getData = { key in storage[key] }
/// engine.putData = { key, val in storage[key] = val }
/// let html = engine.evaluate("java.ajax(url)", result: previousResult)
/// ```
class JSCoreEngine {

    /// A Kotlin `Map<String, String>` as Legado binds one: the login sheet's `result`, which
    /// `SourceLoginDialog.getLoginData` builds as a `HashMap` for the login button, every
    /// loginUi button and every `loginUi`/`viewName` script. Bound, or set as `result`, it is
    /// an object with `java.util.Map`'s methods (`__yueduJavaMap`), so `result.get('邮箱')`
    /// reads it as `result['邮箱']` does. A dictionary binds as a plain object, with no `get`:
    /// ☁️云端聚合's `login(true)` reads `result.get('邮箱')` inside a `try`, read nothing, and
    /// answered every filled-in form with 「请先填写邮箱和密码」.
    struct JavaMap: Sendable {
        let entries: [String: String]
        init(_ entries: [String: String]) { self.entries = entries }
    }

    /// A string a rule chain's earlier step made — a JSONPath, XPath, JSoup or regex step —
    /// set as `result` as the plain JS string it is. Legado's `AnalyzeRule.getString` turns
    /// every such step into a `String` (`AnalyzeByJSonPath.getString` joins a list with
    /// "\n"; a regex replace answers a string), and Rhino binds a `String` as a JS string
    /// (`Context.javaToJS`). Unmarked, a JSON-looking string is hydrated into the object it
    /// spells (`setResult`), which a page body or a list item needs: 爱巴士 (YCK1330) reads
    /// `$.data.content_data` — the text `["我的病娇男友","作者：闲于",…]` — and then
    /// `result.match(/\["(.*)"\]/)`, which an array has no method for.
    struct ScriptString: Sendable {
        let value: String
        init(_ value: String) { self.value = value }
    }

    private var context: JSContext
    /// Stateless (it goes straight to `HTTPCookieStorage`), so every context shares it.
    private let cookieBridge = LegadoCookieBridge()
    /// Bridge for `cache.*` — persistent + memory key-value store. Lock-guarded (`LRUCache`,
    /// `UserDefaults`), so a context a timeout abandoned may share it.
    private(set) var cacheBridge: LegadoCacheBridge

    /// The bridges a context holds that keep state: each context has its own. A JS timeout
    /// reset abandons the old context with its script still running, and that script keeps
    /// calling them — one `source` bridge written from both queues crashed in `put`
    /// (Crashlytics 61eb93e6…, 3.0.1 build 144, background `refresh.all`).
    private struct ContextBridges {
        var java: LegadoJSBridge
        var source: LegadoSourceBridge
        var book: LegadoBookBridge
        var chapter: LegadoChapterBridge
    }

    /// The current context's bridges. Guarded by `queueLock`, and replaced together with the
    /// queue, the context and `generation`: callers read `bookBridge` from their own threads
    /// while a timeout's reset swaps it from the waiting one.
    private var currentBridges: ContextBridges

    /// Bridge for Legado's `java` object.
    private(set) var bridge: LegadoJSBridge {
        get { withQueueLock { currentBridges.java } }
        set { withQueueLock { currentBridges.java = newValue } }
    }
    /// Bridge for `source.*` — replaces the plain dictionary with a full Legado-compatible object.
    private(set) var sourceBridge: LegadoSourceBridge {
        get { withQueueLock { currentBridges.source } }
        set { withQueueLock { currentBridges.source = newValue } }
    }
    /// Bridge for Legado's mutable `book` object.
    private(set) var bookBridge: LegadoBookBridge {
        get { withQueueLock { currentBridges.book } }
        set { withQueueLock { currentBridges.book = newValue } }
    }
    /// Bridge for Legado's mutable `chapter` object.
    private(set) var chapterBridge: LegadoChapterBridge {
        get { withQueueLock { currentBridges.chapter } }
        set { withQueueLock { currentBridges.chapter = newValue } }
    }

    // Serial queue owns the JSContext — all evaluations run on this queue.
    // Using a dedicated queue instead of NSLock eliminates the deadlock that
    // NSLock causes when JS calls java.ajax() (semaphore) while the lock is held.
    private var jsQueue = DispatchQueue(label: "com.yuedu.jsengine.serial", qos: .userInitiated)
    /// Marks a queue as the engine's, with the generation it serves. A timeout reset abandons
    /// the old queue with its script still running, and that queue keeps its mark: work only
    /// runs inline on a queue whose generation is the current one (`isOnCurrentJSQueue`).
    private let jsQueueKey = DispatchSpecificKey<UInt64>()

    /// JS evaluation timeout. If a script takes longer than this, the engine is
    /// reset and the evaluation returns nil. Guards against infinite loops in
    /// book-source rule JS that would otherwise permanently block the serial
    /// queue and freeze the calling Task (common on iOS 17).
    private static let jsTimeout: TimeInterval = 30

    /// Last JavaScript error message (nil if no error on last evaluation).
    private(set) var lastError: String?

    /// Every uncaught exception, counted, with the most recent messages kept. `lastError`
    /// is cleared by each evaluation, so a stage that runs many scripts — a search page's
    /// list and field rules — marks first and asks what was thrown since
    /// (`uncaughtExceptions(since:)`). Guarded by `queueLock`.
    private var uncaughtExceptionCount = 0
    private var recentUncaughtExceptions: [String] = []

    func uncaughtExceptionMark() -> Int {
        withQueueLock { uncaughtExceptionCount }
    }

    /// The messages of the exceptions thrown since `mark`, oldest first (at most the last 8).
    func uncaughtExceptions(since mark: Int) -> [String] {
        withQueueLock {
            let count = min(uncaughtExceptionCount - mark, recentUncaughtExceptions.count)
            return count > 0 ? Array(recentUncaughtExceptions.suffix(count)) : []
        }
    }

    /// Human-readable pipeline stage included in structured compatibility errors.
    private(set) var executionStage = "javascript"

    // MARK: - Delegates

    /// Retrieve a stored variable by key (wired to RuleDataInterface).
    var getData: ((String) -> String?)? {
        didSet { bridge.getData = getData }
    }

    /// Store a variable by key (wired to RuleDataInterface).
    var putData: ((String, String) -> Void)? {
        didSet { bridge.putData = putData }
    }

    /// Handle network requests originating from `java.ajax` / `java.connect`.
    var networkHandler: SourceScriptTransport? {
        didSet { bridge.networkHandler = networkHandler }
    }

    /// Handle AnalyzeUrl parsing for `java.ajax` URLs with ,{json} options. Called on the JS
    /// thread; the request it builds keeps its network apart from its JS (`PreparedSourceRequest`).
    var analyzeUrlHandler: ((String) -> PreparedSourceRequest?)? {
        didSet { bridge.analyzeUrlHandler = analyzeUrlHandler }
    }

    /// Handle `java.getString(ruleStr)` — connected to ModernRuleEngine later.
    var getStringHandler: ((String) -> String?)? {
        didSet { bridge.getStringHandler = getStringHandler }
    }

    /// Handle `java.getStringList(ruleStr)` — connected to ModernRuleEngine later.
    var getStringListHandler: ((String) -> [String]?)? {
        didSet { bridge.getStringListHandler = getStringListHandler }
    }

    /// Handle `java.setContent(content, baseUrl)`: the content of the reader the running rule
    /// step belongs to (`RuleReaders.setContent`).
    var setContentHandler: ((Any?, String?) -> Void)? {
        didSet { bridge.setContentHandler = setContentHandler }
    }

    /// Handle `java.getElements(ruleStr)` — extracts elements from stored content.
    var getElementsHandler: ((String) -> Any?)? {
        didSet { bridge.getElementsHandler = getElementsHandler }
    }

    /// Handle `java.getElement(ruleStr)` — Legado `AnalyzeRule.getElement`.
    var getElementHandler: ((String) -> Any?)? {
        didSet { bridge.getElementHandler = getElementHandler }
    }

    /// Handle `java.getString(ruleStr, content)`: the rule read against `content`.
    var getStringWithContentHandler: ((String, Any?) -> String?)? {
        didSet { bridge.getStringWithContentHandler = getStringWithContentHandler }
    }

    /// Makes the rule reader of a script's `AnalyzeRule()` (`LegadoAnalyzeRule`).
    var analyzeRuleFactory: (() -> ModernRuleEngine?)? {
        didSet { bridge.analyzeRuleFactory = analyzeRuleFactory }
    }

    /// The readers a rule step's script calls back into — `java.getString`, `getStringList`,
    /// `getElements`, `getElement`, `getString(rule, content)`, `setContent` — which belong to
    /// the engine the step runs in: Legado's `java` is that step's `AnalyzeRule`.
    struct RuleReaders {
        var getString: ((String) -> String?)?
        var getStringList: ((String) -> [String]?)?
        var getElements: ((String) -> Any?)?
        var getElement: ((String) -> Any?)?
        var getStringWithContent: ((String, Any?) -> String?)?
        var setContent: ((Any?, String?) -> Void)?
    }

    var ruleReaders: RuleReaders {
        get {
            RuleReaders(
                getString: getStringHandler, getStringList: getStringListHandler,
                getElements: getElementsHandler, getElement: getElementHandler,
                getStringWithContent: getStringWithContentHandler,
                setContent: setContentHandler
            )
        }
        set {
            getStringHandler = newValue.getString
            getStringListHandler = newValue.getStringList
            getElementsHandler = newValue.getElements
            getElementHandler = newValue.getElement
            getStringWithContentHandler = newValue.getStringWithContent
            setContentHandler = newValue.setContent
        }
    }

    /// Called when JS invokes `java.startBrowser` / `java.startBrowserAwait`. Unset, pages
    /// open through `LegadoJSBridge.sharedBrowserPresenter`.
    var browserPresentHandler: ((SourceBrowserRequest, @escaping @Sendable (String?) -> Void) -> Void)? {
        didSet { bridge.browserPresentHandler = browserPresentHandler }
    }

    /// Called when JS invokes `java.getVerificationCode`. Unset, the captcha opens through
    /// `LegadoJSBridge.sharedCaptchaPresenter`.
    var captchaPresentHandler: ((SourceCaptchaRequest, @escaping @Sendable (String?) -> Void) -> Void)? {
        didSet { bridge.captchaPresentHandler = captchaPresentHandler }
    }

    /// See `LegadoJSBridge.sourceBrowserRequest(urlString:)`.
    func sourceBrowserRequest(urlString: String) -> URLRequest? {
        bridge.sourceBrowserRequest(urlString: urlString)
    }

    /// Called for Legado's source-authored four-argument browser pages.
    var browserPagePresentHandler: ((LegadoBrowserPageRequest) -> Void)? {
        didSet { bridge.browserPagePresentHandler = browserPagePresentHandler }
    }

    /// Called when JS invokes `java.reLoginView()` — re-render the source's custom login menu.
    var reLoginViewHandler: (() -> Void)? {
        didSet { bridge.reLoginViewHandler = reLoginViewHandler }
    }

    /// Called when JS invokes `java.upLoginData(map)` — persist source-menu setting values.
    var upLoginDataHandler: ((JSValue) -> Void)? {
        didSet { bridge.upLoginDataHandler = upLoginDataHandler }
    }

    /// Called when JS invokes `java.toast` / `java.longToast`.
    var toastHandler: (@Sendable (String) -> Void)? {
        didSet { bridge.toastHandler = toastHandler }
    }

    /// Called when JS invokes `java.refreshBookInfo()` / `java.refreshBookToc()`.
    var refreshBookInfoHandler: (() -> Void)? {
        didSet { bridge.refreshBookInfoHandler = refreshBookInfoHandler }
    }

    var refreshBookTocHandler: (() -> Void)? {
        didSet { bridge.refreshBookTocHandler = refreshBookTocHandler }
    }

    /// Called when JS invokes `java.refreshExplore()`.
    var refreshExploreHandler: (() -> Void)? {
        didSet { bridge.refreshExploreHandler = refreshExploreHandler }
    }

    /// Called when JS invokes `java.setResponseBase64(data, mimeType)` — captures
    /// base64-decoded audio data from TTS `loginCheckJs` response processing.
    var responseBase64Handler: ((Data, String) -> Void)? {
        didSet { bridge.setResponseBase64Handler = responseBase64Handler }
    }

    /// Book source object injected as `source` in JS — set this before evaluating rule scripts.
    var bookSource: BookSource? {
        didSet {
            onJSQueue {
                guard let src = bookSource else {
                    sourceBridge = LegadoSourceBridge(
                        bookSourceUrl: "", bookSourceName: "", bookSourceGroup: "",
                        bookSourceComment: "", loginUrl: "", header: "", loginCheckJs: ""
                    )
                    cacheBridge = LegadoCacheBridge(sourceId: "")
                    injectSourceObject(sourceBridge, into: context)
                    context.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)
                    return
                }
                let prevHandlers = sourceBridge.getVariableHandler
                sourceBridge = LegadoSourceBridge.from(src)
                sourceBridge.getVariableHandler = prevHandlers
                cacheBridge = LegadoCacheBridge(sourceId: src.bookSourceUrl)
                injectSourceObject(sourceBridge, into: context)
                context.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)
                installExploreInfoMap(into: context)
            }
        }
    }

    // MARK: - Resolved source headers

    private var isResolvingHeaders = false
    /// Where every resolution is also published for readers off the source's host (cover
    /// cells on the main thread read it through `BookSource.parsedHeaders`).
    var headerSnapshot: SourceHeaderSnapshot?

    /// The session's user waits (`BookSourceSession.userWaits`), handed to every bridge.
    var userWaits: LegadoUserWaitRegistry? {
        didSet { bridge.userWaits = userWaits }
    }

    /// The source's `header` rule resolved to request headers (Legado
    /// `BaseSource.getHeaderMap()`): plain JSON, or a `@js:` / `<js>` rule evaluated here.
    ///
    /// Evaluated again on every call, as Legado evaluates it for every request
    /// (`AnalyzeUrl.init`, `java.get`/`java.post`): a rule can read state a script set since
    /// the last request, or have effects a later rule reads. 漫画台 and the other qyyuapi
    /// sources (YCK 1329) `cache.put` their headers under a key built from a variable their
    /// login script sets, and their search rule reads that key back; the result this kept
    /// from before the variable existed (07-25 to 11-09) left the key unset. 小小阅读 signs
    /// its headers with the current time. A caller building one request reads this once and
    /// sends that map (`ModernParserBridge.applySourceAuthentication`).
    ///
    /// Resolved on first use — not when the source is attached — so a rule that calls
    /// `jsLib` helpers sees them. A request the header rule's own script issues gets `[:]`,
    /// where Legado would evaluate the rule again inside itself.
    ///
    /// Never called on the main thread: the source's host resolves it, and readers that
    /// cannot wait read `headerSnapshot` (`BookSource.parsedHeaders`).
    func resolvedSourceHeaders() -> [String: String] {
        // `java.ajaxAll` waits on worker requests while occupying the JS queue, so no worker
        // may reach here: hopping onto that queue deadlocks the batch until its timeout.
        // Every request reads its headers on the JS thread instead — `ajaxAll` resolves them
        // before it fans out, and the AnalyzeUrl handler while it builds each request
        // (`PreparedSourceRequest`).
        let work = { [self] () -> [String: String] in
            guard !isResolvingHeaders else { return [:] }
            var headers: [String: String] = [:]
            if let header = bookSource?.header {
                isResolvingHeaders = true
                // A source's map carries Legado's default User-Agent when it names none
                // (`BookSource.withLegadoUserAgent`, Legado `BaseSource.getHeaderMap`).
                headers = BookSource.withLegadoUserAgent(parseHeaders(header))
                isResolvingHeaders = false
            }
            headerSnapshot?.store(headers)
            return headers
        }
        return onJSQueue(work)
    }

    /// Headers visible to `java.*` requests. Legado's request layer merges the
    /// source header rule with the payload stored by `source.putLoginHeader()`;
    /// the latter wins when both declare the same field.
    func resolvedRequestHeaders() -> [String: String] {
        var headers = resolvedSourceHeaders()
        guard let sourceUrl = bookSource?.bookSourceUrl,
              let loginHeaders = LoginManager.shared.getLoginHeaderMap(sourceUrl: sourceUrl)
        else { return headers }
        headers.merge(loginHeaders) { _, loginValue in loginValue }
        return headers
    }

    /// Called when JS evaluation fails, with the error message and the script that caused it.
    var errorHandler: ((String, String) -> Void)?

    // MARK: - Initializer

    init() {
        let ctx = JSContext()!
        self.context = ctx
        self.currentBridges = ContextBridges(
            java: LegadoJSBridge(),
            source: LegadoSourceBridge(
                bookSourceUrl: "", bookSourceName: "", bookSourceGroup: "",
                bookSourceComment: "", loginUrl: "", header: "", loginCheckJs: ""
            ),
            book: LegadoBookBridge(),
            chapter: LegadoChapterBridge()
        )
        self.cacheBridge = LegadoCacheBridge(sourceId: "")

        jsQueue.setSpecific(key: jsQueueKey, value: 0)
        configureContext(ctx, bridges: currentBridges)
        configureJavaBridge(currentBridges.java)
    }

    /// Everything the engine installs on a `java` bridge: the delegates set on the engine and
    /// the providers. The initializer and a timeout's reset both configure theirs here, so a
    /// replacement bridge works exactly like the first. Called under `queueLock` on a reset.
    private func configureJavaBridge(_ bridge: LegadoJSBridge) {
        bridge.getData = getData
        bridge.putData = putData
        bridge.networkHandler = networkHandler
        bridge.analyzeUrlHandler = analyzeUrlHandler
        bridge.getStringHandler = getStringHandler
        bridge.getStringListHandler = getStringListHandler
        bridge.setContentHandler = setContentHandler
        bridge.getElementsHandler = getElementsHandler
        bridge.getElementHandler = getElementHandler
        bridge.userWaits = userWaits
        bridge.getStringWithContentHandler = getStringWithContentHandler
        bridge.analyzeRuleFactory = analyzeRuleFactory
        bridge.browserPresentHandler = browserPresentHandler
        bridge.captchaPresentHandler = captchaPresentHandler
        bridge.browserPagePresentHandler = browserPagePresentHandler
        bridge.reLoginViewHandler = reLoginViewHandler
        bridge.upLoginDataHandler = upLoginDataHandler
        bridge.toastHandler = toastHandler
        bridge.refreshBookInfoHandler = refreshBookInfoHandler
        bridge.refreshBookTocHandler = refreshBookTocHandler
        bridge.refreshExploreHandler = refreshExploreHandler
        bridge.setResponseBase64Handler = responseBase64Handler
        bridge.videoEpisodeHandover = isHandingOverVideoEpisode ? .init() : nil

        // `java.get`/`java.post`/`java.ajax` inside rule JS ask for the source's
        // headers per request; resolve them lazily so a `@js:` rule runs after
        // jsLib is in place, and again for every request — see `resolvedSourceHeaders`.
        bridge.sourceHeadersProvider = { [weak self] in
            self?.resolvedRequestHeaders() ?? [:]
        }
        // Read live rather than snapshotted: the toggle can change while a
        // source stays attached, and the next request must see it.
        bridge.presentsAndroidIdentityProvider = { [weak self] in
            self?.bookSource?.presentsAndroidIdentity ?? false
        }
        // The script's own `source` — a book source's or an RSS source's.
        bridge.keepsCookieJarProvider = { [weak self] in
            self?.sourceBridge.enabledCookieJar ?? false
        }
        bridge.sourceIdentityProvider = { [weak self] in
            (self?.bookSource?.bookSourceName ?? "", self?.bookSource?.bookSourceUrl ?? "")
        }
        bridge.importScriptCacheProvider = { [weak self] in
            self?.cacheBridge
        }
    }

    // MARK: - Public API

    // Lock protecting `jsQueue` swap during timeout recovery.
    private let queueLock = NSLock()

    private func withQueueLock<T>(_ body: () -> T) -> T {
        queueLock.lock()
        defer { queueLock.unlock() }
        return body()
    }

    private func isCurrentGeneration(_ queueGeneration: UInt64) -> Bool {
        withQueueLock { generation == queueGeneration }
    }

    /// Whether the caller is running on the current generation's JS queue. A script abandoned
    /// by a timeout reset that calls back into the engine (`source.evalJS`, `java.getString`)
    /// is on the old queue: it must queue behind the new jobs, not run inline against the new
    /// context and bridges at the same time as they do.
    private var isOnCurrentJSQueue: Bool {
        guard let queueGeneration = DispatchQueue.getSpecific(key: jsQueueKey) else { return false }
        return isCurrentGeneration(queueGeneration)
    }

    /// Dispatch work to the JS serial queue, re-entrant-safe.
    /// If already executing on the JS queue (e.g. java.getString → engine.getString → evaluate),
    /// the work runs inline to avoid a deadlock.
    private func onJSQueue<T>(_ work: () -> T) -> T {
        if isOnCurrentJSQueue {
            return work() // already on the JS queue — run inline
        }
        let (queue, queueGeneration) = withQueueLock { (jsQueue, generation) }
        return SourcePerfTrace.mainThreadWait("wait.jsQueue") {
            queue.sync {
                // Queued behind a script a timeout abandoned: the engine moved to a new queue
                // meanwhile, and run here this would touch the new context alongside it.
                guard isCurrentGeneration(queueGeneration) else { return onJSQueue(work) }
                return work()
            }
        }
    }

    /// Like `onJSQueue` but with a timeout. Returns `.timedOut` when the JS
    /// evaluation takes longer than `Self.jsTimeout` seconds. On timeout the
    /// engine is reset so subsequent evaluations can proceed.
    private enum JSTimeoutResult<T> {
        case completed(T)
        case timedOut
    }

    private func onJSQueueWithTimeout<T>(_ work: @escaping () -> T) -> JSTimeoutResult<T> {
        if isOnCurrentJSQueue {
            return .completed(work())
        }

        // Written on the JS queue, read here after the group says it finished. After a timeout
        // the late write lands in the lock and is never read.
        let result = OSAllocatedUnfairLock<JSConfined<T>?>(initialState: nil)
        let group = DispatchGroup()
        // The job's queue, generation and `java` bridge, read together: a timeout resets only
        // the generation it dispatched to, and only that bridge says the script awaits the user.
        let (queue, queueGeneration, javaBridge) = withQueueLock { (jsQueue, generation, currentBridges.java) }
        let work = JSConfined(work)
        // Only guards against the engine being torn down; the engine itself is unused
        // because `work` is a self-contained closure.
        let engine = JSConfined<() -> JSCoreEngine?>({ [weak self] in self })

        group.enter()
        queue.async {
            // A job queued behind a script a timeout abandoned never runs: on this queue it would
            // run against the new context at the same time as the new queue's jobs. Its caller
            // gets the timeout's nil, as it would have had its own wait run out first.
            guard let liveEngine = engine.value(), liveEngine.isCurrentGeneration(queueGeneration) else {
                group.leave()
                return
            }
            let value = JSConfined(work.value())
            result.withLock { $0 = value }
            group.leave()
        }

        // The timeout stops runaway rule JS. A script parked in `java.startBrowserAwait` or
        // `java.getVerificationCode` is waiting for the reader — a login, a Cloudflare check,
        // a captcha — not stuck, and Legado waits for as long as that takes; resetting the
        // engine under it threw away the script's state and its result. The sheet always
        // ends (`BrowserAwaitBox`) — but it is shown on the main thread, so a caller blocking
        // the main thread here keeps the timeout: waiting on would leave it unable to appear.
        // A script blocked on the network is not stuck either: each wait is bounded by its
        // request's own timeout, 60 s as in Legado (`LegadoScriptWaits`).
        //
        // So the timeout counts the script's own time, its waits taken out. It checked only
        // whether a wait was in progress at each 30 s mark, and a script whose waits had all
        // ended by then had them counted against it: 番茄听书 (YCK 1330 #31) downloads a
        // chapter's audio and then decrypts it, about 8 s of its own, and a slow download put
        // the 30 s mark in the decrypt — content and the 發現 after it failed.
        var timedOut = false
        let started = DispatchTime.now().uptimeNanoseconds
        let waitedBefore = javaBridge.waitedSeconds
        var budget = Self.jsTimeout
        SourcePerfTrace.mainThreadWait("wait.jsQueue", "timeout=\(Int(Self.jsTimeout))s timedOut=\(timedOut)") {
            while group.wait(timeout: .now() + budget) == .timedOut {
                if !Thread.isMainThread {
                    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                    let ownTime = elapsed - (javaBridge.waitedSeconds - waitedBefore)
                    // Waiting adds nothing to its own time; once the wait ends, the rest of the
                    // budget is checked again. A second's floor keeps a script near the limit,
                    // parked on a long wait, from being polled in a tight loop.
                    if ownTime < Self.jsTimeout || javaBridge.isWaiting {
                        budget = max(Self.jsTimeout - ownTime, 1)
                        continue
                    }
                }
                resetEngine(abandoning: queueGeneration)
                // Why the caller got nothing, read as it reads an exception: a URL script that
                // ran out of time failed, where one that gave no value reads as Legado's null
                // (`AnalyzeUrl.evaluateURLScript`).
                lastError = "script timed out after \(Int(Self.jsTimeout)) s"
                timedOut = true
                return
            }
        }
        if timedOut { return .timedOut }
        guard let value = result.withLock({ $0 }) else { return .timedOut }
        return .completed(value.value)
    }

    // MARK: - JS network attribution
    //
    // Forwards to the java bridge's accumulator so a caller (ModernParserBridge) can measure
    // how much of a parse was spent blocked on `java.*` network (段評 review fetches) vs JS CPU.
    func resetJSNetworkMs() { bridge.resetNetworkMs() }
    func takeJSNetworkMs() -> Double { bridge.takeNetworkMs() }

    /// Executes a nested evaluation under a precise pipeline stage. The JS queue is
    /// re-entrant, so callers can wrap existing evaluation APIs without a second path.
    func withExecutionStage<T>(_ stage: String, _ work: () -> T) -> T {
        onJSQueue {
            let previous = executionStage
            executionStage = stage
            updateRuntimeErrorContext()
            defer {
                executionStage = previous
                updateRuntimeErrorContext()
            }
            return work()
        }
    }

    private func updateRuntimeErrorContext() {
        context.setObject([
            "stage": executionStage,
            "sourceName": bookSource?.bookSourceName ?? "?",
            "sourceId": Self.redactedSourceIdentifier(bookSource?.bookSourceUrl),
        ], forKeyedSubscript: "__yueduLegadoErrorContext" as NSString)
    }

    private static func redactedSourceIdentifier(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "?" }
        guard var components = URLComponents(string: rawValue), components.host != nil else {
            return String(rawValue.prefix(160))
        }
        components.query = nil
        components.fragment = nil
        return String((components.string ?? rawValue).prefix(160))
    }

    /// Evaluate JavaScript code and return the result as a string.
    /// Returns `nil` on JS error, timeout, or if the result is `undefined`/`null`.
    func evaluate(_ script: String) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            let prepared = Self.prepareSourceJS(script)
            guard let value = context.evaluateScript(prepared) else { return nil }
            return extractString(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Evaluate with a `result` variable pre-set (Legado convention:
    /// the previous rule step's output is available as `result` in JS).
    func evaluate(_ script: String, result: String?) -> String? {
        evaluate(script, result: result as Any?, bindings: [:])
    }

    /// Evaluate with an arbitrary `result` value and extra bindings. JSON strings
    /// are exposed to JS as objects so rules can use `result.book_id` after
    /// a `$.data` extraction, matching Legado's dynamic result semantics.
    func evaluate(_ script: String, result: Any?, bindings: [String: Any] = [:]) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            setResult(result)
            let restoreJava = bindGlobals(bindings, converting: true)
            defer { restoreJava() }
            let prepared = Self.prepareSourceJS(script)
            guard let value = context.evaluateScript(prepared) else { return nil }
            return extractString(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// A rule step's script (`@js:` / `<js>`): `evaluateIsolated`, except that a jsoup
    /// `Element`/`Elements` the script returns stays elements for the next step, as in Legado
    /// (`AnalyzeRule.evalJS` returns the Rhino value). Every other value is its string.
    func evaluateRuleStep(_ script: String, result: Any?, bindings: [String: Any] = [:]) -> Any? {
        let isolated = Self.isolatedSourceJS(script)
        switch onJSQueueWithTimeout({ [self] () -> Any? in
            lastError = nil
            setResult(result)
            let restoreJava = bindGlobals(bindings, converting: true)
            defer { restoreJava() }
            guard let value = context.evaluateScript(isolated) else { return nil }
            if lastError == nil, let elements = LegadoJsoupElement.ruleValue(from: value) {
                return elements
            }
            return extractString(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Executes `loginCheckJs` with Legado's response-shaped `result`. When the
    /// script returns another StrResponse, use it; scalar/undefined completion
    /// values mean the script only performed side effects (for example refreshing
    /// a login header), so the original response remains authoritative.
    ///
    /// The check runs once per response, so it runs in a scope of its own
    /// (`isolatedSourceJS`): 三爱小说 (YCK1331) opens it with `let url = result.url()`, and
    /// a second response's check met the first one's `url` in the shared global scope.
    func evaluateResponseScript(
        _ script: String,
        response: LegadoStrResponse,
        bindings: [String: Any] = [:]
    ) -> LegadoStrResponse {
        let isolated = Self.isolatedSourceJS(script)
        switch onJSQueueWithTimeout({ [self] in
            lastError = nil
            setResult(response)
            let restoreJava = bindGlobals(bindings, converting: false)
            defer { restoreJava() }
            guard let value = context.evaluateScript(isolated),
                  lastError == nil,
                  !value.isUndefined,
                  !value.isNull,
                  let replacement = value.toObject() as? LegadoStrResponse else {
                return response
            }
            return replacement
        }) {
        case .completed(let result): return result
        case .timedOut: return response
        }
    }

    /// Normalizes Android/Rhino-isms that JavaScriptCore rejects, so source rule JS authored for
    /// Legado-on-Android compiles on iOS. Applied to every rule-JS evaluation path.
    private static func prepareSourceJS(_ script: String) -> String {
        LegadoRhinoNormalizer.normalize(script).source
    }

    /// `prepareSourceJS` in a scope of its own (`LegadoRuleScope`), as Legado evaluates
    /// every script in a fresh runtime scope (`RhinoScriptEngine.getRuntimeScope`): a
    /// top-level `let url` in one script never meets another's, and a rule's `var d` never
    /// meets jsLib's `let d`. The script answers with its completion value as Rhino computes
    /// it (`LegadoCompletionValue`), or with a top-level `return`, which Rhino accepts. The
    /// text is built once per script; rule scripts run once per item.
    private static func isolatedSourceJS(_ script: String) -> String {
        if let built = isolatedScripts.text(for: script) { return built }
        let prepared = LegadoRhinoNormalizer.normalize(script, evalWrapper: LegadoRuleScope.evalWrapper).source
        let built = LegadoRuleScope.payload(for: prepared)
        isolatedScripts.store(built, for: script)
        return built
    }

    private static let isolatedScripts = IsolatedScriptTexts()

    /// What a rule script's direct eval compiles for `code` (`LegadoRuleScope.evalSource`),
    /// built once per code: a search script evaluates the same decoder for every request.
    fileprivate static func ruleEvalSource(_ code: String) -> String {
        if let built = ruleEvalTexts.text(for: code) { return built }
        let built = LegadoRuleScope.evalSource(for: code)
        ruleEvalTexts.store(built, for: code)
        return built
    }

    private static let ruleEvalTexts = IsolatedScriptTexts()

    /// Source script → what `isolatedSourceJS` (or `ruleEvalSource`) runs for it. Bounded:
    /// emptied when full, since a source's scripts are a few dozen and a reading session
    /// meets a few sources.
    private final class IsolatedScriptTexts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String: String] = [:]
        private static let capacity = 512

        func text(for script: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return texts[script]
        }

        func store(_ text: String, for script: String) {
            lock.lock()
            defer { lock.unlock() }
            if texts.count >= Self.capacity { texts.removeAll(keepingCapacity: true) }
            texts[script] = text
        }
    }

    /// Evaluate with multiple bindings injected into the context before execution.
    func evaluate(_ script: String, bindings: [String: Any]) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            let restoreJava = bindGlobals(bindings, converting: false)
            defer { restoreJava() }
            guard let val = context.evaluateScript(Self.prepareSourceJS(script)) else { return nil }
            return extractString(from: val)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Evaluate a rule snippet in a scope of its own (`isolatedSourceJS`), so nothing one
    /// Legado rule segment declares or assigns reaches later segments or jsLib.
    func evaluateIsolated(_ script: String, result: Any?, bindings: [String: Any] = [:]) -> String? {
        evaluate(Self.isolatedSourceJS(script), result: result, bindings: bindings)
    }

    func evaluateIsolated(_ script: String, bindings: [String: Any]) -> String? {
        evaluate(Self.isolatedSourceJS(script), bindings: bindings)
    }

    /// `evaluateIsolated(_:bindings:)` with `overlay` read in place of the source's stored
    /// variable for this one evaluation, and never stored (unified library 5d-5:
    /// `LegadoSourceBridge.withVariableOverlay`). The overlay is put in place on the JS queue,
    /// around the script alone.
    func evaluateIsolated(_ script: String, bindings: [String: Any], variableOverlay overlay: [String: String]) -> String? {
        guard !overlay.isEmpty else { return evaluateIsolated(script, bindings: bindings) }
        switch onJSQueueWithTimeout({ [self] () -> String? in
            LegadoSourceBridge.withVariableOverlay(overlay) { evaluateIsolated(script, bindings: bindings) }
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Evaluate a script whose result is BYTES (Legado image-decode convention:
    /// `result` holds the raw bytes, the script returns decoded bytes). The
    /// input bytes are exposed as a JS number array (0–255) that also answers the
    /// java.io.InputStream reads (`__yueduByteInputStream`); the return value
    /// may be a number array (Java byte semantics tolerated) or a base64 string.
    func evaluateBytes(_ script: String, data: Data, bindings: [String: Any] = [:]) -> Data? {
        let numbers = data.map { NSNumber(value: $0) }
        switch onJSQueueWithTimeout({ [self] () -> Data? in
            lastError = nil
            let input: JSValue = JSValue(object: numbers, in: context)
            let result: JSValue = context.objectForKeyedSubscript("__yueduByteInputStream")
                .call(withArguments: [input])
            context.setObject(result, forKeyedSubscript: "result" as NSString)
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            let prepared = Self.prepareSourceJS(script)
            guard let value = context.evaluateScript(prepared) else { return nil }
            let bytes = Self.extractBytes(from: value)
            if bytes == nil, lastError == nil, !value.isUndefined, !value.isNull {
                lastError = "Image decode result must contain finite bytes and fit within 32 MiB"
            }
            return bytes
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    private static func extractBytes(from value: JSValue) -> Data? {
        if value.isUndefined || value.isNull { return nil }
        if value.isArray {
            // JSValue.toArray recursively bridges the entire graph to NSArray.
            // A sparse/cyclic result or an enormous declared length can trap in
            // Foundation before a Swift cast can reject it. Decode scalar bytes
            // directly on the JS queue, with the image payload bounded to 32 MiB.
            guard let lengthValue = value.forProperty("length") else { return nil }
            let length = lengthValue.toDouble()
            guard length.isFinite, length > 0, length <= 32 * 1024 * 1024,
                  length.rounded(.towardZero) == length else { return nil }
            var data = Data(capacity: Int(length))
            for index in 0..<Int(length) {
                guard let element = value.atIndex(index), element.isNumber else { return nil }
                let number = element.toDouble()
                guard number.isFinite else { return nil }
                // Java signed bytes and JS unsigned bytes share the same low byte.
                let byte = Int(number.rounded(.towardZero).truncatingRemainder(dividingBy: 256))
                data.append(UInt8(truncatingIfNeeded: byte))
            }
            return data.isEmpty ? nil : data
        }
        if value.isString, let string = value.toString() {
            if let decoded = Data(base64Encoded: string), !decoded.isEmpty {
                return decoded
            }
            let utf8 = Data(string.utf8)
            return utf8.isEmpty ? nil : utf8
        }
        return nil
    }

    /// Reset the context — clears all JS variables and re-injects the bridge.
    func reset() {
        onJSQueue {
            let ctx = JSContext()!
            configureContext(ctx, bridges: withQueueLock { currentBridges })
            withQueueLock { self.context = ctx }
            lastError = nil
        }
    }

    /// Monotonically increasing generation counter. Incremented on `resetEngine()`.
    /// `ModernParserBridge` uses this to know when to re-evaluate jsLib.
    private(set) var generation: UInt64 = 0

    /// Hard-reset the engine by creating a fresh serial queue and JSContext.
    /// Used after a JS evaluation timeout to break free from a hung script;
    /// the old queue and context are abandoned and the script keeps running on them.
    ///
    /// Nothing the abandoned script can reach is the new context's:
    /// - the new context gets its own `java`, `source`, `book` and `chapter` bridges — `book`
    ///   and `chapter` as copies of what the old ones hold, `source` with the same handlers;
    /// - the old queue keeps its generation mark, so its calls back into the engine
    ///   (`source.evalJS`, `java.getString`) queue behind the new jobs (`isOnCurrentJSQueue`),
    ///   and the jobs queued behind the hung script never run (`onJSQueueWithTimeout`);
    /// - its exceptions are not the engine's `lastError` (`configureContext`).
    ///
    /// Resets only `staleGeneration`: every job queued behind the hung script times out too,
    /// and those must not reset the queue that replaced it.
    private func resetEngine(abandoning staleGeneration: UInt64) {
        let (old, isStale) = withQueueLock { (currentBridges, generation == staleGeneration) }
        guard isStale else { return }
        let label = "com.yuedu.jsengine.\(UUID().uuidString.prefix(8))"
        let newQueue = DispatchQueue(label: label, qos: .userInitiated)
        let newContext = JSContext()!
        let bridges = ContextBridges(
            java: LegadoJSBridge(),
            source: old.source.replacementForNewContext(),
            book: old.book.replacementForNewContext(),
            chapter: old.chapter.replacementForNewContext()
        )
        configureContext(newContext, bridges: bridges)

        let published: Bool = withQueueLock {
            guard generation == staleGeneration else { return false }
            generation += 1
            newQueue.setSpecific(key: jsQueueKey, value: generation)
            // Under the lock: a delegate set on the engine during this reset is either read
            // here or forwarded by its `didSet` to the bridge published here.
            configureJavaBridge(bridges.java)
            currentBridges = bridges
            jsQueue = newQueue
            context = newContext
            return true
        }
        if published { lastError = nil }
    }

    /// Whether `handingOverVideoEpisode` is running, so a reset's new `java` bridge hands
    /// over too. Guarded by `queueLock`.
    private var isHandingOverVideoEpisode = false

    /// Runs `body` — the content rule of the video episode being played — with
    /// `java.openVideoPlayer` and `java.startBrowser` handing their link or page to the caller
    /// instead of opening a player or a sheet (`LegadoJSBridge.videoEpisodeHandover`).
    func handingOverVideoEpisode<T>(_ body: () throws -> T) rethrows -> (T, LegadoJSBridge.VideoEpisodeHandover) {
        onJSQueue {
            withQueueLock { isHandingOverVideoEpisode = true }
            bridge.videoEpisodeHandover = .init()
        }
        defer {
            onJSQueue {
                withQueueLock { isHandingOverVideoEpisode = false }
                bridge.videoEpisodeHandover = nil
            }
        }
        let result = try body()
        return (result, onJSQueue { bridge.videoEpisodeHandover ?? .init() })
    }

    func setBookBridge(_ bridge: LegadoBookBridge) {
        onJSQueue {
            self.bookBridge = bridge
            context.setObject(bridge, forKeyedSubscript: "book" as NSString)
        }
    }

    func setChapterBridge(_ bridge: LegadoChapterBridge) {
        onJSQueue {
            self.chapterBridge = bridge
            context.setObject(bridge, forKeyedSubscript: "chapter" as NSString)
            injectChapterGlobals(bridge, into: context)
        }
    }

    // MARK: - Private Helpers

    /// Configure a fresh JSContext with the bridge object and helpers.
    private func configureContext(_ ctx: JSContext, bridges: ContextBridges) {
        // This context's own bridges: every block below captures these, never the engine's
        // current ones, which a timeout's reset replaces while this context may still run.
        let bridge = bridges.java
        let sourceBridge = bridges.source

        // Exception handler
        ctx.exceptionHandler = { [weak self] thrower, exception in
            let msg = exception?.toString() ?? "Unknown JS error"
            // A context a timeout abandoned runs on beside the new one: its exception is not
            // the current job's error, and writing `lastError` from its thread races the job.
            guard let self, self.withQueueLock({ self.context === thrower }) else {
                AppLogger.parse("Book source rule JS exception in a context a timeout abandoned", context: [
                    "error": msg
                ])
                return
            }
            self.lastError = msg
            self.withQueueLock {
                self.uncaughtExceptionCount += 1
                self.recentUncaughtExceptions.append(msg)
                if self.recentUncaughtExceptions.count > 8 { self.recentUncaughtExceptions.removeFirst() }
            }
            if msg.contains("eval() is disabled") {
                AppLogger.security("Book source JS attempted to use disabled eval(); blocked", context: ["error": msg])
            }
            // Surface uncaught rule-JS exceptions to the device log (Console) so book
            // source failures (TOC/content not loading, etc.) are diagnosable without
            // the in-app debug engine. Only uncaught exceptions reach this handler.
            // `sourceUrl` names the source exactly: packs repeat names (dozens of 笔趣阁), and
            // `scripts/legado-compat` attributes each exception to its source by this key.
            AppLogger.parse("Book source rule JS exception", context: [
                "source": self.bookSource?.bookSourceName ?? "?",
                "sourceUrl": self.bookSource?.bookSourceUrl ?? "?",
                "error": msg
            ])
            self.errorHandler?(msg, "js exception")
            #if DEBUG
            print("[JSCoreEngine] JS Error: \(msg)")
            #endif
        }

        // Inject the `java` bridge object
        ctx.setObject(bridge, forKeyedSubscript: "java" as NSString)
        // JSExport cannot expose two `showBrowser` overloads under one JavaScript name.
        // Keep the native two-argument method for ordinary URLs, and route Legado's
        // four-argument source-page form through a uniquely named native block.
        let showBrowserPageBlock: @convention(block) (String, String, String, String) -> Void = {
            [weak bridge] url, html, injectedJavaScript, configurationJSON in
            bridge?.browserPagePresentHandler?(
                LegadoBrowserPageRequest(
                    baseURL: url,
                    // JavaScript null crosses as "" (the shim's `String(x == null ? '' : x)`).
                    html: html.isEmpty ? nil : html,
                    injectedJavaScript: injectedJavaScript,
                    configurationJSON: configurationJSON
                )
            )
        }
        ctx.setObject(showBrowserPageBlock, forKeyedSubscript: "__yueduShowBrowserPage" as NSString)
        ctx.evaluateScript("""
            (function () {
                var nativeShowBrowser = java.showBrowser.bind(java);
                java.showBrowser = function (url, titleOrHTML, injectedJavaScript, configurationJSON) {
                    if (arguments.length >= 3) {
                        return __yueduShowBrowserPage(
                            String(url == null ? '' : url),
                            String(titleOrHTML == null ? '' : titleOrHTML),
                            String(injectedJavaScript == null ? '' : injectedJavaScript),
                            String(configurationJSON == null ? '' : configurationJSON)
                        );
                    }
                    return nativeShowBrowser(url, titleOrHTML);
                };
            })();
        """)
        // Legado overloads `startBrowserAwait(url, title[, refetchAfterSuccess[, html]])` and
        // `startBrowser(url, title[, html])` by arity, and JSExport cannot: the Swift overloads
        // land on one JavaScript name, so which one a call reached — and whether an omitted
        // `refetchAfterSuccess` meant Legado's `true` — was up to JavaScriptCore. An absent
        // `html` crosses as "" (a JavaScript null would arrive as the string "null").
        let startBrowserAwaitBlock: @convention(block) (String, String, Bool, String) -> LegadoStrResponse = {
            [weak bridge] url, title, refetchAfterSuccess, html in
            bridge?.startBrowserAwait(url, title, refetchAfterSuccess, html.isEmpty ? nil : html)
                ?? LegadoStrResponse(url: url, body: "")
        }
        let startBrowserBlock: @convention(block) (String, String, String) -> Void = {
            [weak bridge] url, title, html in
            bridge?.startBrowser(url, title, html.isEmpty ? nil : html)
        }
        ctx.setObject(startBrowserAwaitBlock, forKeyedSubscript: "__yueduStartBrowserAwait" as NSString)
        ctx.setObject(startBrowserBlock, forKeyedSubscript: "__yueduStartBrowser" as NSString)
        ctx.evaluateScript("""
            (function (nativeStartBrowserAwait, nativeStartBrowser) {
                function text(value) { return String(value == null ? '' : value); }
                java.startBrowserAwait = function (url, title, refetchAfterSuccess, html) {
                    return nativeStartBrowserAwait(
                        text(url),
                        text(title),
                        arguments.length < 3 ? true : !!refetchAfterSuccess,
                        text(html)
                    );
                };
                java.startBrowser = function (url, title, html) {
                    nativeStartBrowser(text(url), text(title), text(html));
                };
            })(__yueduStartBrowserAwait, __yueduStartBrowser);
            delete __yueduStartBrowserAwait;
            delete __yueduStartBrowser;
        """)
        // JavaScriptCore performs an Objective-C receiver check when an exported
        // bridge method is called as a detached function (`const b64 =
        // java.base64Encode; b64(...)`). Legado sources commonly use that form;
        // install closures for the string codecs so those calls retain a valid
        // receiver instead of throwing `self type check failed`.
        let base64EncodeBlock: @convention(block) (String) -> String = { [weak bridge] value in
            bridge?.base64Encode(value) ?? ""
        }
        let base64DecodeBlock: @convention(block) (String) -> String = { [weak bridge] value in
            bridge?.base64Decode(value) ?? ""
        }
        ctx.setObject(base64EncodeBlock, forKeyedSubscript: "__yueduBase64Encode" as NSString)
        ctx.setObject(base64DecodeBlock, forKeyedSubscript: "__yueduBase64Decode" as NSString)
        ctx.evaluateScript("""
            java.base64Encode = __yueduBase64Encode;
            java.base64Decode = __yueduBase64Decode;
            delete __yueduBase64Encode;
            delete __yueduBase64Decode;
        """)
        let getCookieBlock: @convention(block) (String, JSValue?) -> String = { [weak bridge] url, keyValue in
            guard let bridge else { return "" }
            let key: String
            if let keyValue, !keyValue.isUndefined, !keyValue.isNull {
                key = keyValue.toString() ?? ""
            } else {
                key = ""
            }
            return key.isEmpty ? bridge.getCookie(url) : bridge.getCookieValue(url, key)
        }
        ctx.setObject(getCookieBlock, forKeyedSubscript: "__yueduGetCookie" as NSString)
        ctx.evaluateScript("java.getCookie = __yueduGetCookie;")

        // Inject the `cookie` bridge object (get/set/remove via HTTPCookieStorage)
        ctx.setObject(cookieBridge, forKeyedSubscript: "cookie" as NSString)

        // SwiftSoup backing for the `org.jsoup.*` polyfill installed below.
        // The context retains its own DOM bridge/cache. A timeout can leave the old
        // context running, so a replacement context must not share mutable SwiftSoup nodes.
        ctx.setObject(LegadoJsoupBridge(), forKeyedSubscript: "__yueduJsoup" as NSString)

        // Inject `source` as a full bridge object (Legado-compatible)
        injectSourceObject(sourceBridge, into: ctx)

        // Inject `cache` bridge object (persistent + memory key-value store)
        ctx.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)

        // Inject mutable book/chapter bridge objects used by Legado rule JS.
        ctx.setObject(bridges.book, forKeyedSubscript: "book" as NSString)
        ctx.setObject(bridges.chapter, forKeyedSubscript: "chapter" as NSString)
        injectChapterGlobals(bridges.chapter, into: ctx)
        // Rhino, which runs Legado's rules, gives every bean property its accessor methods as
        // well: 番茄听书 (YCK 1330) calls `book.setType(32)` and 黄果短剧 calls
        // `source.getBookSourceUrl()`, which threw `is not a function` here — JSExport exports
        // the property alone. The methods go on the prototype that every `book`, `chapter`
        // and `source` of this context shares, so a later `setBookBridge` or a source switch
        // keeps them; a method the bridge declares itself (`getVariable`, `getKey`) is left
        // as it is.
        ctx.evaluateScript("""
            (function () {
              function addAccessors(object) {
                var proto = object && Object.getPrototypeOf(object);
                if (!proto) return;
                Object.getOwnPropertyNames(proto).forEach(function (name) {
                  var d = Object.getOwnPropertyDescriptor(proto, name);
                  if (!d || (!d.get && !d.set)) return;
                  var cap = name.charAt(0).toUpperCase() + name.slice(1);
                  if (d.get && !(('get' + cap) in proto)) {
                    proto['get' + cap] = function () { return this[name]; };
                  }
                  if (d.set && !(('set' + cap) in proto)) {
                    proto['set' + cap] = function (value) { this[name] = value; };
                  }
                });
              }
              addAccessors(book);
              addAccessors(chapter);
              addAccessors(source);
            })();
            """)

        // Inject a top-level `print` that delegates to java.log
        let printBlock: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            print("[JS] \(msg)")
            #endif
        }
        ctx.setObject(printBlock, forKeyedSubscript: "print" as NSString)

        // Note: eval() is intentionally LEFT ENABLED. The sandbox boundary for book
        // source JS is the bridge layer (java.*/source.*/cookie.*): JavaScriptCore code
        // can only reach the network/filesystem through those bridges, and eval()'d code
        // is confined to exactly the same surface as ordinary code. Many legitimate Legado
        // sources require eval — e.g. obfuscated jsLib loaders (`eval(java.importScript(url))`)
        // and explore builders (`eval('sort'+i+'.push(json)')`). Disabling it broke those
        // sources without adding real isolation, so native eval is used.
        //
        // The source an eval compiles is Rhino source as much as a rule is, so
        // `LegadoRhinoNormalizer` wraps every direct `eval(x)` argument in this, and a string
        // gets the same rewrites before JavaScriptCore compiles it.
        let rhinoSourceBlock: @convention(block) (JSValue) -> JSValue = { value in
            guard value.isString, let source = value.toString() else { return value }
            return JSValue(object: LegadoRhinoNormalizer.normalize(source).source, in: value.context)
        }
        ctx.setObject(rhinoSourceBlock, forKeyedSubscript: "__yueduRhinoSource" as NSString)

        // A rule script's direct eval passes its argument through this instead
        // (`LegadoRuleScope.evalWrapper`): what the code declares in the script's function is
        // the script's for `Function` code too, as on Rhino, through `__yueduRuleNames`.
        let ruleEvalBlock: @convention(block) (JSValue) -> JSValue = { value in
            guard value.isString, let code = value.toString() else { return value }
            return JSValue(object: JSCoreEngine.ruleEvalSource(code), in: value.context)
        }
        ctx.setObject(ruleEvalBlock, forKeyedSubscript: LegadoRuleScope.evalWrapper as NSString)
        ctx.evaluateScript(LegadoRuleScope.registry)

        // The normalizer rewrites a no-argument `.length()` call to this: a Java String's
        // `length()` (every `java.*` result under Rhino) is the JS string's `length`, and an
        // object that really has a `length()` method still gets it called.
        ctx.evaluateScript("""
            Object.defineProperty(Object.prototype, '__yueduJavaLength', {
                value: function () {
                    var length = this.length;
                    return typeof length === 'function' ? length.call(this) : length;
                },
                enumerable: false, configurable: true, writable: true
            });
        """)

        // Under Rhino a `java.*` call returns a wrapped `java.lang.String`, and its
        // `replaceAll(/re/, s)` is Java's `String.replaceAll(String, String)`: the RegExp
        // converts to its `/source/flags` text and is read as a Java regex, and nothing throws
        // (rhino 1.8.1, `oracle/cases/string-replaceall-regexp.json`). Our strings are all JS
        // strings, and JS throws on a non-global RegExp — as Rhino does for a JS string, so a
        // source that works on Legado made this call on a Java String. Only that call takes
        // Java's meaning: a global RegExp or a string pattern works on both engines, and our
        // strings carry no mark of having come from Java (string patterns on `java.*` results
        // are Java regexes on Legado and stay literal here). 紫云宫 (YCK1330) strips
        // zero-width characters from each decrypted chapter with one.
        let javaReplaceAllBlock: @convention(block) (String, String, String) -> JSValue? = { text, pattern, replacement in
            guard let context = JSContext.current() else { return nil }
            guard let replaced = RegexCache.shared.replaceMatches(
                in: text, pattern: pattern, replacement: replacement
            ) else {
                context.exception = JSValue(
                    newErrorFromMessage: "java.util.regex.PatternSyntaxException: \(pattern)", in: context
                )
                return nil
            }
            return JSValue(object: replaced, in: context)
        }
        ctx.setObject(javaReplaceAllBlock, forKeyedSubscript: "__yueduJavaReplaceAll" as NSString)
        ctx.evaluateScript("""
            (function () {
                var replaceAll = String.prototype.replaceAll;
                Object.defineProperty(String.prototype, 'replaceAll', {
                    value: function (pattern, replacement) {
                        if (pattern instanceof RegExp && !pattern.global) {
                            return __yueduJavaReplaceAll(String(this), String(pattern), String(replacement));
                        }
                        return replaceAll.call(this, pattern, replacement);
                    },
                    enumerable: false, configurable: true, writable: true
                });
            })();
        """)

        // The normalizer rewrites an E4X descendant access (`x..name`) to a member whose key is
        // this call. Legado's Rhino parses E4X (`FEATURE_E4X` is on for `VERSION_ES6`) but ships
        // without `rhino-xml`, so no XML object exists and evaluating one always throws
        // `TypeError: … is not an xml object.` (verified against rhino 1.8.1).
        ctx.evaluateScript("""
            Object.defineProperty(this, '__yueduE4XDescendants', {
                value: function (name) {
                    throw new TypeError('..' + name + ': not an xml object.');
                },
                enumerable: false, configurable: false, writable: false
            });
        """)

        // JSON is always natively available in JSContext — this guard is a safety net only.
        // The eval() fallback from the original Legado port has been removed (eval is disabled).
        ctx.evaluateScript("""
            if (typeof JSON === 'undefined') {
                var JSON = {
                    parse: function(s) { return null; },
                    stringify: function(o) { return ''; }
                };
            }
        """)

        // `java` in an AnalyzeUrl's own scripts (`bindGlobals`): the bridge, with the members the
        // AnalyzeUrl's view has — `url`, `ruleUrl`, `headerMap`, `getStrResponse`, `initUrl` —
        // taken from the view. Methods are bound to whichever object answered, because a JSExport
        // method only runs against its own wrapper. `initUrl` is the view's `reinitUrl`: an
        // `init…` selector is never exported as a method (`LegadoAnalyzeUrlScriptExport`).
        //
        // The native `Proxy` is captured now, before any source script runs: a source's
        // top-level `var Proxy = …` replaces the global (存档书库's header script, YCK1331),
        // and Legado's `java` is a Java object no source script can reach that way.
        ctx.evaluateScript("""
            (function (NativeProxy) { Object.defineProperty(this, '__yueduAnalyzeUrlJava', {
                enumerable: false, configurable: false, writable: false,
                value: function (bridge, view) {
                    var exported = function (name) { return name === 'initUrl' ? 'reinitUrl' : name; };
                    return new NativeProxy(bridge, {
                        get: function (target, name) {
                            var own = exported(name);
                            var owner = (own in view) ? view : target;
                            var value = owner === view ? view[own] : target[name];
                            // A Java package the interop runtime hangs on the bridge
                            // (`java.security`, `java.lang`) is callable but is navigated, not
                            // called: bound, it lost its classes, and `.bind` itself resolved as
                            // a package — 酷狗小说's jsLib signer threw
                            // `Packages.java.security.bind` and sent `signature=`.
                            if (typeof value === 'function' && value.__members === undefined) return value.bind(owner);
                            return value;
                        },
                        has: function (target, name) { return (exported(name) in view) || (name in target); }
                    });
                }
            }); }).call(this, Proxy);
        """)

        // Legado/Rhino exposes a JSON response dynamically: source JS can read
        // `result.field`, while `String(result)` / `result.toString()` still yield
        // the original JSON text. A plain JavaScriptCore object loses that second
        // half of the contract and becomes "[object Object]". Build the parsed value
        // inside JS so arrays keep their native methods, then attach non-enumerable
        // primitive conversion hooks that preserve the exact response string.
        // JSON.stringify remains structural because the hooks are non-enumerable.
        //
        // `text`, when given, is what the value reads as instead: an object a JSONPath rule
        // selected is a `LinkedHashMap` in Rhino, whose string is `{id=12, name=…}`
        // (`OrderedJSON.javaText`). Such a map (`isJavaMap`) also answers `java.util.Map`'s
        // methods, as Rhino's `FEATURE_ENABLE_JAVA_MAP_ACCESS` (on in Legado) lets it.
        ctx.evaluateScript("""
            (function () {
                var __nativeParse = JSON.parse;
                Object.defineProperty(this, '__yueduWrapJSONResult', {
                    enumerable: false,
                    configurable: false,
                    writable: false,
                    value: function (raw, text, isJavaMap) {
                        var parsed = __nativeParse(raw);
                        if (parsed === null || typeof parsed !== 'object') return parsed;
                        var shown = typeof text === 'string' ? text : raw;
                        var asString = function () { return shown; };
                        if (!Object.prototype.hasOwnProperty.call(parsed, 'toString')) {
                            Object.defineProperty(parsed, 'toString', {
                                value: asString, enumerable: false, configurable: true
                            });
                        }
                        if (!Object.prototype.hasOwnProperty.call(parsed, 'valueOf')) {
                            Object.defineProperty(parsed, 'valueOf', {
                                value: asString, enumerable: false, configurable: true
                            });
                        }
                        if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                            Object.defineProperty(parsed, Symbol.toPrimitive, {
                                value: asString, enumerable: false, configurable: true
                            });
                        }
                        // In Rhino the page is a string, so a script may test it as one before
                        // parsing: Linpx (YCK1330 index 95) runs `result.startsWith("<!DOCTYPE
                        // html>")` on its JSON detail page. An object keeps its fields and also
                        // answers the string methods, on the original text; an array keeps its
                        // own `indexOf` / `slice` / `includes`.
                        if (isJavaMap === true && !Array.isArray(parsed)) __yueduJavaMap(parsed);
                        if (!Array.isArray(parsed)) {
                            Object.getOwnPropertyNames(String.prototype).forEach(function (name) {
                                if (name === 'constructor' || name === 'length' || name in parsed) return;
                                var method = String.prototype[name];
                                if (typeof method !== 'function') return;
                                Object.defineProperty(parsed, name, {
                                    value: function () { return method.apply(shown, arguments); },
                                    enumerable: false, configurable: true, writable: true
                                });
                            });
                        }
                        return parsed;
                    }
                });
                // An object a script hands back to `JSON.parse` is a page it was given already
                // parsed (above), and stays that object. A `String` object is text: Rhino's
                // `JSON.parse` reads `ScriptRuntime.toString` of its argument, and `String(x)`
                // inside `with (JavaImporter(java.lang))` is `java.lang.String`'s constructor,
                // which `JavaString` answers with a boxed string. 书香之家 (YCK1331) parses
                // `String(java.aesBase64DecodeToByteArray(…))` that way.
                JSON.parse = function (value, reviver) {
                    if (value !== null && typeof value === 'object' && !(value instanceof String)) {
                        return value;
                    }
                    return __nativeParse(value, reviver);
                };
            })();
        """)

        // Legado helper functions frequently used by complex sources.
        // getArgument(key) reads source-level variables; setArgument(key, val) writes them.
        ctx.evaluateScript("""
            function getArgument(key) { return java.get(key) || ''; }
            function setArgument(key, value) { java.put(key, value); }
        """)

        // java.util.Map compatibility shim.
        // Legado runs on Rhino, where `source.getLoginInfoMap()` / `source.getHeaderMap()`
        // return real `java.util.Map` instances. Source jsLib routinely calls `.get(key)`
        // / `.put(key,val)` / `.containsKey(key)` on them (e.g. `getConfigValue` →
        // `infomap.get(key)`). JavaScriptCore bridges a Swift dictionary to a plain JS
        // object with no such methods, so those calls throw `… is not a function` and
        // abort the whole rule (symptom: book opens but TOC/content silently fail).
        // `__yueduJavaMap` augments a plain object in place with the Map methods as
        // non-enumerable properties, so `obj[key]` / `for..in` / `Object.keys` are
        // unaffected while `.get()` etc. work. An entry of the same name wins, as it does
        // in Rhino's `NativeJavaMap`: a JSON item with a `size` field reads `result.size`
        // as the field.
        ctx.evaluateScript("""
            function __yueduJavaMap(o) {
                o = o || {};
                function def(name, fn) {
                    if (Object.prototype.hasOwnProperty.call(o, name)) return;
                    Object.defineProperty(o, name, { value: fn, enumerable: false, configurable: true });
                }
                def('get', function (k) { var v = o[k]; return v === undefined ? null : v; });
                def('put', function (k, v) { o[k] = v; return v; });
                def('containsKey', function (k) { return Object.prototype.hasOwnProperty.call(o, k); });
                def('remove', function (k) { var v = o[k]; delete o[k]; return v === undefined ? null : v; });
                def('size', function () { return Object.keys(o).length; });
                def('isEmpty', function () { return Object.keys(o).length === 0; });
                def('keySet', function () { return Object.keys(o); });
                def('values', function () { return Object.keys(o).map(function (k) { return o[k]; }); });
                // LYC sources persist filter metadata through infoMap.save().
                // Their map is process-local here, so saving is intentionally a no-op.
                def('save', function () { return o; });
                return o;
            }
        """)

        // java.util.List compatibility. Rhino exposes both native Java lists (including
        // AnalyzeRule.getElements()) and JSON arrays with Java collection methods. JSC
        // exposes both as ordinary arrays, so source rules calling `.size()`, `.get()` or
        // `.add()` otherwise abort even though the rows are present. Keep these methods
        // non-enumerable so JSON.stringify, for..in and native array iteration are unchanged.
        ctx.evaluateScript("""
            (function (prototype) {
                function def(name, fn) {
                    if (typeof prototype[name] !== 'function') {
                        Object.defineProperty(prototype, name, {
                            value: fn, enumerable: false, configurable: true, writable: true
                        });
                    }
                }
                def('size', function () { return this.length; });
                def('get', function (index) {
                    index = Number(index);
                    return index >= 0 && index < this.length ? this[index] : null;
                });
                def('set', function (index, value) {
                    index = Number(index);
                    var previous = this.get(index);
                    this[index] = value;
                    return previous;
                });
                def('add', function (indexOrValue, value) {
                    if (arguments.length >= 2) {
                        this.splice(Number(indexOrValue), 0, value);
                    } else {
                        this.push(indexOrValue);
                    }
                    return true;
                });
                def('addAll', function (values) {
                    if (values == null) return false;
                    var incoming = Array.prototype.slice.call(values);
                    if (incoming.length === 0) return false;
                    this.push.apply(this, incoming);
                    return true;
                });
                def('toArray', function () { return this.slice(); });
                def('isEmpty', function () { return this.length === 0; });
                def('contains', function (value) { return this.indexOf(value) >= 0; });
            })(Array.prototype);
        """)

        // An image-decode `result` is a byte array that also reads like a java.io.InputStream.
        // The Legado forks (legado-E, Sigma, MD3) hand `coverDecodeJs` the cover download's
        // `byteStream()` and every other decode a `byte[]`, so cover rules written for them
        // call `result.readAllBytes()` (🥝猕猴桃漫画, FB-135). The methods go on the one array
        // instance, non-enumerable: rules that index the bytes, XOR them in place or test
        // `typeof x.readAllBytes` on ordinary arrays see no difference.
        ctx.evaluateScript("""
            Object.defineProperty(this, '__yueduByteInputStream', {
                enumerable: false,
                value: function (bytes) {
                    var position = 0;
                    function def(name, fn) {
                        Object.defineProperty(bytes, name, {
                            value: fn, enumerable: false, configurable: true, writable: true
                        });
                    }
                    function take(count) {
                        var end = Math.min(bytes.length, position + Math.max(0, count));
                        var out = Array.prototype.slice.call(bytes, position, end);
                        position = end;
                        return out;
                    }
                    def('available', function () { return Math.max(0, bytes.length - position); });
                    def('readAllBytes', function () { return take(bytes.length - position); });
                    def('readNBytes', function (count) { return take(Number(count) || 0); });
                    def('read', function () {
                        return position < bytes.length ? (Number(bytes[position++]) & 255) : -1;
                    });
                    def('skip', function (count) { return take(Number(count) || 0).length; });
                    def('close', function () {});
                    return bytes;
                }
            });
        """)

        // Luo-Ya-Cheng (洛雅橙/lyc) mod compatibility shim.
        // This must be installed after `__yueduJavaMap`: LYC explore scripts call
        // `infoMap.save()` while assembling their filter rows.
        //
        // `Set` doubles as LYC's key-value setter AND JavaScript's built-in Set
        // constructor. A plain `function Set(key, value)` shadowed the builtin, so any
        // source rule constructing `new Set()` (e.g. 企点 chapterList de-dups volume
        // names this way when 显示卷名 is on) got a method-less object, threw
        // "addedVolumes.has is not a function", and the whole TOC parse aborted
        // (symptom: 目录为空). Worse, the constructor call leaked a
        // `source.put(undefined, undefined)` into the variable store. Keep both callers
        // working: `new Set(...)` / bare `Set()` delegate to the native constructor,
        // while LYC's `Set(key, value)` call form still writes through `source.put`.
        ctx.evaluateScript("""
            function csh() {
                if (typeof source === 'undefined') return;
                var d = {
                    sort: '全部',
                    size: '30',
                    isfinish: 'all',
                    orderBy: 'newest',
                    fmale: '男频',
                    fxy: '0',
                    img: '1',
                    dp: '1',
                    jj: '0',
                    api: '1',
                    lock: '0',
                    zdy: '',
                };
                for (var k in d) {
                    if (!source.get(k)) source.put(k, d[k]);
                }
            }
            function Get(key) {
                if (typeof source !== 'undefined') return source.get(key) || '';
                return '';
            }
            (function (global) {
                var NativeSet = global.Set;
                function lycSet(key, value) {
                    if (new.target || arguments.length === 0) {
                        return arguments.length ? new NativeSet(key) : new NativeSet();
                    }
                    if (typeof source !== 'undefined') source.put(key, value);
                }
                lycSet.prototype = NativeSet.prototype;
                global.Set = lycSet;
            })(this);
            var infoMap = __yueduJavaMap({});
            function createFilter(sort, size, isfinish, orderBy, fmale) {
                // The source's jsLib may replace this fallback with its filter builder.
            }
        """)

        // Legado overloads `java.get` by arity — Rhino dispatches on argument count:
        //   java.get(key)          → the source's variable store
        //   java.get(url, headers) → an HTTP GET returning a response with `.body()`
        // JSExport maps one selector to one JS name, so only the variable getter
        // existed. 同人小说网's 段评 does `java.get(url, {}).body()`; `.body()` on a
        // String threw straight into the rule's own `catch`, which returns the
        // paragraph text unchanged — 段评 silently never appeared.
        // Shadows the exported method with a dispatcher (verified: an own property on
        // a JSExport-backed object wins over its prototype).
        Self.installJavaGetOverload(in: ctx)
        Self.installJavaConnectOverload(in: ctx)
        Self.installJavaHeadAndPostOverloads(in: ctx)
        Self.installJavaElementAccessors(in: ctx)

        // Install the authoritative registry-backed Java/Android contract.
        LegadoJavaInteropRuntime.install(in: ctx)
        updateRuntimeErrorContext()

        // org.jsoup.Jsoup polyfill.
        // Legado Android uses Rhino with full Java interop, so book sources can call
        // `org.jsoup.Jsoup.connect(url).execute().body()` directly. JavaScriptCore has
        // no Java interop, so `org` is undefined → "undefined is not an object" crashes
        // obfuscated content scripts (e.g. 番茄酱's remote `to.js`). `execute()` sends through
        // the bridge's response-shaped requests, so `statusCode()`, `header(name)`, `cookies()`
        // and the final `url()` are the server's; `followRedirects(false)` hands back the 3xx
        // itself, as jsoup does.
        ctx.evaluateScript("""
            (function () {
                function Connection(url) {
                    this._url = String(url || '');
                    this._method = 'GET';
                    this._headers = {};
                    this._data = {};
                    this._timeout = 10000;
                    this._ua = '';
                    this._referrer = '';
                    this._body = null;
                }
                var P = Connection.prototype;
                P.method = function (m) { this._method = (typeof m === 'string') ? m : (m && m.name) || 'GET'; return this; };
                P.header = function (k, v) { this._headers[k] = String(v); return this; };
                P.headers = function (h) { if (h) for (var k in h) this._headers[k] = String(h[k]); return this; };
                P.data = function (k, v) {
                    if (arguments.length === 1 && typeof k === 'object') { for (var key in k) this._data[key] = String(k[key]); }
                    else { this._data[k] = String(v); }
                    return this;
                };
                P.requestBody = function (b) { this._body = (arguments.length === 0) ? null : String(b); return this; };
                P.cookie = function (k, v) { return this; };
                P.ignoreContentType = function (b) { return this; };
                P.timeout = function (ms) { this._timeout = parseInt(ms) || 10000; return this; };
                P.userAgent = function (ua) { this._ua = String(ua); return this; };
                P.referrer = function (r) { this._referrer = String(r); return this; };
                P.followRedirects = function (b) { this._follow = b !== false; return this; };
                P._follow = true;
                P.sslSocketFactory = function () { return this; };
                P.execute = function () { return new Response(this._fetch(), this._url); };
                P.get = function () { this._method = 'GET'; return JsoupParse(this._fetch().body(), this._url); };
                P.post = function () { this._method = 'POST'; return JsoupParse(this._fetch().body(), this._url); };
                // The bridge's StrResponse for this request.
                P._fetch = function () {
                    var url = this._url, pairs = [], hasData = false;
                    for (var k in this._data) { hasData = true; pairs.push(encodeURIComponent(k) + '=' + encodeURIComponent(this._data[k])); }
                    var dataStr = pairs.join('&');
                    var hdrs = this._headers;
                    if (this._ua && !hdrs['User-Agent']) hdrs['User-Agent'] = this._ua;
                    if (this._referrer && !hdrs['Referer']) hdrs['Referer'] = this._referrer;
                    var method = String(this._method || 'GET').toUpperCase();
                    if (method === 'POST' || method === 'PUT' || method === 'PATCH') {
                        var body = this._body || dataStr;
                        if (dataStr && !this._body && !hdrs['Content-Type']) hdrs['Content-Type'] = 'application/x-www-form-urlencoded';
                        // java.post refuses redirects (Legado-E jsoup POST); httpExecute follows them.
                        return (this._follow || method !== 'POST')
                            ? java.httpExecute(method, url, body, hdrs)
                            : java.post(url, body, hdrs);
                    }
                    if (hasData) url += (url.indexOf('?') < 0 ? '?' : '&') + dataStr;
                    if (this._follow) return java.httpExecute(method, url, '', hdrs);
                    return method === 'HEAD' ? java.head(url, hdrs) : java.get(url, hdrs);
                };
                // jsoup `Connection.Response` over the bridge's StrResponse.
                function Response(raw, url) { this._raw = raw; this._url = url; }
                var RP = Response.prototype;
                RP.body = RP.text = RP.html = function () { var b = this._raw.body(); return b == null ? '' : String(b); };
                RP.header = RP.get = function (n) { var v = this._raw.header(String(n)); return v == null ? null : String(v); };
                RP.hasHeader = function (n) { return this._raw.hasHeader(String(n)); };
                RP.headers = function (n) { return this._raw.headers(n); };
                RP.cookie = function (n) { var v = this._raw.cookie(String(n)); return v == null ? null : String(v); };
                RP.cookies = function () { return this._raw.cookies(); };
                RP.statusCode = function () { return this._raw.code(); };
                RP.statusMessage = function () { return this._raw.message(); };
                RP.contentType = function () { return this._raw.contentType(); };
                RP.url = function () { return this._raw.url() || this._url; };
                RP.method = function () { return null; };
                RP.parse = function () { return JsoupParse(this.body(), this.url()); };
                RP.bodyAsBytes = function () { return java.strToBytes(this.body(), 'UTF-8'); };

                // `_n` is a native SwiftSoup node (`LegadoJsoupElement`). JavaScriptCore owns its
                // lifetime, so a selected element stays valid for as long as JS holds it —
                // serialising back to a string between calls would mangle fragments the HTML
                // parser is context-sensitive about (`<body>`, `<td>`, `<li>`, …).
                // The tree is the script's own (see LegadoJsoupElement), so jsoup's mutators
                // change it: `doc.select('.ad').remove()` then `doc.html()` is how sources clean
                // a chapter before reading it.
                // `new org.jsoup.nodes.Element('a')` in a source is jsoup's `Element(String tag)`:
                // a new element of that tag. Everywhere else `node` is a native node.
                function Element(node, baseUrl) {
                    if (typeof node === 'string' || node instanceof String) node = __yueduJsoup.createElement(String(node));
                    this._n = node || null; this._baseUrl = baseUrl || '';
                }
                function isNode(v) { return v != null && typeof v === 'object' && typeof v.isJsoupNode === 'function'; }
                function wrapOne(node, baseUrl) { return node ? new Element(node, baseUrl) : null; }
                function wrap(list, baseUrl) {
                    var out = [];
                    if (list) for (var i = 0; i < list.length; i++) out.push(new Element(list[i], baseUrl));
                    return new Elements(out);
                }
                // jsoup's `Attributes`: iterable `Attribute`s with `key()`/`value()`, plus map reads.
                function Attribute(k, v) { this._k = k; this._v = v; }
                Attribute.prototype.key = Attribute.prototype.getKey = function () { return this._k; };
                Attribute.prototype.value = Attribute.prototype.getValue = function () { return this._v; };
                Attribute.prototype.toString = Attribute.prototype.html = function () { return this._k + '="' + this._v + '"'; };
                function Attributes(list) {
                    var arr = (list || []).map(function (a) { return new Attribute(String(a.key), String(a.value)); });
                    Object.defineProperty(this, '_arr', { value: arr });
                    for (var i = 0; i < arr.length; i++) this[i] = arr[i];
                }
                var AP = Attributes.prototype;
                AP.size = function () { return this._arr.length; };
                AP.isEmpty = function () { return this._arr.length === 0; };
                AP.asList = function () { return this._arr.slice(); };
                AP.get = function (k) { for (var i = 0; i < this._arr.length; i++) if (this._arr[i]._k === String(k)) return this._arr[i]._v; return ''; };
                AP.hasKey = function (k) { for (var i = 0; i < this._arr.length; i++) if (this._arr[i]._k === String(k)) return true; return false; };
                AP.dataset = function () {
                    var out = __yueduJavaMap({});
                    this._arr.forEach(function (a) { if (a._k.indexOf('data-') === 0) out.put(a._k.slice(5), a._v); });
                    return out;
                };
                AP.forEach = function (fn) { this._arr.forEach(fn); };
                AP.iterator = function () { return this._arr[Symbol.iterator](); };
                AP[Symbol.iterator] = function () { return this._arr[Symbol.iterator](); };
                AP.html = AP.toString = function () { return this._arr.map(function (a) { return ' ' + a.html(); }).join(''); };
                Object.defineProperty(AP, 'length', { get: function () { return this._arr.length; }, configurable: true });
                Object.keys(AP).forEach(function (k) { Object.defineProperty(AP, k, { enumerable: false }); });

                // `TextNode` stays Element's alias for `instanceof`; only the string constructor
                // differs. jsoup's `new TextNode(text)` is a text node, which the polyfill has no
                // native for: it throws, rather than make an element named after the text.
                function TextNode(node, baseUrl) {
                    if (typeof node === 'string' || node instanceof String) {
                        throw new Error('org.jsoup.nodes.TextNode(String) is not supported');
                    }
                    Element.call(this, node, baseUrl);
                }
                TextNode.prototype = Element.prototype;
                var EP = Element.prototype;
                EP.html = function (h) {
                    if (arguments.length) { if (this._n) this._n.setHtml(String(h)); return this; }
                    return this._n ? this._n.html() : '';
                };
                EP.text = function (t) {
                    if (arguments.length) { if (this._n) this._n.setText(String(t)); return this; }
                    return this._n ? this._n.text() : '';
                };
                EP.ownText = function () { return this._n ? this._n.ownText() : ''; };
                EP.outerHtml = function () { return this._n ? this._n.outerHtml() : ''; };
                EP.toString = function () { return this.outerHtml(); };
                // A rule's JS result reaches the rule engine as JSON. Rhino hands Legado the
                // jsoup node itself, whose string form is its outer HTML; the rule engine's own
                // list extraction represents an element the same way (JsoupDefaultExtractor).
                EP.toJSON = function () { return this.outerHtml(); };
                EP.attr = function (k, v) {
                    if (arguments.length === 2) { if (this._n) this._n.setAttr(String(k), String(v)); return this; }
                    return this._n ? this._n.attr(String(k)) : '';
                };
                EP.attributes = function () { return new Attributes(this._n ? this._n.attributeList() : []); };
                EP.dataset = function () { return this.attributes().dataset(); };
                EP.select = function (q) { return wrap(this._n ? this._n.select(String(q)) : [], this._baseUrl); };
                // jsoup `Element.selectFirst`: the first match, or null. jsoup 1.16.2 (the
                // version every Legado fork pins) has no `Elements.selectFirst`, so neither do we.
                EP.selectFirst = function (q) { return this.select(q).first(); };
                EP.is = function (q) { return this._n ? this._n.matches(String(q)) : false; };
                EP.first = function () { return null; };
                EP.last = function () { return null; };
                EP.children = function () { return wrap(this._n ? this._n.children() : [], this._baseUrl); };
                EP.childrenSize = function () { return this.children().size(); };
                EP.child = function (i) { return this.children().get(i); };
                EP.firstElementChild = function () { return this.children().first(); };
                EP.lastElementChild = function () { return this.children().last(); };
                EP.parent = function () { return wrapOne(this._n ? this._n.parent() : null, this._baseUrl); };
                EP.nextElementSibling = function () { return wrapOne(this._n ? this._n.nextElementSibling() : null, this._baseUrl); };
                EP.previousElementSibling = function () { return wrapOne(this._n ? this._n.previousElementSibling() : null, this._baseUrl); };
                EP.firstElementSibling = function () { return wrapOne(this._n ? this._n.firstElementSibling() : null, this._baseUrl); };
                EP.lastElementSibling = function () { return wrapOne(this._n ? this._n.lastElementSibling() : null, this._baseUrl); };
                EP.siblingElements = function () { return wrap(this._n ? this._n.siblingElements() : [], this._baseUrl); };
                EP.elementSiblingIndex = function () { return this._n ? this._n.elementSiblingIndex() : 0; };
                // jsoup `parents()`: up to <html>, not the document. 掌阅书城 (YCK1329) drops
                // nested matches with `parents().contains(c)`.
                EP.parents = function () { return wrap(this._n ? this._n.parents() : [], this._baseUrl); };
                // jsoup `closest(query)`: this element or its nearest matching ancestor, else null.
                EP.closest = function (q) { return wrapOne(this._n ? this._n.closest(String(q)) : null, this._baseUrl); };
                // jsoup's `Node.equals` is identity: two reads of one node are equal. Rhino's `==`
                // on two of them is true as well (it compares the unwrapped nodes); ours compares
                // the wrappers, which no `==` can be taught otherwise.
                EP.equals = function (o) { return o === this || (o instanceof Element && !!this._n && !!o._n && this._n.isSameNode(o._n)); };
                // jsoup `clone()`: a deep copy the script may edit without touching this tree.
                EP.clone = function () { return new Element(this._n ? this._n.cloneElement() : null, this._baseUrl); };
                // jsoup moves a node `appendChild` is given; this inserts a copy of its markup.
                EP.appendChild = function (el) { if (this._n && el) this._n.appendHtml(String(el.outerHtml ? el.outerHtml() : el)); return this; };
                EP.prependChild = function (el) { if (this._n && el) this._n.prependHtml(String(el.outerHtml ? el.outerHtml() : el)); return this; };
                EP.append = function (h) { if (this._n) this._n.appendHtml(String(h)); return this; };
                EP.prepend = function (h) { if (this._n) this._n.prependHtml(String(h)); return this; };
                EP.before = function (h) { if (this._n) this._n.beforeHtml(String(h && h.outerHtml ? h.outerHtml() : h)); return this; };
                EP.after = function (h) { if (this._n) this._n.afterHtml(String(h && h.outerHtml ? h.outerHtml() : h)); return this; };
                EP.empty = function () { if (this._n) this._n.empty(); return this; };
                EP.remove = function () { if (this._n) this._n.remove(); };
                EP.removeAttr = function (k) { if (this._n) this._n.removeAttr(String(k)); return this; };
                EP.tagName = function () { return (this._n ? this._n.tagName() : '') || 'div'; };
                EP.nodeName = function () { return this.tagName(); };
                EP.normalName = function () { return this.tagName().toLowerCase(); };
                EP.id = function () { return this._n ? this._n.id() : ''; };
                EP.className = function () { return this._n ? this._n.className() : ''; };
                EP.classNames = function () { return this.className().split(/\\s+/).filter(function (c) { return c; }); };
                // jsoup compares each whitespace-separated class ignoring case
                // (oracle case file elements-hasclass.json).
                EP.hasClass = function (c) {
                    var wanted = String(c).toLowerCase();
                    return this.classNames().some(function (k) { return k.toLowerCase() === wanted; });
                };
                EP.hasText = function () { return this.text().trim().length > 0; };
                EP.getElements = function () { return this.select('*'); };
                EP.getAllElements = function () { return this.select('*'); };
                EP.getElementById = function (id) { return this.select('#' + id).first(); };
                EP.getElementsByClass = function (c) { return this.select('.' + c); };
                EP.getElementsByTag = function (t) { return this.select(String(t)); };
                EP.getElementsByAttribute = function (a) { return this.select('[' + a + ']'); };
                EP.getElementsByAttributeValue = function (a, v) { return this.select('[' + a + '="' + v + '"]'); };
                EP.getElementsByAttributeValueContaining = function (a, v) { return this.select('[' + a + '*="' + v + '"]'); };
                EP.absUrl = function (k) { return this._n ? this._n.absUrl(String(k)) : ''; };
                EP.baseUri = function () { return this._baseUrl; };
                EP.parentNode = function () { return this.parent(); };
                EP.wholeText = function () { return this._n ? this._n.wholeText() : ''; };
                // jsoup `Element.data()`: script/style contents, which `text()` leaves out.
                EP.data = function () { return this._n ? this._n.data() : ''; };
                EP.val = function (v) { if (arguments.length) return this.attr('value', v); return this.attr('value'); };
                EP.textNode = function () { return this.text(); };
                EP.hasAttr = function (k) { return this._n ? this._n.hasAttr(String(k)) : false; };

                // jsoup's Elements is a java.util.ArrayList, and Rhino lets Legado scripts use it
                // as one: `els[0]`, `els.toArray()`, `els.add(e)`, and `for (i in els)` over its
                // indices (🥝猕猴桃漫画's explore rule does all three). The elements are the
                // wrapper's own index properties; `_arr` and every method are non-enumerable, so
                // for-in sees the indices and nothing else.
                function Elements(arr) {
                    if (arr == null) arr = [];
                    else if (arr._arr) arr = arr._arr.slice();
                    else if (typeof arr === 'object' && typeof arr.length === 'number') arr = Array.prototype.slice.call(arr);
                    else arr = [];
                    Object.defineProperty(this, '_arr', { value: arr });
                    for (var i = 0; i < arr.length; i++) this[i] = arr[i];
                }
                var ESP = Elements.prototype;
                ESP._reindex = function () {
                    var n = this._arr.length;
                    for (var k in this) { if (/^\\d+$/.test(k) && Number(k) >= n) delete this[k]; }
                    for (var i = 0; i < n; i++) this[i] = this._arr[i];
                };
                ESP.size = function () { return this._arr.length; };
                ESP.size2 = function () { return this._arr.length; };
                ESP.isEmpty = function () { return this._arr.length === 0; };
                Object.defineProperty(ESP, 'length', { get: function () { return this._arr.length; }, configurable: true });
                ESP.get = function (i) { return this._arr[i] || null; };
                ESP.add = function (a, b) {
                    if (arguments.length === 2) this._arr.splice(Number(a), 0, b); else this._arr.push(a);
                    this._reindex();
                    return true;
                };
                ESP.addAll = function (list) {
                    var items = list && list._arr ? list._arr : Array.prototype.slice.call(list || []);
                    for (var i = 0; i < items.length; i++) this._arr.push(items[i]);
                    this._reindex();
                    return items.length > 0;
                };
                ESP.set = function (i, e) { var old = this._arr[i]; this._arr[i] = e; this[i] = e; return old; };
                // java.util.List compares with `equals`, which for a jsoup node is the node itself.
                ESP.indexOf = function (e) {
                    for (var i = 0; i < this._arr.length; i++) {
                        var x = this._arr[i];
                        if (x === e || (x instanceof Element && x.equals(e))) return i;
                    }
                    return -1;
                };
                ESP.contains = function (e) { return this.indexOf(e) >= 0; };
                ESP.toArray = function () { return this._arr.slice(); };
                // java.util.List `sort(Comparator)`: in place, returning nothing; a comparator
                // answer that is not a number counts as equal, as Rhino's int conversion reads
                // NaN. 完本小说 and 小红书库 (YCK1330) order their chapter rows this way.
                ESP.sort = function (comparator) {
                    this._arr.sort(function (a, b) { var r = Number(comparator(a, b)); return r === r ? r : 0; });
                    this._reindex();
                };
                // jsoup `Elements.clone()`: a deep copy of each element.
                ESP.clone = function () { return new Elements(this._arr.map(function (e) { return e.clone(); })); };
                ESP.first = function () { return this._arr[0] || null; };
                ESP.last = function () { return this._arr[this._arr.length - 1] || null; };
                // jsoup joins the matched elements' text with a space, and their HTML with newlines.
                ESP.text = function () { return this._arr.map(function (e) { return e.text(); }).filter(function (t) { return t.length; }).join(' '); };
                ESP.eachText = function () { return this._arr.map(function (e) { return e.text(); }).filter(function (t) { return t.length; }); };
                ESP.eachAttr = function (k) { return this._arr.filter(function (e) { return e.hasAttr(k); }).map(function (e) { return e.attr(k); }); };
                ESP.html = function () { return this._arr.map(function (e) { return e.html(); }).join('\\n'); };
                ESP.hasText = function () { return this._arr.some(function (e) { return e.hasText(); }); };
                ESP.each = function (fn) { this._arr.forEach(fn); return this; };
                ESP.forEach = function (fn) { this._arr.forEach(fn); return this; };
                // jsoup `Elements.attr(k)`: the first element that has the attribute;
                // `attr(k, v)` sets it on every element.
                ESP.attr = function (k, v) {
                    if (arguments.length === 2) { this._arr.forEach(function (e) { e.attr(k, v); }); return this; }
                    for (var i = 0; i < this._arr.length; i++) if (this._arr[i].hasAttr(k)) return this._arr[i].attr(k);
                    return '';
                };
                ESP.hasAttr = function (k) { return this._arr.some(function (e) { return e.hasAttr(k); }); };
                // jsoup `Elements.hasClass`: whether any element has the class.
                ESP.hasClass = function (c) { return this._arr.some(function (e) { return e.hasClass(c); }); };
                ESP.removeAttr = function (k) { this._arr.forEach(function (e) { e.removeAttr(k); }); return this; };
                ESP.select = function (q) {
                    var out = [];
                    this._arr.forEach(function (e) { e.select(q).each(function (m) { out.push(m); }); });
                    return new Elements(out);
                };
                ESP.outerHtml = function () { return this._arr.map(function (e) { return e.outerHtml(); }).join('\\n'); };
                ESP.toString = function () { return this.outerHtml(); };
                // Legado's list rules take a returned jsoup Elements as the list itself
                // (AnalyzeRule.getElements). As JSON it is the array of its elements, so a
                // chapterList ending in `doc.select(…)` yields one row per element.
                ESP.toJSON = function () { return this._arr; };
                ESP.not = function (q) { return new Elements(this._arr.filter(function (e) { return !e.is(q); })); };
                ESP.is = function (q) { return this._arr.some(function (e) { return e.is(q); }); };
                ESP.filter = function (fn) { return new Elements(this._arr.filter(fn)); };
                ESP.eq = function (i) { return new Elements(this._arr[i] ? [this._arr[i]] : []); };
                ESP.next = function () { return new Elements(this._arr.map(function (e) { return e.nextElementSibling(); }).filter(function (e) { return e; })); };
                ESP.prev = function () { return new Elements(this._arr.map(function (e) { return e.previousElementSibling(); }).filter(function (e) { return e; })); };
                ESP.parents = function () {
                    var out = [];
                    this._arr.forEach(function (e) { var p = e.parent(); while (p) { out.push(p); p = p.parent(); } });
                    return new Elements(out);
                };
                // `remove()` takes the elements out of their documents (jsoup); `remove(i)` /
                // `remove(element)` is ArrayList's, taking one out of this list.
                ESP.remove = function (x) {
                    if (arguments.length === 0) { this._arr.forEach(function (e) { e.remove(); }); return this; }
                    var i = typeof x === 'number' ? x : this._arr.indexOf(x);
                    if (i < 0 || i >= this._arr.length) return typeof x === 'number' ? null : false;
                    var removed = this._arr.splice(i, 1)[0];
                    this._reindex();
                    return typeof x === 'number' ? removed : true;
                };
                ESP.empty = function () { this._arr.forEach(function (e) { e.empty(); }); return this; };
                ESP.append = function (h) { this._arr.forEach(function (e) { e.append(h); }); return this; };
                ESP.prepend = function (h) { this._arr.forEach(function (e) { e.prepend(h); }); return this; };
                ESP.before = function (h) { this._arr.forEach(function (e) { e.before(h); }); return this; };
                ESP.after = function (h) { this._arr.forEach(function (e) { e.after(h); }); return this; };
                ESP.iterator = function () { return this._arr[Symbol.iterator](); };
                ESP[Symbol.iterator] = function () { return this._arr[Symbol.iterator](); };
                Object.keys(ESP).forEach(function (k) { Object.defineProperty(ESP, k, { enumerable: false }); });

                // A value from the rule engine: a native node becomes an Element, a list of them
                // an Elements — what Rhino hands Legado's scripts. Anything else passes through.
                this.__yueduJsoupWrap = function (v, baseUrl) {
                    // A jsoup step's selection (`JsoupSelection`) is `Elements`, empty or not.
                    if (v != null && typeof v === 'object' && Array.isArray(v.__yueduJsoupSelection)) {
                        return wrap(v.__yueduJsoupSelection, baseUrl);
                    }
                    if (isNode(v)) return new Element(v, baseUrl);
                    if (Array.isArray(v) && v.length > 0 && v.every(isNode)) return wrap(v, baseUrl);
                    return v;
                };
                // The reverse, for a script's result: the native node of an Element, the native
                // nodes of an Elements or of an array of Elements; undefined for anything else.
                this.__yueduJsoupUnwrap = function (v) {
                    if (v instanceof Element) return v._n || undefined;
                    var items = v instanceof Elements ? v._arr : (Array.isArray(v) ? v : null);
                    if (!items || items.length === 0) return undefined;
                    for (var i = 0; i < items.length; i++) if (!(items[i] instanceof Element) || !items[i]._n) return undefined;
                    return items.map(function (e) { return e._n; });
                };

                function Document(node, baseUrl) { Element.call(this, node, baseUrl); }
                Document.prototype = Object.create(Element.prototype);
                Document.prototype.constructor = Document;
                Document.prototype.body = function () { var b = this._n ? this._n.body() : null; return new Element(b, this._baseUrl); };
                Document.prototype.head = function () { return this.select('head').first() || new Element(null, this._baseUrl); };
                Document.prototype.title = function () { return this._n ? this._n.title() : ''; };
                Document.prototype.setBaseUri = function () { return this; };
                Document.prototype.outputSettings = function () { return this; };

                function JsoupParse(html, baseUrl) {
                    return new Document(__yueduJsoup.parse(html == null ? '' : String(html), baseUrl), baseUrl);
                }

                var Method = { GET: 'GET', POST: 'POST', HEAD: 'HEAD', PUT: 'PUT', DELETE: 'DELETE', OPTIONS: 'OPTIONS', PATCH: 'PATCH', TRACE: 'TRACE' };

                this.org = {
                    jsoup: {
                        Jsoup: { connect: function (url) { return new Connection(url); }, parse: function (h, b) { return JsoupParse(h, b); }, parseBodyFragment: function (h, b) { return JsoupParse(h, b); }, clean: function (h) { return h; } },
                        Connection: { Method: Method, Response: Response, KeyVal: { create: function (k, v) { return { key: function () { return k; }, value: function () { return v; } }; } } },
                        nodes: { Document: Document, Element: Element, TextNode: TextNode },
                        safety: { Clean: { clean: function (h) { return h; } } },
                        select: { Elements: Elements, Selector: { select: function (q, root) { return root ? root.select(q) : new Elements([]); } } },
                        parser: { Parser: {
                            parse: function (h, b) { return JsoupParse(h, b); },
                            unescapeEntities: function (s) { return __yueduJsoup.unescape(s == null ? '' : String(s)); }
                        } },
                        helper: { HttpConnection: { connect: function (url) { return new Connection(url); } } }
                    }
                };
            })();
        """)

        installExploreInfoMap(into: ctx)
    }

    // MARK: - Explore infoMap

    /// Legado's explore `infoMap`: one map per source that the explore page's buttons,
    /// inputs and toggles write and the source's JS reads — in its explore rule, its
    /// category URLs and its explore actions. Legado keeps it in `CacheManager` under
    /// `infoMap_<source URL>`; here it lives in the source's `cache` store under the same
    /// key, and the JS global `infoMap` is loaded from it whenever a context is set up or
    /// the source changes. `infoMap.save()` writes it back.
    private var exploreInfoMapKey: String? {
        bookSource.map { "infoMap_" + $0.bookSourceUrl }
    }

    private func installExploreInfoMap(into ctx: JSContext) {
        let stored = exploreInfoMapKey.flatMap { cacheBridge.get($0) } ?? "{}"
        // The key and store as they are now: installed again whenever the source changes, and
        // read from this context's thread, which a timeout may have abandoned.
        let key = exploreInfoMapKey
        let cache = cacheBridge
        let persist: @convention(block) (String) -> Void = { json in
            guard let key else { return }
            cache.put(key, json)
        }
        ctx.setObject(persist, forKeyedSubscript: "__yueduPersistInfoMap" as NSString)
        ctx.setObject(stored, forKeyedSubscript: "__yueduStoredInfoMap" as NSString)
        ctx.evaluateScript("""
            (function () {
                var stored = {};
                try {
                    stored = JSON.parse(__yueduStoredInfoMap) || {};
                } catch (e) {
                    if (typeof java !== 'undefined' && java.log) java.log('infoMap: stored map is not JSON: ' + e);
                }
                var map = __yueduJavaMap(stored);
                Object.defineProperty(map, 'save', {
                    value: function () { __yueduPersistInfoMap(JSON.stringify(map)); return map; },
                    enumerable: false,
                    configurable: true
                });
                infoMap = map;
            })();
        """)
    }

    /// The source's explore `infoMap` as its JS holds it now, values as strings.
    func exploreInfoMapValues() -> [String: String] {
        onJSQueue {
            let json = context.evaluateScript(
                "JSON.stringify(typeof infoMap === 'undefined' ? {} : infoMap)"
            )?.toString() ?? "{}"
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    return [:]
                }
                return object.mapValues { value in
                    (value as? String) ?? (value is NSNull ? "" : "\(value)")
                }
            } catch {
                AppLogger.parse("Explore infoMap is not JSON", context: ["error": "\(error)"])
                return [:]
            }
        }
    }

    /// Sets one `infoMap` entry, as an explore input or toggle does, and saves the map.
    func setExploreInfoMapValue(_ value: String, forKey key: String) {
        onJSQueue {
            context.setObject(key, forKeyedSubscript: "__yueduInfoMapKey" as NSString)
            context.setObject(value, forKeyedSubscript: "__yueduInfoMapValue" as NSString)
            context.evaluateScript("infoMap.put(__yueduInfoMapKey, __yueduInfoMapValue); infoMap.save();")
        }
    }

    /// Some Legado/Rhino source scripts read current-chapter fields as bare globals
    /// (`title`, `url`, `index`) instead of going through `chapter.title`.
    /// JavaScriptCore does not synthesize those globals from the exported `chapter` object,
    /// so keep them explicitly mirrored whenever the chapter bridge changes.
    /// Restores Legado's arity overload of `java.get` (see the call site for why).
    /// Idempotent: re-running it re-binds the already-installed dispatcher, and it
    /// no-ops if the native `httpGet` is missing rather than clobbering `java.get`.
    private static func installJavaGetOverload(in ctx: JSContext) {
        ctx.evaluateScript("""
        (function () {
            if (typeof java === 'undefined' || typeof java.httpGet !== 'function') { return; }
            if (java.__yueduGetOverloaded) { return; }
            var storeGet = (typeof java.get === 'function')
                ? java.get.bind(java)
                : function () { return ''; };
            var httpGet = java.httpGet.bind(java);
            java.get = function (a, b) {
                return arguments.length >= 2 ? httpGet(String(a), b) : storeGet(String(a));
            };
            java.__yueduGetOverloaded = true;
        })();
        """)
    }

    private static func installJavaConnectOverload(in ctx: JSContext) {
        ctx.evaluateScript("""
        (function () {
            if (typeof java === 'undefined' || typeof java.connectWithOptions !== 'function') { return; }
            if (java.__yueduConnectOverloaded) { return; }
            var simpleConnect = java.connect.bind(java);
            var optionConnect = java.connectWithOptions.bind(java);
            java.connect = function (url, headers, timeout) {
                return arguments.length === 1
                    ? simpleConnect(String(url))
                    : optionConnect(String(url), headers == null ? null : headers, timeout == null ? null : timeout);
            };
            java.__yueduConnectOverloaded = true;
        })();
        """)
    }

    /// `java.getElements` / `java.getElement` hand back jsoup `Element`s, as Legado does: the
    /// native side returns detached nodes and the polyfill's `__yueduJsoupWrap` (looked up at
    /// call time) wraps them. Without this, `java.getElements('tag.li')[i].select(…)` threw.
    private static func installJavaElementAccessors(in ctx: JSContext) {
        ctx.evaluateScript("""
        (function (g) {
            if (typeof java === 'undefined' || java.__yueduElementAccessors) { return; }
            function wrap(v) { return typeof g.__yueduJsoupWrap === 'function' ? g.__yueduJsoupWrap(v) : v; }
            var nativeElements = java.getElements.bind(java);
            java.getElements = function (rule) { return wrap(nativeElements(String(rule))); };
            var nativeElement = java.getElementValue.bind(java);
            java.getElement = function (rule) {
                var v = nativeElement(String(rule));
                return v === undefined ? null : wrap(v);
            };
            java.__yueduElementAccessors = true;
        })(this);
        """)
    }

    private static func installJavaHeadAndPostOverloads(in ctx: JSContext) {
        ctx.evaluateScript("""
        (function () {
            if (typeof java === 'undefined' || java.__yueduHeadPostOverloaded) { return; }
            if (typeof java.headWithOptions === 'function') {
                var simpleHead = java.head.bind(java);
                var optionHead = java.headWithOptions.bind(java);
                java.head = function (url, headers, timeout) {
                    return arguments.length < 3
                        ? simpleHead(String(url), headers)
                        : optionHead(String(url), headers, timeout);
                };
            }
            if (typeof java.postWithOptions === 'function') {
                var simplePost = java.post.bind(java);
                var optionPost = java.postWithOptions.bind(java);
                java.post = function (url, body, headers, timeout) {
                    return arguments.length < 4
                        ? simplePost(String(url), String(body), headers)
                        : optionPost(String(url), String(body), headers, timeout);
                };
            }
            java.__yueduHeadPostOverloaded = true;
        })();
        """)
    }

    private func injectChapterGlobals(_ bridge: LegadoChapterBridge, into ctx: JSContext) {
        ctx.setObject(bridge.title, forKeyedSubscript: "title" as NSString)
        ctx.setObject(bridge.title, forKeyedSubscript: "chapterTitle" as NSString)
        ctx.setObject(bridge.url, forKeyedSubscript: "url" as NSString)
        ctx.setObject(bridge.url, forKeyedSubscript: "chapterUrl" as NSString)
        ctx.setObject(bridge.index, forKeyedSubscript: "index" as NSString)
        ctx.setObject(bridge.index, forKeyedSubscript: "chapterIndex" as NSString)
        ctx.setObject(bridge.order, forKeyedSubscript: "order" as NSString)
        ctx.setObject(bridge.order, forKeyedSubscript: "chapterOrder" as NSString)
        ctx.setObject(bridge.isVip(), forKeyedSubscript: "isVip" as NSString)
    }

    /// Inject `source` as a Legado-compatible bridge object with methods and properties.
    private func injectSourceObject(_ sourceBridge: LegadoSourceBridge, into ctx: JSContext) {
        ctx.setObject(sourceBridge, forKeyedSubscript: "source" as NSString)
    }

    private func setResult(_ result: Any?) {
        guard let result else {
            context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)
            return
        }
        if let map = result as? JavaMap {
            context.setObject(javaMapValue(map), forKeyedSubscript: "result" as NSString)
            return
        }
        if let string = result as? ScriptString {
            context.setObject(string.value, forKeyedSubscript: "result" as NSString)
            return
        }
        // A jsoup step's elements reach the script as jsoup `Element`/`Elements`, as Legado
        // hands them over: `result.attr('href')`, `result[i].select('a')`.
        if let elements = jsElements(result) {
            context.setObject(elements, forKeyedSubscript: "result" as NSString)
            return
        }
        if let string = result as? String,
           Self.jsonObjectIfPossible(from: string) != nil,
           let wrapper = context.objectForKeyedSubscript("__yueduWrapJSONResult"),
           let wrapped = wrapper.call(withArguments: [string]),
           !wrapped.isUndefined {
            context.setObject(wrapped, forKeyedSubscript: "result" as NSString)
            return
        }
        // Values extracted by Swift rule evaluators arrive here as Foundation
        // arrays/dictionaries. JavaScriptCore exposes those as Obj-C collection
        // proxies rather than native JS values, so they do not inherit the
        // java.util.List compatibility methods installed on Array.prototype.
        // Legado/Rhino exposes the same intermediate list as a mutable Java List;
        // rules such as 番茄酱's `result.add("有声书")` must therefore be able to
        // mutate it. Re-enter through JSON only for JSON-safe value collections;
        // bridge objects such as LegadoStrResponse keep their native identity.
        // The JSON text keeps each object's keys in document order, so the script's
        // object does too. An object reads as Rhino's `LinkedHashMap`: 猫耳有声 takes an
        // item's id with `String(result).match(/id=(\d+)/)`.
        if result is NSDictionary || result is NSArray,
           let raw = OrderedJSON.jsonText(result),
           let wrapper = context.objectForKeyedSubscript("__yueduWrapJSONResult") {
            let arguments: [Any] = result is NSDictionary
                ? [raw, OrderedJSON.javaText(result), true]
                : [raw]
            if let wrapped = wrapper.call(withArguments: arguments), !wrapped.isUndefined {
                context.setObject(wrapped, forKeyedSubscript: "result" as NSString)
                return
            }
        }
        context.setObject(result, forKeyedSubscript: "result" as NSString)
    }

    /// `map` as a script receives it: its entries in an object `__yueduJavaMap` gave the
    /// `java.util.Map` methods. JS queue only.
    private func javaMapValue(_ map: JavaMap) -> Any {
        guard let object = JSValue(object: map.entries, in: context),
              let wrapper = context.objectForKeyedSubscript("__yueduJavaMap"),
              wrapper.isObject,
              let wrapped = wrapper.call(withArguments: [object]) else {
            // `configureContext` installs the shim in every context; not finding it is an
            // engine bug, and the entries still read as `result[key]`.
            AppLogger.parse("Java Map shim missing; binding a plain object", level: .anomaly)
            return map.entries
        }
        return wrapped
    }

    /// Forgets the page copies this context's scripts were handed elements of
    /// (`LegadoScriptTrees`), once the parse that handed them out is over. Any thread.
    func releaseScriptTrees() {
        bridge.scriptTrees.removeAll()
    }

    /// `value` as polyfill jsoup objects when it is an engine element or a list of them.
    /// JS queue only.
    private func jsElements(_ value: Any) -> JSValue? {
        let bridged = LegadoJsoupElement.bridged(value, trees: bridge.scriptTrees)
        let holdsElements = bridged is LegadoJsoupElement
            || ((bridged as? [Any]).map { !$0.isEmpty && $0.allSatisfy { $0 is LegadoJsoupElement } } ?? false)
        guard holdsElements,
              let wrapper = context.objectForKeyedSubscript("__yueduJsoupWrap"),
              !wrapper.isUndefined
        else { return nil }
        return wrapper.call(withArguments: [bridged])
    }

    /// A binding's value as the script receives it (`src` can be a selected element).
    private func jsBinding(_ value: Any) -> Any {
        jsElements(value) ?? value
    }

    /// Sets each binding as a global for one evaluation, as every evaluation always has. A
    /// `java` binding that is an AnalyzeUrl's view does not replace the bridge: `java` becomes
    /// the bridge with that AnalyzeUrl's members on top (`__yueduAnalyzeUrlJava`), which is what
    /// Legado's `AnalyzeUrl.evalJS` binds (`LegadoAnalyzeUrlScriptView`).
    ///
    /// The returned closure puts the previous `java` and `result` back. Those two are what an
    /// evaluation nested in a running script would otherwise take from it: `java.initUrl()` in
    /// `loginCheckJs` runs the URL's scripts — its `js` option gets the URL as `result` — while
    /// the check still reads its own `result` and `java`. Legado scopes every binding to its
    /// evaluation; the other bindings stay set here, as they always have. JS queue only.
    private func bindGlobals(_ bindings: [String: Any], converting: Bool) -> () -> Void {
        let ctx = context
        var restores: [() -> Void] = []
        func scoped(_ key: String, _ value: Any) {
            let previous = ctx.objectForKeyedSubscript(key)
            ctx.setObject(value, forKeyedSubscript: key as NSString)
            restores.append { ctx.setObject(previous, forKeyedSubscript: key as NSString) }
        }
        for (key, value) in bindings {
            if key == "java", let view = value as? LegadoAnalyzeUrlScriptView {
                guard let bridgeValue = JSValue(object: bridge, in: ctx),
                      let layered = ctx.objectForKeyedSubscript("__yueduAnalyzeUrlJava")?
                          .call(withArguments: [bridgeValue, view]),
                      layered.isObject else {
                    AppLogger.parse("AnalyzeUrl java could not be layered over the bridge", level: .warning)
                    continue
                }
                scoped(key, layered)
                continue
            }
            let bound: Any
            if let map = value as? JavaMap {
                bound = javaMapValue(map)
            } else {
                bound = converting ? jsBinding(value) : value
            }
            if key == "result" {
                scoped(key, bound)
            } else {
                ctx.setObject(bound, forKeyedSubscript: key as NSString)
            }
        }
        return { restores.reversed().forEach { $0() } }
    }

    private static func jsonObjectIfPossible(from string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// Parse a Legado header rule (a JSON object, or an `@js:` / `<js>` rule that returns one)
    /// into a dictionary, as `BaseSource.getHeaderMap()` does: the JSON goes through
    /// `BookSource.legadoHeaderMap(fromJSON:)`, and a rule that yields none contributes
    /// nothing.
    ///
    /// A header rule may be JS that *builds* the map (书山聚合 emits `java.getWebViewUA()` plus
    /// a constant API token that its server requires on every endpoint). Evaluating it here
    /// is what makes those headers reach the request at all.
    func parseHeaders(_ headerStr: String) -> [String: String] {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let script = Self.headerJSScript(trimmed) else {
            guard let map = BookSource.legadoHeaderMap(fromJSON: trimmed) else {
                AppLogger.parse("header rule is not JSON; requests carry only the default User-Agent", context: [
                    "rule": String(trimmed.prefix(120))
                ])
                return [:]
            }
            return map
        }
        let evaluated = (evaluateHeaderScript(script) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let map = BookSource.legadoHeaderMap(fromJSON: evaluated) else {
            AppLogger.parse("header JS produced no header map", context: [
                "rule": String(trimmed.prefix(120)),
                "result": String(evaluated.prefix(120)),
                "jsError": lastError ?? "-"
            ])
            return [:]
        }
        return map
    }

    /// Every fork evaluates a header rule through `BaseSource.evalJS`, which binds `baseUrl`
    /// to the source URL (`getKey()`); a header script reading it here hit a ReferenceError.
    /// A header rule can be resolved while another rule is running — the first `java.ajax`
    /// of a TOC script — so the global is put back afterwards and that rule keeps its own
    /// `baseUrl`.
    ///
    /// In a scope of its own, as `BaseSource.evalJS` runs it in a fresh runtime scope: the
    /// rule runs again for every request, and a top-level `let` in the global context threw
    /// `SyntaxError: Can't create duplicate variable` the second time — 点众阅读 (YCK 1330)
    /// declares `let randomUuid`, and its book pages went out without their signed header.
    private func evaluateHeaderScript(_ script: String) -> String? {
        onJSQueue { [self] () -> String? in
            let global: JSValue = context.globalObject
            let hadBaseURL = global.hasProperty("baseUrl")
            let previous = global.forProperty("baseUrl")
            global.setValue(bookSource?.bookSourceUrl ?? "", forProperty: "baseUrl")
            defer {
                if hadBaseURL {
                    global.setValue(previous, forProperty: "baseUrl")
                } else {
                    global.deleteProperty("baseUrl")
                }
            }
            return evaluateIsolated(script, bindings: [:])
        }
    }

    /// The JS body of a `@js:` / `<js>…</js>` header rule, or nil for a plain header.
    static func headerJSScript(_ headerStr: String) -> String? {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.lowercased().hasPrefix("<js>"),
           let close = trimmed.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<close.lowerBound])
        }
        return nil
    }

    /// Extract a usable String from a JSValue, returning nil for undefined/null/error.
    private func extractString(from value: JSValue) -> String? {
        if lastError != nil { return nil }
        if value.isUndefined || value.isNull { return nil }

        // Arrays and objects → JSON string.
        // Uses JavaScriptCore's own JSON.stringify instead of NSJSONSerialization,
        // because NSJSONSerialization raises an *uncatchable* ObjC exception
        // (NSInvalidArgumentException) for values that JS bridges as non-JSON-safe
        // objects (Map, Set, Proxy, functions with custom toJSON, etc.).
        // JSON.stringify returns `undefined` for unserialisable values, which we
        // fall through from gracefully.
        if value.isArray || value.isObject {
            guard let ctx = value.context else { return value.toString() }
            ctx.setObject(value, forKeyedSubscript: "__yuedu_jsonify" as NSString)
            let jsonVal = ctx.evaluateScript("JSON.stringify(__yuedu_jsonify)")
            ctx.evaluateScript("delete __yuedu_jsonify")
            if let jsonVal,
               !jsonVal.isUndefined, !jsonVal.isNull,
               let json = jsonVal.toString(), !json.isEmpty {
                // An object whose JSON form is a string stands in for a Java object that
                // Rhino would hand Legado as its `toString()`: a jsoup Element (its outer
                // HTML) or a `java.lang.String` (a boxed JS string). Return that string, not
                // a quoted JSON literal. JSON.stringify's own output always parses.
                if json.hasPrefix("\""),
                   let data = json.data(using: .utf8),
                   let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                    return string
                }
                return json
            }
        }

        return value.toString()
    }
}
