import re

file_path = "yuedu app/Views/ReaderView.swift"
with open(file_path, "r") as f:
    content = f.read()

# Make sure we only replace in the right block. This script will do a targeted string replace.

old_block = """        // MARK: - Cover pan gesture

        @objc func handleCoverPan(_ gesture: UIPanGestureRecognizer) {"""

new_block = """        // MARK: - Cover pan gesture
        
        private enum GestureConstants {
            /// The minimum horizontal translation (in points) required to trigger the cover animation.
            static let initialTranslationThreshold: CGFloat = 18.0
            /// The threshold ratio (0.0 to 1.0) of the screen width that must be crossed to commit the page turn.
            static let commitProgressRatio: CGFloat = 0.34
            /// The minimum flick velocity (in points per second) to commit the page turn even if the progress ratio is not reached.
            static let commitVelocityThreshold: CGFloat = 560.0
            /// The duration (in seconds) of the settling animation when the user releases their finger.
            static let settleAnimationDuration: TimeInterval = 0.22
            /// The maximum alpha value for the dimming overlay during the cover animation.
            static let maxDimmingAlpha: CGFloat = 0.35
        }

        @objc func handleCoverPan(_ gesture: UIPanGestureRecognizer) {"""

content = content.replace(old_block, new_block)

old_changed_block = """            case .changed:
                if coverTargetPage == nil {
                    if translationX < -18, currentPage < currentEngine.totalPages - 1 {
                        // Forward uncover：當前頁往左滑走，新頁在底下
                        coverDirection = 1
                        let target = currentPage + 1"""

new_changed_block = """            case .changed:
                if coverTargetPage == nil {
                    if translationX < -GestureConstants.initialTranslationThreshold, currentPage < currentEngine.totalPages - 1 {
                        // Forward uncover：當前頁往左滑走，新頁在底下
                        coverDirection = 1
                        let target = currentPage + 1"""

content = content.replace(old_changed_block, new_changed_block)

old_backward_block = """                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, in: view)
                    } else if translationX > 18, currentPage > 0 {
                        // Backward cover：上一頁從左側蓋入"""

new_backward_block = """                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, in: view)
                    } else if translationX > GestureConstants.initialTranslationThreshold, currentPage > 0 {
                        // Backward cover：上一頁從左側蓋入"""

content = content.replace(old_backward_block, new_backward_block)

old_dimming_1 = """                if coverDirection == -1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = rawProgress * 0.35
                } else if coverDirection == 1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = (1 - rawProgress) * 0.35
                }"""

new_dimming_1 = """                if coverDirection == -1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = rawProgress * GestureConstants.maxDimmingAlpha
                } else if coverDirection == 1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = (1 - rawProgress) * GestureConstants.maxDimmingAlpha
                }"""

content = content.replace(old_dimming_1, new_dimming_1)

old_ended_block = """            case .ended, .cancelled, .failed:
                guard let targetPage = coverTargetPage else {
                    resetCoverOverlay()
                    return
                }
                let progress = min(max(abs(translationX) / width, 0), 1)
                let shouldCommit = progress > 0.34 || abs(velocityX) > 560

                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {"""

new_ended_block = """            case .ended, .cancelled, .failed:
                guard let targetPage = coverTargetPage else {
                    resetCoverOverlay()
                    return
                }
                let progress = min(max(abs(translationX) / width, 0), 1)
                let shouldCommit = progress > GestureConstants.commitProgressRatio || abs(velocityX) > GestureConstants.commitVelocityThreshold

                UIView.animate(withDuration: GestureConstants.settleAnimationDuration, delay: 0, options: [.curveEaseOut]) {"""

content = content.replace(old_ended_block, new_ended_block)

old_dimming_2 = """                    if self.coverDirection == -1 {
                        self.coverDimView.alpha = shouldCommit ? 0.35 : 0
                    } else if self.coverDirection == 1 {
                        self.coverDimView.alpha = shouldCommit ? 0 : 0.35
                    }"""

new_dimming_2 = """                    if self.coverDirection == -1 {
                        self.coverDimView.alpha = shouldCommit ? GestureConstants.maxDimmingAlpha : 0
                    } else if self.coverDirection == 1 {
                        self.coverDimView.alpha = shouldCommit ? 0 : GestureConstants.maxDimmingAlpha
                    }"""

content = content.replace(old_dimming_2, new_dimming_2)

with open(file_path, "w") as f:
    f.write(content)

print("Replaced magic numbers successfully.")
