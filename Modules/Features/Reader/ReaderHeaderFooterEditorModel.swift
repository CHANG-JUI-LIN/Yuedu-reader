import Combine
import Foundation

enum ReaderHeaderFooterEditorValidationError: Error, Equatable, Sendable {
    case duplicateComponentID(UUID)
    case unsupportedLayoutVersion(Int)
}

@MainActor
final class ReaderHeaderFooterEditorModel: ObservableObject {
    @Published private(set) var draft: ReaderOverlayLayout
    @Published var activeScope: ReaderOverlayPageScope {
        didSet {
            guard activeScope != oldValue else { return }
            selectedComponentID = nil
            lastDeleted = nil
            onScopeChange(activeScope)
        }
    }
    @Published var selectedComponentID: UUID?
    @Published private(set) var lastDeleted: (
        component: ReaderOverlayComponent,
        index: Int,
        scope: ReaderOverlayPageScope
    )?
    @Published private(set) var saveError: Error?
    @Published private(set) var isFinished = false

    let original: ReaderOverlayLayout

    private let onSave: (ReaderOverlayLayout) throws -> Void
    private let onScopeChange: (ReaderOverlayPageScope) -> Void
    private var isSaving = false

    init(
        initial: ReaderOverlayLayout,
        activeScope: ReaderOverlayPageScope = .chapterBody,
        onScopeChange: @escaping (ReaderOverlayPageScope) -> Void = { _ in },
        onSave: @escaping (ReaderOverlayLayout) throws -> Void
    ) {
        original = initial
        draft = initial
        self.activeScope = activeScope
        self.onScopeChange = onScopeChange
        self.onSave = onSave
    }

    var activeComponents: [ReaderOverlayComponent] {
        draft.components(for: activeScope)
    }

    func add(_ component: ReaderOverlayComponent) {
        guard canEdit,
              !activeComponents.contains(where: { $0.id == component.id }) else {
            return
        }
        var components = activeComponents
        components.append(component.normalized)
        replaceActiveComponents(components)
        if lastDeleted?.component.id == component.id {
            lastDeleted = nil
        }
        selectedComponentID = component.id
        didEdit()
    }

    func update(_ component: ReaderOverlayComponent) {
        guard canEdit,
              let index = activeComponents.firstIndex(where: { $0.id == component.id }) else {
            return
        }
        var components = activeComponents
        components[index] = component.normalized
        replaceActiveComponents(components)
        didEdit()
    }

    func move(id: UUID, to position: ReaderOverlayNormalizedPoint) {
        guard canEdit,
              let index = activeComponents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var components = activeComponents
        components[index].position = position.clamped
        replaceActiveComponents(components)
        didEdit()
    }

    func delete(id: UUID) {
        guard canEdit,
              let index = activeComponents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var components = activeComponents
        let component = components.remove(at: index)
        replaceActiveComponents(components)
        lastDeleted = (component: component, index: index, scope: activeScope)
        if selectedComponentID == id {
            selectedComponentID = nil
        }
        didEdit()
    }

    func undoDelete() {
        guard canEdit,
              let deletion = lastDeleted,
              deletion.scope == activeScope else { return }
        guard !activeComponents.contains(where: { $0.id == deletion.component.id }) else {
            lastDeleted = nil
            return
        }
        var components = activeComponents
        let index = min(max(deletion.index, 0), components.count)
        components.insert(deletion.component, at: index)
        replaceActiveComponents(components)
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

    private func replaceActiveComponents(_ components: [ReaderOverlayComponent]) {
        var next = draft
        next.replaceComponents(components, for: activeScope)
        draft = next
    }

    private func validationError(
        for layout: ReaderOverlayLayout
    ) -> ReaderHeaderFooterEditorValidationError? {
        guard layout.version <= ReaderOverlayLayout.currentVersion else {
            return .unsupportedLayoutVersion(layout.version)
        }

        for scope in ReaderOverlayPageScope.allCases {
            var componentIDs: Set<UUID> = []
            for component in layout.components(for: scope)
            where !componentIDs.insert(component.id).inserted {
                return .duplicateComponentID(component.id)
            }
        }
        return nil
    }
}
