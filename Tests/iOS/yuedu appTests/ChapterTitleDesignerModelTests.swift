import Testing
@testable import yuedu_app

@Suite("Chapter title designer draft")
@MainActor
struct ChapterTitleDesignerModelTests {
    @Test("locked layers reject canvas mutations but accept unlocking")
    func lockedLayer() throws {
        var locked = try #require(ChapterTitleDesign.default.layers.first)
        locked.isLocked = true
        let model = ChapterTitleDesignerModel(
            initial: .init(layers: [locked])
        ) { _ in }

        model.move(id: locked.id, to: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1))
        #expect(model.draft.layers[0].frame == locked.frame)

        model.setLocked(false, id: locked.id)
        model.move(id: locked.id, to: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1))
        #expect(model.draft.layers[0].frame.x == 0.8)
    }

    @Test("undo and redo restore complete layer snapshots")
    func history() throws {
        let original = ChapterTitleDesign.default
        let id = try #require(original.layers.first?.id)
        let model = ChapterTitleDesignerModel(initial: original) { _ in }

        model.rename(id: id, to: "Renamed")
        model.rotate(id: id, degrees: 45)
        model.undo()
        #expect(model.draft.layers[0].rotation.degrees == 0)
        #expect(model.draft.layers[0].name == "Renamed")
        model.undo()
        #expect(model.draft == original)
        model.redo()
        #expect(model.draft.layers[0].name == "Renamed")
    }

    @Test("invalid source never partially replaces the draft")
    func invalidSourceIsAtomic() {
        let original = ChapterTitleDesign.default
        let model = ChapterTitleDesignerModel(initial: original) { _ in }

        #expect(model.applySource(light: "<script></script>", dark: "<div></div>") == false)
        #expect(model.draft == original)
        #expect(model.validationError != nil)
    }

    @Test("done saves one sanitized design and cancel saves nothing")
    func saveAndCancel() {
        var saved: [ChapterTitleDesign] = []
        let saveModel = ChapterTitleDesignerModel(initial: .default) { saved.append($0) }
        #expect(saveModel.done())
        #expect(saveModel.done() == false)
        #expect(saved.count == 1)

        let cancelModel = ChapterTitleDesignerModel(initial: .default) { saved.append($0) }
        cancelModel.cancel()
        #expect(saved.count == 1)
    }

    @Test("continuous edits create one undo snapshot")
    func continuousHistory() throws {
        let original = ChapterTitleDesign.default
        let id = try #require(original.layers.first?.id)
        let model = ChapterTitleDesignerModel(initial: original) { _ in }

        model.beginContinuousMutation()
        model.updateContinuousFrame(id: id, frame: .init(x: 0.2, y: 0.2, width: 0.5, height: 0.2))
        model.updateContinuousFrame(id: id, frame: .init(x: 0.3, y: 0.3, width: 0.4, height: 0.2))
        model.endContinuousMutation()
        model.undo()

        #expect(model.draft == original)
        #expect(model.canUndo == false)
    }

    @Test("removing an asset clears every reference in one undo step")
    func removeAssetReferences() throws {
        let assetID = readerStyleFixtureUUID(71)
        var layer = try #require(ChapterTitleDesign.default.layers.first)
        layer.content = .image(assetID)
        layer.lightStyle.imagePresentation = .init(assetID: assetID)
        layer.darkStyle.ruleStyle.decoration.backgroundImage = .init(assetID: assetID)
        let original = ChapterTitleDesign(layers: [layer])
        let model = ChapterTitleDesignerModel(initial: original) { _ in }

        model.removeAssetReferences(assetID: assetID)
        #expect(model.draft.layers[0].content == .none)
        #expect(model.draft.layers[0].lightStyle.imagePresentation == nil)
        #expect(model.draft.layers[0].darkStyle.ruleStyle.decoration.backgroundImage == nil)

        model.undo()
        #expect(model.draft == original)
        #expect(model.canUndo == false)
    }

    @Test("finished and continuous states reject unrelated mutations")
    func mutationGuards() throws {
        let original = ChapterTitleDesign.default
        let id = try #require(original.layers.first?.id)
        let model = ChapterTitleDesignerModel(initial: original) { _ in }

        model.beginContinuousMutation()
        #expect(model.applySource(
            light: ChapterTitleHTMLCodec.encode(original, appearance: .light),
            dark: ChapterTitleHTMLCodec.encode(original, appearance: .dark)
        ) == false)
        model.cancel()
        model.beginContinuousMutation()
        model.updateContinuousRotation(id: id, degrees: 45)

        #expect(model.draft == original)
        #expect(model.removeAssetReferences(assetID: readerStyleFixtureUUID(99)) == false)
    }
}
