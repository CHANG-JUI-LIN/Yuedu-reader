import Combine
import Foundation
import SwiftUI

// MARK: - Auto Read Controller

/// Timer-driven auto page turning / auto scrolling
/// Speed range 0.5x ~ 5.0x (faster = shorter page-turn interval)
final class AutoReadController: ObservableObject {

    @Published var isRunning = false
    @Published var speed: Double = 1.0  // 1x = one page every 4 seconds

    var onNextPage: (() -> Void)?

    private var timer: Timer?

    /// Page turn interval (seconds)
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

    /// Auto-pause on touch
    func touchPause() {
        guard isRunning else { return }
        pause()
    }

    /// Reschedule when speed changes
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
