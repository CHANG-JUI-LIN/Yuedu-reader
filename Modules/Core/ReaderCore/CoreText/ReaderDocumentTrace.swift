import Foundation

/// Chapter identity for the `⏱ coreText.document.*` breakdown lines.
///
/// Stage 0 of `Technotes/ViewportScrollArchitecture.md` measured chapter load and found the
/// document build (HTML/CSS → `NSAttributedString`) dominating slicing by 5–50×. Splitting that
/// cost means logging inside `HTMLBuilderPipelines` / `HTMLAttributedStringBuilder`, which are
/// deliberately chapter-agnostic — they never learn which spine they are building.
///
/// The spine index rides down as a task-local rather than a parameter because it is pure
/// diagnostic context crossing six call layers; widening their signatures for it would be noise
/// in code that has no other reason to know. `Task {}` inherits task-locals, so the build task
/// in `ChapterDocumentStore` carries it. `Task.detached` does not — a phase that moves onto a
/// detached task will log `spine=?` rather than a wrong number.
enum ReaderDocumentTrace {

    @TaskLocal static var spineIndex: Int?

    /// `"spine=12 "`, or `"spine=? "` outside a bound scope. Trailing space so call sites can
    /// prefix it unconditionally.
    static var spineTag: String {
        guard let spineIndex else { return "spine=? " }
        return "spine=\(spineIndex) "
    }

    /// Collector for the async leaves of `NodeAttributedStringRenderer.render`, bound by
    /// `render(_:)` itself. Stage 0.5 measured `render` at 85–91% of a heavy chapter's build;
    /// this splits that number by what the leaf actually waited on.
    @TaskLocal static var renderLeaves: RenderLeafMetrics?

    /// Times an awaited leaf into `bucket`. A no-op pass-through when no collector is bound,
    /// so render paths outside a measured chapter build stay uninstrumented rather than crash.
    static func measuring<T>(_ bucket: String, _ body: () async throws -> T) async rethrows -> T {
        guard let renderLeaves else { return try await body() }
        return try await renderLeaves.measuring(bucket, body)
    }

    /// Synchronous variant, for CPU leaves such as transparent-pixel trimming.
    static func measuringSync<T>(_ bucket: String, _ body: () throws -> T) rethrows -> T {
        guard let renderLeaves else { return try body() }
        return try renderLeaves.measuringSync(bucket, body)
    }

    /// Records a distinct input for `bucket`, so `/102u9` can say "102 calls, 9 distinct".
    static func note(_ bucket: String, key: String) {
        renderLeaves?.note(bucket, key: key)
    }
}

/// Async-leaf costs of one `NodeAttributedStringRenderer.render` call.
///
/// A task-local reference rather than a parameter or stored property: the renderer is a
/// deliberately stateless `struct` and the render is a deep async recursion, so threading an
/// accumulator would touch thirty call sites and contradict the type's design. Bound once per
/// `render(_:)`, so one instance is one chapter.
///
/// `nonisolated(unsafe)` state behind a lock: `render` is a `nonisolated async` method, so it
/// runs on the global executor rather than the caller's actor, and its leaves resume on
/// whatever thread the awaited service hands back.
final class RenderLeafMetrics: @unchecked Sendable {

    private let lock = NSLock()
    private var seconds: [String: Double] = [:]
    private var calls: [String: Int] = [:]
    private var distinctKeys: [String: Set<Int>] = [:]

    /// Records that `bucket` was entered for `key`, so the log can report how many of N calls
    /// were for distinct inputs. Stores hashes, not the keys — an image `src` can be a
    /// multi-megabyte base64 data URI.
    func note(_ bucket: String, key: String) {
        let hash = key.hashValue
        lock.withLock {
            distinctKeys[bucket, default: []].insert(hash)
            return
        }
    }

    /// Times `body` into the named bucket. Buckets are the awaited services — SVG
    /// rasterization, image loading, and so on — not the tree walk between them.
    ///
    /// `withLock` rather than `lock()`/`unlock()`: the bare pair is unavailable in an async
    /// context, since holding a lock across a suspension can deadlock the cooperative pool.
    /// Nothing is awaited inside the critical section here.
    /// `defer` rather than a straight-line record so a leaf that throws — an unreadable archive
    /// entry, say — still contributes its time instead of vanishing from the breakdown.
    func measuring<T>(_ bucket: String, _ body: () async throws -> T) async rethrows -> T {
        let start = SourcePerfTrace.now
        defer { record(bucket, since: start) }
        return try await body()
    }

    /// Synchronous variant for CPU leaves such as transparent-pixel trimming.
    func measuringSync<T>(_ bucket: String, _ body: () throws -> T) rethrows -> T {
        let start = SourcePerfTrace.now
        defer { record(bucket, since: start) }
        return try body()
    }

    private func record(_ bucket: String, since start: TimeInterval) {
        let elapsed = SourcePerfTrace.now - start
        lock.withLock {
            seconds[bucket, default: 0] += elapsed
            calls[bucket, default: 0] += 1
        }
    }

    /// `"imageLoad=3548.3ms/102u9 imageLoad.zip=3100.0ms/102"`, heaviest bucket first.
    /// `/102u9` reads "102 calls, 9 distinct inputs".
    var logDetail: String {
        lock.withLock {
            guard !seconds.isEmpty else { return "leaves=none" }
            return seconds
                .sorted { $0.value > $1.value }
                .map { bucket, value in
                    let distinct = distinctKeys[bucket].map { "u\($0.count)" } ?? ""
                    return "\(bucket)=\(String(format: "%.1f", value * 1000))ms"
                        + "/\(calls[bucket] ?? 0)\(distinct)"
                }
                .joined(separator: " ")
        }
    }

    /// Excludes dotted buckets: `imageLoad.zip` is a breakdown *inside* `imageLoad`, so counting
    /// both would double-count and drive `walk` negative.
    var totalSeconds: Double {
        lock.withLock {
            seconds
                .filter { !$0.key.contains(".") }
                .values
                .reduce(0, +)
        }
    }

    /// How many times `bucket` was entered. The hit rate of the image cache is
    /// `calls("imageLoad") - calls("imageLoad.zip")`, which is what its test asserts on.
    func callCount(_ bucket: String) -> Int {
        lock.withLock { calls[bucket] ?? 0 }
    }

    /// Distinct inputs seen for `bucket`.
    func distinctCount(_ bucket: String) -> Int {
        lock.withLock { distinctKeys[bucket]?.count ?? 0 }
    }
}
