import QuartzCore
import UIKit

// MARK: - Frame gaps while the strip moves
//
// 回饋 #133：條漫捲動時大約每秒一次 67–150 ms 沒有新幀。`MainThreadMonitor` 只認 250 ms 以上
// 不回應的主執行緒，這種長度的停頓它看不到；時間落在 Core Animation 提交或 SwiftUI 更新裡的，
// 包在任何 span 裡也量不到。所以這裡直接看螢幕：捲動中每一幀記下時間，兩幀之間隔了兩幀以上就
// 記一行 ⏱ `webtoon.frameGap`，附上這段期間主執行緒上跑過的條漫各階段（`span`／`note`）。
// 空的那段期間就是落在沒有 span 的工作上——那一行本身就是下一個要補的 span。

@MainActor
final class FixedPageFrameGapProbe {

    /// One stage's work since the last frame.
    private struct Stage {
        var count = 0
        var ms: Double = 0
        var detail = ""
    }

    /// Stages run on the main thread since the previous frame, while a probe watches.
    private static var stages: [String: Stage] = [:]
    /// Order the stages first ran in since the previous frame.
    private static var stageOrder: [String] = []
    private static var watchers = 0

    /// A gap counts from this long: two frames at 60 Hz, four at 120 Hz.
    nonisolated static let gapThresholdMs: Double = 34

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    /// What the gap line names the strip by.
    private let stage: String

    init(stage: String) {
        self.stage = stage
    }

    isolated deinit {
        stop()
    }

    var isWatching: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
        Self.watchers += 1
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        lastTimestamp = nil
        Self.watchers -= 1
        if Self.watchers == 0 { Self.clear() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer {
            lastTimestamp = link.timestamp
            Self.clear()
        }
        guard let last = lastTimestamp else { return }
        let gapMs = (link.timestamp - last) * 1000
        let frameMs = (link.targetTimestamp - link.timestamp) * 1000
        guard gapMs >= Self.gapThresholdMs, gapMs > frameMs * 2 else { return }
        SourcePerfTrace.record(
            stage,
            "frame=\(String(format: "%.0f", frameMs))ms since=\(Self.summary())",
            since: SourcePerfTrace.now - gapMs / 1000,
            thresholdMs: 0,
            mainThreadStallBreadcrumb: false
        )
    }

    /// "pageMove×1 2ms, imageShown×2 1ms (1179x5000)", or "none" when no stage ran.
    private static func summary() -> String {
        guard !stageOrder.isEmpty else { return "none" }
        return stageOrder.compactMap { name in
            guard let stage = stages[name] else { return nil }
            let detail = stage.detail.isEmpty ? "" : " (\(stage.detail))"
            return "\(name)×\(stage.count) \(String(format: "%.1f", stage.ms))ms\(detail)"
        }.joined(separator: ", ")
    }

    private static func clear() {
        stages.removeAll(keepingCapacity: true)
        stageOrder.removeAll(keepingCapacity: true)
    }

    /// Records that `stage` ran on the main thread for `ms`, for the next gap line.
    static func note(_ stage: String, ms: Double, detail: String = "") {
        guard watchers > 0 else { return }
        if stages[stage] == nil { stageOrder.append(stage) }
        stages[stage, default: Stage()].count += 1
        stages[stage]?.ms += ms
        if !detail.isEmpty { stages[stage]?.detail = detail }
    }

    /// A main-thread stage of the strip: logged on its own past `thresholdMs`, and named in
    /// the next gap line whatever its length.
    @discardableResult
    static func span<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 8,
        _ body: () throws -> T
    ) rethrows -> T {
        let t0 = SourcePerfTrace.now
        defer { note(stage, ms: (SourcePerfTrace.now - t0) * 1000, detail: watchers > 0 ? detail() : "") }
        return try SourcePerfTrace.span(stage, detail(), thresholdMs: thresholdMs, body)
    }
}
