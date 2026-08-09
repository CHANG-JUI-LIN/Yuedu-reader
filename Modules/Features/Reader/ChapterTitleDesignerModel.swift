import Combine
import SwiftUI

@MainActor
final class ChapterTitleDesignerModel: ObservableObject {
    @Published private(set) var draft: ChapterTitleDesign
    @Published var selectedLayerID: UUID?
    @Published var activeAppearance: ReaderStyleAppearance = .light
    @Published var previewWritingMode: ReaderWritingMode = .horizontal
    @Published private(set) var validationError: Error?
    @Published private(set) var isFinished = false
    @Published private(set) var isAssetMutationInProgress = false

    let original: ChapterTitleDesign

    private var undoStack: [ChapterTitleDesign] = []
    private var redoStack: [ChapterTitleDesign] = []
    private var continuousMutationOrigin: ChapterTitleDesign?
    private let onSave: (ChapterTitleDesign) throws -> Void

    var canUndo: Bool { !undoStack.isEmpty && continuousMutationOrigin == nil }
    var canRedo: Bool { !redoStack.isEmpty && continuousMutationOrigin == nil }
    var hasChanges: Bool { draft != original }

    init(
        initial: ChapterTitleDesign,
        onSave: @escaping (ChapterTitleDesign) throws -> Void
    ) {
        let sanitized = initial.sanitized()
        original = sanitized
        draft = sanitized
        selectedLayerID = sanitized.layers.first?.id
        self.onSave = onSave
    }

    func add(_ layer: ChapterTitleLayer) {
        recordMutation { design in
            design.layers.append(layer)
        }
        selectedLayerID = layer.id
    }

    func duplicate(id: UUID) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = draft.layers[index]
        copy.id = UUID()
        copy.name = String(format: localized("%@ 副本"), copy.name)
        copy.isLocked = false
        let destination = min(index + 1, draft.layers.count)
        recordMutation { design in
            design.layers.insert(copy, at: destination)
        }
        selectedLayerID = copy.id
    }

    func delete(id: UUID) {
        guard draft.layers.contains(where: { $0.id == id }) else { return }
        recordMutation { design in
            design.layers.removeAll { $0.id == id }
        }
        if selectedLayerID == id {
            selectedLayerID = draft.layers.first?.id
        }
    }

    func moveLayer(fromOffsets: IndexSet, toOffset: Int) {
        guard !fromOffsets.isEmpty else { return }
        recordMutation { design in
            design.layers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }

    func move(id: UUID, to frame: ReaderStyleNormalizedRect) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }),
              !draft.layers[index].isLocked else { return }
        recordMutation { design in
            design.layers[index].frame = frame
        }
    }

    func rotate(id: UUID, degrees: Double) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }),
              !draft.layers[index].isLocked else { return }
        recordMutation { design in
            design.layers[index].rotation = ReaderStyleRotation(degrees: degrees)
        }
    }

    func updateStyle(
        id: UUID,
        appearance: ReaderStyleAppearance,
        style: ChapterTitleLayerStyle
    ) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        recordMutation { design in
            switch appearance {
            case .light: design.layers[index].lightStyle = style
            case .dark: design.layers[index].darkStyle = style
            }
        }
    }

    func updateContent(id: UUID, content: ChapterTitleLayerContent) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        recordMutation { design in
            design.layers[index].content = content
        }
    }

    /// Clears every design-owned reference to an asset in one history entry.
    /// Forced deletion deletes from the store first; this mutation is then
    /// infallible, so a store failure can never leave the draft partially edited.
    @discardableResult
    func removeAssetReferences(assetID: UUID) -> Bool {
        guard canMutate else { return false }
        let next = draft.removingAssetReferences(assetID)
        guard next != draft else { return true }
        return recordMutation { $0 = next }
    }

    /// Deletes the managed file and commits the already-prepared reference-free
    /// draft as one editor transaction. Other draft mutations are blocked while
    /// the actor performs I/O, so success cannot leave a dangling asset ID and a
    /// store error cannot partially change the design.
    @discardableResult
    func deleteAsset(
        id: UUID,
        store: ReaderStyleAssetStore = .shared
    ) async -> Bool {
        guard canMutate else { return false }
        let originalDraft = draft
        let next = draft.removingAssetReferences(id)
        isAssetMutationInProgress = true
        defer { isAssetMutationInProgress = false }
        do {
            try await store.delete(id, removingReferences: true)
            if next != originalDraft {
                appendUndo(originalDraft)
                redoStack.removeAll()
                draft = next.sanitized()
                validationError = nil
            }
            repairSelection()
            return true
        } catch {
            validationError = error
            return false
        }
    }

    func rename(id: UUID, to name: String) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        recordMutation { design in
            design.layers[index].name = name
        }
    }

    func setVisible(_ value: Bool, id: UUID) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        recordMutation { design in
            design.layers[index].isVisible = value
        }
    }

    func setLocked(_ value: Bool, id: UUID) {
        guard let index = draft.layers.firstIndex(where: { $0.id == id }) else { return }
        recordMutation { design in
            design.layers[index].isLocked = value
        }
    }

    @discardableResult
    func applySource(light: String, dark: String) -> Bool {
        guard canMutate else { return false }
        do {
            let decoded = try ChapterTitleHTMLCodec.decode(light: light, dark: dark)
            guard decoded != draft else {
                validationError = nil
                return true
            }
            guard recordMutation({ $0 = decoded }) else { return false }
            validationError = nil
            if !draft.layers.contains(where: { $0.id == selectedLayerID }) {
                selectedLayerID = draft.layers.first?.id
            }
            return true
        } catch {
            validationError = error
            return false
        }
    }

    func beginContinuousMutation() {
        guard !isFinished, !isAssetMutationInProgress,
              continuousMutationOrigin == nil else { return }
        continuousMutationOrigin = draft
    }

    func updateContinuousFrame(id: UUID, frame: ReaderStyleNormalizedRect) {
        guard !isFinished, !isAssetMutationInProgress,
              continuousMutationOrigin != nil,
              let index = draft.layers.firstIndex(where: { $0.id == id }),
              !draft.layers[index].isLocked else { return }
        draft.layers[index].frame = frame
        draft = draft.sanitized()
        validationError = nil
    }

    func updateContinuousRotation(id: UUID, degrees: Double) {
        guard !isFinished, !isAssetMutationInProgress,
              continuousMutationOrigin != nil,
              let index = draft.layers.firstIndex(where: { $0.id == id }),
              !draft.layers[index].isLocked else { return }
        draft.layers[index].rotation = ReaderStyleRotation(degrees: degrees)
        validationError = nil
    }

    func endContinuousMutation() {
        guard let origin = continuousMutationOrigin else { return }
        continuousMutationOrigin = nil
        guard origin != draft else { return }
        appendUndo(origin)
        redoStack.removeAll()
    }

    func cancelContinuousMutation() {
        guard let origin = continuousMutationOrigin else { return }
        continuousMutationOrigin = nil
        draft = origin
    }

    func undo() {
        guard continuousMutationOrigin == nil, let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = previous
        validationError = nil
        repairSelection()
    }

    func redo() {
        guard continuousMutationOrigin == nil, let next = redoStack.popLast() else { return }
        appendUndo(draft)
        draft = next
        validationError = nil
        repairSelection()
    }

    func cancel() {
        guard !isFinished else { return }
        cancelContinuousMutation()
        isFinished = true
    }

    @discardableResult
    func done() -> Bool {
        guard !isFinished, continuousMutationOrigin == nil else { return false }
        do {
            try onSave(draft.sanitized())
            validationError = nil
            isFinished = true
            return true
        } catch {
            validationError = error
            return false
        }
    }

    @discardableResult
    private func recordMutation(_ mutation: (inout ChapterTitleDesign) -> Void) -> Bool {
        guard canMutate else { return false }
        var next = draft
        mutation(&next)
        next = next.sanitized()
        guard next != draft else { return true }
        appendUndo(draft)
        redoStack.removeAll()
        draft = next
        validationError = nil
        return true
    }

    private func appendUndo(_ design: ChapterTitleDesign) {
        undoStack.append(design)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
    }

    private func repairSelection() {
        guard let selectedLayerID,
              draft.layers.contains(where: { $0.id == selectedLayerID }) else {
            selectedLayerID = draft.layers.first?.id
            return
        }
    }

    private var canMutate: Bool {
        !isFinished && !isAssetMutationInProgress && continuousMutationOrigin == nil
    }
}

private extension ChapterTitleDesign {
    func removingAssetReferences(_ assetID: UUID) -> ChapterTitleDesign {
        var result = self
        for index in result.layers.indices {
            if case let .image(id) = result.layers[index].content, id == assetID {
                result.layers[index].content = .none
            }
            if result.layers[index].lightStyle.imagePresentation?.assetID == assetID {
                result.layers[index].lightStyle.imagePresentation = nil
            }
            if result.layers[index].darkStyle.imagePresentation?.assetID == assetID {
                result.layers[index].darkStyle.imagePresentation = nil
            }
            if result.layers[index].lightStyle.ruleStyle.decoration.backgroundImage?.assetID == assetID {
                result.layers[index].lightStyle.ruleStyle.decoration.backgroundImage = nil
            }
            if result.layers[index].darkStyle.ruleStyle.decoration.backgroundImage?.assetID == assetID {
                result.layers[index].darkStyle.ruleStyle.decoration.backgroundImage = nil
            }
        }
        let token = "yuedu-asset://\(assetID.uuidString.lowercased())"
        if result.legacySource?.light.lowercased().contains(token) == true
            || result.legacySource?.dark.lowercased().contains(token) == true {
            // Migrated layers are authoritative. Dropping the audit-only source
            // prevents future export from retaining a reference to a deleted file.
            result.legacySource = nil
        }
        return result.sanitized()
    }
}
