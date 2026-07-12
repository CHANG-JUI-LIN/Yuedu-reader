import Testing

@Suite("Reader Touch Zone Editor Model")
@MainActor
struct ReaderTouchZoneEditorModelTests {
    @Test("draft changes persist only when saved")
    func savesDraft() {
        var saved: TouchZoneConfig?
        var disabledGlobalPaging = false
        let model = ReaderTouchZoneEditorModel(
            initial: .default,
            save: { saved = $0 },
            disableGlobalPaging: { disabledGlobalPaging = true }
        )

        model.set(.none, at: 0)
        #expect(saved == nil)

        #expect(model.save(isProActive: true))
        #expect(saved?.zones[0] == .none)
        #expect(disabledGlobalPaging)
    }

    @Test("restore defaults changes only the draft")
    func restoresDraft() {
        var saved = TouchZoneConfig(zones: Array(repeating: .none, count: 9))
        let model = ReaderTouchZoneEditorModel(
            initial: saved,
            save: { saved = $0 },
            disableGlobalPaging: {}
        )

        model.restoreDefault()

        #expect(model.draft == .default)
        #expect(saved.zones.allSatisfy { $0 == .none })
    }

    @Test("lost Pro access refuses to save")
    func refusesSaveWithoutPro() {
        var didSave = false
        let model = ReaderTouchZoneEditorModel(
            initial: .default,
            save: { _ in didSave = true },
            disableGlobalPaging: {}
        )

        #expect(!model.save(isProActive: false))
        #expect(!didSave)
    }
}
