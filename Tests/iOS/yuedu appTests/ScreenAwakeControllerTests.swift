import Testing
@testable import yuedu_app

@MainActor
struct ScreenAwakeControllerTests {

    /// Stands in for a reader, a narrator, an auto-reader: anything that holds a reason.
    private final class Holder {}

    /// What the controller wrote to the idle timer, in order.
    private final class IdleTimerRecorder {
        var writes: [Bool] = []
    }

    private func makeController() -> (ScreenAwakeController, IdleTimerRecorder) {
        let recorder = IdleTimerRecorder()
        let controller = ScreenAwakeController { recorder.writes.append($0) }
        return (controller, recorder)
    }

    @Test("朗讀 stopping while 自動閱讀 runs keeps the screen on")
    func narrationStopKeepsAutoReadAwake() {
        let (controller, recorder) = makeController()
        let reader = Holder()
        let narrator = Holder()

        controller.setHeld(true, .narration, by: narrator)
        controller.setHeld(true, .autoRead, by: reader)
        controller.setHeld(false, .narration, by: narrator)

        #expect(controller.keepsScreenAwake)
        #expect(recorder.writes == [true])
    }

    @Test("自動閱讀 ending while 朗讀 plays keeps the screen on")
    func autoReadExitKeepsNarrationAwake() {
        let (controller, recorder) = makeController()
        let reader = Holder()
        let narrator = Holder()

        controller.setHeld(true, .autoRead, by: reader)
        controller.setHeld(true, .narration, by: narrator)
        controller.setHeld(false, .autoRead, by: reader)

        #expect(controller.keepsScreenAwake)
        #expect(recorder.writes == [true])
    }

    @Test("A reader closing after the next one opened leaves the next one's hold")
    func readersDoNotReleaseEachOther() {
        let (controller, recorder) = makeController()
        let closing = Holder()
        let opening = Holder()

        controller.setHeld(true, .reading, by: closing)
        controller.setHeld(true, .reading, by: opening)
        controller.setHeld(false, .reading, by: closing)

        #expect(controller.keepsScreenAwake)
        #expect(controller.isHeld(.reading, by: opening))
        #expect(!controller.isHeld(.reading, by: closing))
        #expect(recorder.writes == [true])
    }

    @Test("The last reason released lets the screen sleep again")
    func lastReleaseReenablesIdleTimer() {
        let (controller, recorder) = makeController()
        let reader = Holder()
        let narrator = Holder()

        controller.setHeld(true, .reading, by: reader)
        controller.setHeld(true, .autoRead, by: reader)
        controller.setHeld(true, .narration, by: narrator)
        controller.setHeld(false, .narration, by: narrator)
        controller.setHeld(false, .reading, by: reader)
        controller.setHeld(false, .autoRead, by: reader)

        #expect(!controller.keepsScreenAwake)
        #expect(recorder.writes == [true, false])
    }

    @Test("Holding twice is one hold, and releasing what was never held does nothing")
    func holdsAreIdempotent() {
        let (controller, recorder) = makeController()
        let reader = Holder()
        let stranger = Holder()

        controller.setHeld(false, .reading, by: reader)
        #expect(recorder.writes.isEmpty)

        controller.setHeld(true, .reading, by: reader)
        controller.setHeld(true, .reading, by: reader)
        controller.setHeld(false, .reading, by: stranger)
        controller.setHeld(false, .autoRead, by: reader)
        #expect(controller.keepsScreenAwake)

        controller.setHeld(false, .reading, by: reader)
        #expect(!controller.keepsScreenAwake)
        #expect(recorder.writes == [true, false])
    }

    @Test("自動閱讀 holds the screen for exactly as long as it runs")
    func autoReadControllerHoldsWhileActive() {
        let autoReader = AutoReadController()
        let shared = ScreenAwakeController.shared
        #expect(!shared.isHeld(.autoRead, by: autoReader))

        autoReader.enter()
        #expect(shared.isHeld(.autoRead, by: autoReader))

        autoReader.exit()
        #expect(!shared.isHeld(.autoRead, by: autoReader))

        autoReader.enter()
        autoReader.stopForReaderExit()
        #expect(!shared.isHeld(.autoRead, by: autoReader))
    }
}
