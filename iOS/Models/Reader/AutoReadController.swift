import Combine
import Foundation
import SwiftUI

// MARK: - 自動閱讀控制器

/// Timer-driven auto page turning / auto scrolling
/// 速度範圍 0.5x ~ 5.0x（越快，翻頁間隔越短）
final class AutoReadController: ObservableObject {

    @Published var isRunning = false
    @Published var speed: Double = 1.0  // 1x = 每 4 秒翻一頁

    var onNextPage: (() -> Void)?

    private var timer: Timer?

    /// 翻頁間隔（秒）
    private var interval: TimeInterval {
        max(0.5, 4.0 / speed)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer()
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    /// 觸控時自動暫停
    func touchPause() {
        guard isRunning else { return }
        pause()
    }

    /// 速度改變時重新排程
    func updateSpeed(_ newSpeed: Double) {
        speed = max(0.5, min(newSpeed, 5.0))
        if isRunning {
            timer?.invalidate()
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onNextPage?()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
