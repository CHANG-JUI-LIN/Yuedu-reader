import Foundation
import Testing
@testable import yuedu_app

@MainActor
struct AutoReadControllerTests {

    private static let key = "yd_auto_read_seconds_per_page"
    private static let legacyKey = "yd_auto_read_speed"

    private func makeController() -> AutoReadController {
        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        return AutoReadController()
    }

    // MARK: - Mode

    @Test("Entering and exiting are idempotent")
    func modeIsIdempotent() {
        let controller = makeController()
        #expect(!controller.isActive)

        controller.enter()
        controller.enter()
        #expect(controller.isActive)

        controller.exit()
        controller.exit()
        #expect(!controller.isActive)
    }

    @Test("Leaving the reader always ends the mode")
    func readerExitAlwaysStops() {
        let controller = makeController()
        controller.stopForReaderExit()
        #expect(!controller.isActive)

        controller.enter()
        controller.stopForReaderExit()
        #expect(!controller.isActive)
    }

    /// Pausing is not stopping: the reveal holds its place while the menu is up.
    @Test("Pausing holds the reveal, and only applies while the mode is on")
    func pauseHoldsTheReveal() {
        let controller = makeController()
        controller.pause()
        #expect(!controller.isPaused)

        controller.enter()
        controller.pause()
        #expect(controller.isPaused)
        #expect(controller.isActive)

        controller.resume()
        #expect(!controller.isPaused)

        controller.exit()
        #expect(!controller.isPaused)
    }

    // MARK: - Speed

    /// legado's slider: 1–120 seconds for one page, whole numbers, default 10.
    @Test("Seconds per page are clamped, rounded, and default when nonsense")
    func secondsAreClamped() {
        let controller = makeController()
        #expect(controller.secondsPerPage == AutoReadController.defaultSecondsPerPage)

        controller.setSecondsPerPage(500)
        #expect(controller.secondsPerPage == AutoReadController.secondsPerPageRange.upperBound)

        controller.setSecondsPerPage(0)
        #expect(controller.secondsPerPage == AutoReadController.secondsPerPageRange.lowerBound)

        controller.setSecondsPerPage(10.4)
        #expect(controller.secondsPerPage == 10)

        controller.setSecondsPerPage(.nan)
        #expect(controller.secondsPerPage == AutoReadController.defaultSecondsPerPage)
    }

    @Test("Seconds survive a new controller")
    func secondsArePersisted() {
        let controller = makeController()
        controller.setSecondsPerPage(25)

        let reopened = AutoReadController()
        #expect(reopened.secondsPerPage == 25)

        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// The old value was a 0.5×–5× multiplier over a four-second page. A stored
    /// `2.0` is ambiguous between the two scales, which is why the new value has
    /// a key of its own and the old one is read exactly once.
    @Test("An old multiplier is converted the first time it is read")
    func legacyMultiplierMigrates() {
        for (multiplier, expected) in [(0.5, 8.0), (1.0, 4.0), (2.0, 2.0), (5.0, 1.0)] {
            UserDefaults.standard.removeObject(forKey: Self.key)
            UserDefaults.standard.set(multiplier, forKey: Self.legacyKey)

            let controller = AutoReadController()
            #expect(controller.secondsPerPage == expected)
            // Converted once and written under the new key, so the old value is
            // never reinterpreted a second time.
            #expect(UserDefaults.standard.object(forKey: Self.key) as? Double == expected)
        }

        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }

    @Test("Readouts match what the panel prints")
    func readouts() {
        let controller = makeController()
        controller.setSecondsPerPage(10)

        #expect(AutoReadController.secondsText(10) == "10s")
        #expect(controller.secondsText == "10s")
        #expect(controller.intervalDescription.contains("10"))
    }

    // MARK: - Frame arithmetic

    @Test("A frame advances the page by elapsed / secondsPerPage")
    func fractionFollowsElapsedTime() {
        #expect(AutoReadController.fraction(ofPageIn: 1, secondsPerPage: 10) == 0.1)
        #expect(AutoReadController.fraction(ofPageIn: 10, secondsPerPage: 10) == 1)
        // Below the slider's floor the velocity is capped, not divided by zero.
        #expect(AutoReadController.fraction(ofPageIn: 1, secondsPerPage: 0).isFinite)
    }

    @Test("Crossing a page boundary turns exactly one page")
    func oneTurnPerBoundary() {
        let advance = AutoReadController.advance(progress: 0.9, by: 0.2)
        #expect(advance.pageTurns == 1)
        #expect(abs(advance.progress - 0.1) < 1e-9)
    }

    @Test("A frame long enough to cover several pages turns all of them")
    func longFrameTurnsEveryPage() {
        let advance = AutoReadController.advance(progress: 0, by: 2.5)
        #expect(advance.pageTurns == 2)
        #expect(abs(advance.progress - 0.5) < 1e-9)
    }

    /// legado-E zeroes the progress at a page boundary and so loses the
    /// overshoot — up to a frame of drift per page. Subtracting keeps the total
    /// honest over a long run, which is what this asserts.
    @Test("Progress does not drift over many pages")
    func progressDoesNotDrift() {
        let secondsPerPage = 10.0
        let frame = 1.0 / 60
        var progress = 0.0
        var turns = 0

        // Exactly ten pages' worth of frames.
        let frames = Int((secondsPerPage * 10 / frame).rounded())
        for _ in 0..<frames {
            let advance = AutoReadController.advance(
                progress: progress,
                by: AutoReadController.fraction(ofPageIn: frame, secondsPerPage: secondsPerPage)
            )
            progress = advance.progress
            turns += advance.pageTurns
        }

        // Total distance travelled, not the turn count on its own: whether the
        // 6000th frame lands a hair before or after the boundary is float noise,
        // but the sum of turns and leftover progress must still be ten pages.
        #expect(abs(Double(turns) + progress - 10) < 1e-6)
    }

    @Test("A nonsense frame time moves nothing")
    func nonsenseFrameIsIgnored() {
        #expect(AutoReadController.advance(progress: 0.4, by: 0) == .init(progress: 0.4, pageTurns: 0))
        #expect(AutoReadController.advance(progress: 0.4, by: .nan) == .init(progress: 0.4, pageTurns: 0))
        #expect(AutoReadController.advance(progress: 0.4, by: -1) == .init(progress: 0.4, pageTurns: 0))
    }
}
