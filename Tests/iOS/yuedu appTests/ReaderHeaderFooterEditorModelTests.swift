import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader header and footer editor draft")
@MainActor
struct ReaderHeaderFooterEditorModelTests {
    private struct SaveFailure: Error {}

    @Test("adding a component appends and selects it")
    func addSelectsComponent() {
        let model = makeModel()
        let component = ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        )

        model.add(component)

        #expect(model.draft.components.last == component)
        #expect(model.selectedComponentID == component.id)
    }

    @Test("all mutations stay inside the active page scope")
    func mutationsAreScopeLocal() throws {
        let opening = ReaderOverlayComponent.make(
            kind: .bookTitle,
            position: ReaderOverlayNormalizedPoint(x: 0.2, y: 0.2)
        )
        let body = ReaderOverlayComponent.make(
            kind: .chapterPage,
            position: ReaderOverlayNormalizedPoint(x: 0.8, y: 0.8)
        )
        let initial = ReaderOverlayLayout(
            components: [body],
            chapterOpeningComponents: [opening],
            contentReservations: ReaderOverlayContentReservations(top: 34, bottom: 32)
        )
        let model = makeModel(initial: initial, activeScope: .chapterOpening)
        let added = ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        )

        model.add(added)
        var updated = added
        updated.configuration.customText = "Opening only"
        model.update(updated)
        model.move(
            id: opening.id,
            to: ReaderOverlayNormalizedPoint(x: 0.3, y: 0.4)
        )
        model.delete(id: added.id)
        model.undoDelete()

        let openingResult = model.draft.components(for: .chapterOpening)
        #expect(openingResult.count == 2)
        #expect(openingResult.first?.position == ReaderOverlayNormalizedPoint(x: 0.3, y: 0.4))
        #expect(openingResult.last?.configuration.customText == "Opening only")
        #expect(model.draft.components(for: .chapterBody) == [body])
    }

    @Test("switching page scope clears selection and scoped undo")
    func switchingScopeClearsTransientState() throws {
        let model = makeModel(activeScope: .chapterOpening)
        let opening = try #require(model.activeComponents.first)
        model.selectedComponentID = opening.id
        model.delete(id: opening.id)
        #expect(model.lastDeleted != nil)

        model.activeScope = .chapterBody

        #expect(model.selectedComponentID == nil)
        #expect(model.lastDeleted == nil)
        #expect(model.activeComponents == model.draft.components(for: .chapterBody))
    }

    @Test("duplicate component IDs are not added")
    func duplicateAddIsIgnored() {
        let original = ReaderOverlayLayout.default
        let model = makeModel(initial: original)

        model.add(original.components[0])

        #expect(model.draft == original)
    }

    @Test("known components update and move while unknown IDs do nothing")
    func updateMoveAndUnknownIDs() {
        let original = ReaderOverlayLayout.default
        let model = makeModel(initial: original)
        let first = original.components[0]
        var updated = first
        updated.configuration.customText = "Changed"

        model.update(updated)
        model.move(
            id: first.id,
            to: ReaderOverlayNormalizedPoint(x: 2, y: -.infinity)
        )
        let afterKnownChanges = model.draft

        var unknown = updated
        unknown.id = UUID()
        model.update(unknown)
        model.move(id: unknown.id, to: ReaderOverlayNormalizedPoint(x: 0, y: 0))
        model.delete(id: unknown.id)

        #expect(model.draft == afterKnownChanges)
        #expect(model.draft.components[0].configuration.customText == "Changed")
        #expect(model.draft.components[0].position == ReaderOverlayNormalizedPoint(x: 1, y: 0.5))
    }

    @Test("delete preserves the original index and undo restores it")
    func deleteUndoRestoresOrder() throws {
        let original = ReaderOverlayLayout.default
        let model = makeModel(initial: original)
        let removed = original.components[1]
        model.selectedComponentID = removed.id

        model.delete(id: removed.id)

        #expect(model.draft.components.count == original.components.count - 1)
        #expect(model.lastDeleted?.component == removed)
        #expect(model.lastDeleted?.index == 1)
        #expect(model.selectedComponentID == nil)

        model.undoDelete()

        #expect(model.draft == original)
        #expect(model.lastDeleted == nil)
        #expect(model.selectedComponentID == removed.id)
    }

    @Test("re-adding a deleted UUID invalidates its stale undo record")
    func readdingDeletedIDCannotDuplicateIt() {
        let original = ReaderOverlayLayout.default
        let removed = original.components[1]
        let model = makeModel(initial: original)

        model.delete(id: removed.id)
        model.add(removed)
        model.undoDelete()

        #expect(model.lastDeleted == nil)
        #expect(model.draft.components.count == original.components.count)
        #expect(Set(model.draft.components.map(\.id)).count == model.draft.components.count)
    }

    @Test("cancel discards every draft change without saving")
    func cancelDiscardsChanges() {
        var saved: [ReaderOverlayLayout] = []
        let original = ReaderOverlayLayout.default
        let model = ReaderHeaderFooterEditorModel(initial: original) { saved.append($0) }
        model.move(
            id: original.components[0].id,
            to: ReaderOverlayNormalizedPoint(x: 0.8, y: 0.8)
        )

        model.cancel()

        #expect(saved.isEmpty)
        #expect(model.draft == original)
        #expect(model.isFinished)
    }

    @Test("done saves one normalized layout")
    func doneSavesOnce() throws {
        var saved: [ReaderOverlayLayout] = []
        let component = ReaderOverlayComponent(
            id: UUID(),
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: -4, y: .infinity),
            style: ReaderOverlayComponentStyle(
                fontSize: 500,
                opacity: .nan
            )
        )
        let initial = ReaderOverlayLayout(
            version: 0,
            components: [component],
            contentReservations: ReaderOverlayContentReservations(top: -2, bottom: 500)
        )
        let model = ReaderHeaderFooterEditorModel(initial: initial) { saved.append($0) }

        #expect(model.done())
        #expect(model.done() == false)

        let result = try #require(saved.first)
        #expect(saved.count == 1)
        #expect(result.version == ReaderOverlayLayout.currentVersion)
        #expect(result.components[0].position == ReaderOverlayNormalizedPoint(x: 0, y: 0.5))
        #expect(result.components[0].style.fontSize == 72)
        #expect(result.components[0].style.opacity == ReaderOverlayComponentStyle.defaultOpacity)
        #expect(result.contentReservations == ReaderOverlayContentReservations(top: 0, bottom: 120))
        #expect(model.draft == result)
    }

    @Test("a save failure keeps the draft editable and retryable")
    func saveFailureKeepsDraft() {
        var attempts = 0
        var saved: [ReaderOverlayLayout] = []
        let model = ReaderHeaderFooterEditorModel(initial: .default) { layout in
            attempts += 1
            if attempts == 1 { throw SaveFailure() }
            saved.append(layout)
        }

        #expect(model.done() == false)
        #expect(model.saveError != nil)
        #expect(model.isFinished == false)

        let component = ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        )
        model.add(component)
        #expect(model.saveError == nil)
        #expect(model.done())
        #expect(saved.count == 1)
    }

    @Test("duplicate IDs are rejected before persistence")
    func duplicateInitialIDsAreRejected() throws {
        let component = ReaderOverlayLayout.default.components[0]
        let initial = ReaderOverlayLayout(
            components: [component, component],
            contentReservations: ReaderOverlayContentReservations(top: 0, bottom: 0)
        )
        var saved: [ReaderOverlayLayout] = []
        let model = ReaderHeaderFooterEditorModel(initial: initial) { saved.append($0) }

        #expect(model.done() == false)

        let error = try #require(
            model.saveError as? ReaderHeaderFooterEditorValidationError
        )
        #expect(error == .duplicateComponentID(component.id))
        #expect(saved.isEmpty)
        #expect(model.isFinished == false)
    }

    @Test("the same component ID is valid in different scopes")
    func matchingIDsAcrossScopesAreValid() {
        let component = ReaderOverlayLayout.default.components[0]
        let initial = ReaderOverlayLayout(
            components: [component],
            chapterOpeningComponents: [component],
            contentReservations: ReaderOverlayContentReservations(top: 0, bottom: 0)
        )
        var saved: [ReaderOverlayLayout] = []
        let model = ReaderHeaderFooterEditorModel(initial: initial) { saved.append($0) }

        #expect(model.done())
        #expect(saved.count == 1)
    }

    @Test("duplicate IDs inside the opening scope are rejected")
    func duplicateOpeningIDsAreRejected() throws {
        let component = ReaderOverlayLayout.default.components[0]
        let initial = ReaderOverlayLayout(
            components: [],
            chapterOpeningComponents: [component, component],
            contentReservations: ReaderOverlayContentReservations(top: 0, bottom: 0)
        )
        let model = makeModel(initial: initial, activeScope: .chapterOpening)

        #expect(model.done() == false)
        #expect(
            model.saveError as? ReaderHeaderFooterEditorValidationError
                == .duplicateComponentID(component.id)
        )
    }

    @Test("future layout versions are never overwritten")
    func futureVersionIsRejected() throws {
        var initial = ReaderOverlayLayout.default
        initial.version = ReaderOverlayLayout.currentVersion + 1
        var saved: [ReaderOverlayLayout] = []
        let model = ReaderHeaderFooterEditorModel(initial: initial) { saved.append($0) }

        #expect(model.done() == false)

        let error = try #require(
            model.saveError as? ReaderHeaderFooterEditorValidationError
        )
        #expect(error == .unsupportedLayoutVersion(initial.version))
        #expect(saved.isEmpty)
        #expect(model.isFinished == false)
        #expect(model.draft == initial)
    }

    @Test("mutations after a successful finish are ignored")
    func finishedModelIsTerminal() {
        let model = makeModel()
        #expect(model.done())
        let savedDraft = model.draft

        model.add(ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        ))
        model.delete(id: savedDraft.components[0].id)
        model.cancel()

        #expect(model.draft == savedDraft)
    }

    private func makeModel(
        initial: ReaderOverlayLayout = .default,
        activeScope: ReaderOverlayPageScope = .chapterBody
    ) -> ReaderHeaderFooterEditorModel {
        ReaderHeaderFooterEditorModel(initial: initial, activeScope: activeScope) { _ in }
    }
}
