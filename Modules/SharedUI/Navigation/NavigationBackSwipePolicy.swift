import CoreGraphics

/// Shared by native navigation and the bookshelf's custom book transition.
/// UIKit still detects an actual edge gesture; this is its defensive start limit.
enum NavigationBackSwipePolicy {
    static let reservedWidth: CGFloat = 30

    static func contains(initialX: CGFloat, containerWidth: CGFloat) -> Bool {
        containerWidth > 0 && initialX >= 0 && initialX <= reservedWidth
    }

    static func shouldBegin(initialX: CGFloat, translation: CGPoint, containerWidth: CGFloat) -> Bool {
        guard contains(initialX: initialX, containerWidth: containerWidth) else { return false }
        // The system edge recognizer can ask before accumulating translation.
        if translation == .zero { return true }
        return translation.x > 0 && abs(translation.x) >= abs(translation.y)
    }
}
