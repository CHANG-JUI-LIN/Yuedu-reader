import YueduCoreText
import AVKit
import UIKit
import SwiftUI

struct BrowserInlineVideoPlacement {
    let nodeID: Int
    let media: EPUBMediaAttachment
    let rect: CGRect
}

/// Owns only embedded AVKit views. The shared EPUB manager owns the players,
/// matching CoreText's background playback and page-revisit lifetime.
@MainActor
final class BrowserInlineVideoCoordinator {
    private weak var owner: UIViewController?
    private let playerProvider: @MainActor (EPUBMediaAttachment) async -> AVPlayer?
    private let isActive: @MainActor (EPUBMediaAttachment) -> Bool
    private var controllers: [Int: AVPlayerViewController] = [:]
    private var bindingTasks: [Int: Task<Void, Never>] = [:]
    private var placements: [BrowserInlineVideoPlacement] = []

    init(
        owner: UIViewController,
        playerProvider: (@MainActor (EPUBMediaAttachment) async -> AVPlayer?)? = nil,
        isActive: (@MainActor (EPUBMediaAttachment) -> Bool)? = nil
    ) {
        self.owner = owner
        self.playerProvider = playerProvider ?? { await EPUBVideoPlaybackManager.shared.player(for: $0) }
        self.isActive = isActive ?? { EPUBVideoPlaybackManager.shared.isActive($0) }
    }

    var embeddedNodeIDs: Set<Int> { Set(controllers.keys) }

    func sync(_ placements: [BrowserInlineVideoPlacement]) {
        let previous = Dictionary(uniqueKeysWithValues: self.placements.map { ($0.nodeID, $0.media) })
        self.placements = placements
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.nodeID, $0) })
        for id in Array(controllers.keys) {
            if byID[id] == nil || previous[id] != byID[id]?.media { detach(id) }
        }
        for placement in placements {
            if let controller = controllers[placement.nodeID] {
                controller.view.frame = placement.rect
            } else if isActive(placement.media) {
                embed(placement)
            }
        }
    }

    @discardableResult
    func start(nodeID: Int) -> Bool {
        guard let placement = placements.first(where: { $0.nodeID == nodeID }) else { return false }
        embed(placement)
        return true
    }

    func detachAll() {
        for id in Array(controllers.keys) { detach(id) }
    }

    private func embed(_ placement: BrowserInlineVideoPlacement) {
        guard controllers[placement.nodeID] == nil, let owner else { return }
        let controller = AVPlayerViewController()
        controller.view.frame = placement.rect
        controller.view.backgroundColor = UIColor(DSColor.background)
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        owner.addChild(controller)
        owner.view.addSubview(controller.view)
        controller.didMove(toParent: owner)
        controllers[placement.nodeID] = controller
        let startsFresh = !isActive(placement.media)
        let provider = playerProvider
        bindingTasks[placement.nodeID] = Task { @MainActor [weak self, weak controller] in
            let player = await provider(placement.media)
            guard !Task.isCancelled, let self, let controller,
                  controllers[placement.nodeID] === controller else { return }
            bindingTasks[placement.nodeID] = nil
            guard let player else { detach(placement.nodeID); return }
            controller.player = player
            if startsFresh { player.play() }
        }
    }

    private func detach(_ id: Int) {
        bindingTasks.removeValue(forKey: id)?.cancel()
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        controller.player = nil
    }
}
