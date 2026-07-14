import Combine
import Foundation

enum ReaderHeaderFooterEditorValidationError: Error, Equatable, Sendable {
    case duplicateComponentID(UUID)
    case unsupportedLayoutVersion(Int)
}

@MainActor
final class ReaderHeaderFooterEditorModel: ObservableObject {
    @Published private(set) var draft: ReaderOverlayLayout
    @Published var selectedComponentID: UUID?
    @Published private(set) var lastDeleted: (
        component: ReaderOverlayComponent,
        index: Int
    )?
    @Published private(set) var saveError: Error?
    @Published private(set) var isFinished = false

    let original: ReaderOverlayLayout

    private let onSave: (ReaderOverlayLayout) throws -> Void
    private var isSaving = false

    init(
        initial: ReaderOverlayLayout,
        onSave: @escaping (ReaderOverlayLayout) throws -> Void
    ) {
        original = initial
        draft = initial
        self.onSave = onSave
    }

    func add(_ component: ReaderOverlayComponent) {
        guard canEdit,
              !draft.components.contains(where: { $0.id == component.id }) else {
            return
        }
        draft.components.append(component.normalized)
        if lastDeleted?.component.id == component.id {
            lastDeleted = nil
        }
        selectedComponentID = component.id
        didEdit()
    }

    func update(_ component: ReaderOverlayComponent) {
        guard canEdit,
              let index = draft.components.firstIndex(where: { $0.id == component.id }) else {
            return
        }
        draft.components[index] = component.normalized
        didEdit()
    }

    func move(id: UUID, to position: ReaderOverlayNormalizedPoint) {
        guard canEdit,
              let index = draft.components.firstIndex(where: { $0.id == id }) else {
            return
        }
        draft.components[index].position = position.clamped
        didEdit()
    }

    func delete(id: UUID) {
        guard canEdit,
              let index = draft.components.firstIndex(where: { $0.id == id }) else {
            return
        }
        let component = draft.components.remove(at: index)
        lastDeleted = (component: component, index: index)
        if selectedComponentID == id {
            selectedComponentID = nil
        }
        didEdit()
    }

    func undoDelete() {
        guard canEdit, let deletion = lastDeleted else { return }
        guard !draft.components.contains(where: { $0.id == deletion.component.id }) else {
            lastDeleted = nil
            return
        }
        let index = min(max(deletion.index, 0), draft.components.count)
        draft.components.insert(deletion.component, at: index)
        lastDeleted = nil
        selectedComponentID = deletion.component.id
        didEdit()
    }

    func cancel() {
        guard canEdit else { return }
        draft = original
        selectedComponentID = nil
        lastDeleted = nil
        saveError = nil
        isFinished = true
    }

    @discardableResult
    func done() -> Bool {
        guard canEdit else { return false }
        saveError = nil
        if let validationError = validationError(for: draft) {
            saveError = validationError
            return false
        }

        isSaving = true
        defer { isSaving = false }

        let normalized = ReaderOverlayLayoutMigration.upgrade(draft)
        do {
            try onSave(normalized)
            draft = normalized
            selectedComponentID = nil
            lastDeleted = nil
            isFinished = true
            return true
        } catch {
            saveError = error
            return false
        }
    }

    private var canEdit: Bool {
        !isFinished && !isSaving
    }

    private func didEdit() {
        saveError = nil
    }

    private func validationError(
        for layout: ReaderOverlayLayout
    ) -> ReaderHeaderFooterEditorValidationError? {
        guard layout.version <= ReaderOverlayLayout.currentVersion else {
            return .unsupportedLayoutVersion(layout.version)
        }

        var componentIDs: Set<UUID> = []
        for component in layout.components where !componentIDs.insert(component.id).inserted {
            return .duplicateComponentID(component.id)
        }
        return nil
    }
}
