import Foundation
import os

/// The settings that code off the main thread reads: chapter building (comment bubbles, the
/// reader font), page prerendering (the text underline), search, and network TTS.
/// `GlobalSettings` is main-actor state the UI mutates; these readers get a copy instead,
/// replaced whenever one of its fields changes.
///
/// Read it once per operation (`let settings = GlobalSettings.snapshot`) so one bubble's cache
/// key and image, or one TTS request's template and headers, come from the same settings.
///
/// A SwiftUI view that draws through these readers does not observe the snapshot; it must read
/// the `GlobalSettings` properties it depends on itself.
struct GlobalSettingsSnapshot: Sendable, Equatable {
    var commentBubbleFollowsSourceSVG: Bool
    var commentBubblePresetMode: ReaderCommentBubblePresetMode
    var commentBubbleSelectedCustomStyleID: UUID?
    /// The selected style itself, not only its ID: editing a style in place keeps the ID and
    /// changes the SVG, and the bubble image cache keys on that.
    var commentBubbleSelectedCustomStyle: ReaderCommentBubbleCustomStyle?
    var commentBubbleScale: Double
    var selectedReaderFontPostScript: String?

    var readerTextUnderlineDecorationEnabled: Bool
    var readerTextUnderlineDecorationColorHex: UInt32
    var readerTextUnderlineThickness: Double
    var readerTextUnderlineOffset: Double
    var readerTextUnderlineStyle: ReaderTextUnderlineStyle

    var searchCacheDays: Int

    var httpTtsUrlTemplate: String
    var httpTtsHeaders: [String: String]
    var activeTTSSource: ImportedTTSSource?
}

extension GlobalSettings {
    /// Published by `GlobalSettings.init` and by every change to a field it mirrors.
    private nonisolated static let published = OSAllocatedUnfairLock<GlobalSettingsSnapshot?>(initialState: nil)

    /// The settings as last written, for readers off the main thread.
    nonisolated static var snapshot: GlobalSettingsSnapshot {
        guard let snapshot = published.withLock({ $0 }) else {
            // `GlobalSettings.shared` is created on main in `yuedu_appApp.init`, which also runs
            // before hosted unit tests; every reader comes after it.
            preconditionFailure("GlobalSettings.snapshot read before GlobalSettings.shared was created")
        }
        return snapshot
    }

    /// Call from the `didSet` of every property `GlobalSettingsSnapshot` mirrors, and at the
    /// end of `init` (which runs no `didSet`).
    func publishSnapshot() {
        let snapshot = GlobalSettingsSnapshot(
            commentBubbleFollowsSourceSVG: commentBubbleFollowsSourceSVG,
            commentBubblePresetMode: commentBubblePresetMode,
            commentBubbleSelectedCustomStyleID: commentBubbleSelectedCustomStyleID,
            commentBubbleSelectedCustomStyle: commentBubbleSelectedCustomStyle,
            commentBubbleScale: commentBubbleScale,
            selectedReaderFontPostScript: selectedReaderFontPostScript,
            readerTextUnderlineDecorationEnabled: readerTextUnderlineDecorationEnabled,
            readerTextUnderlineDecorationColorHex: readerTextUnderlineDecorationColorHex,
            readerTextUnderlineThickness: readerTextUnderlineThickness,
            readerTextUnderlineOffset: readerTextUnderlineOffset,
            readerTextUnderlineStyle: readerTextUnderlineStyle,
            searchCacheDays: searchCacheDays,
            httpTtsUrlTemplate: httpTtsUrlTemplate,
            httpTtsHeaders: httpTtsHeaders,
            activeTTSSource: activeTTSSource
        )
        Self.published.withLock { $0 = snapshot }
    }
}
