import Testing
@testable import yuedu_app

/// Feedback #15: with the reading menu open, a page coming on screen took VoiceOver back off the
/// menu, so the bottom bar was never reached. `ReaderPageVoiceOverFocus.movesFocus` decides when a
/// page that appears moves VoiceOver to itself.
struct ReaderPageVoiceOverFocusTests {
    private typealias Page = ReaderPageVoiceOverFocus.Page
    private let first = CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
    private let second = CoreTextReadingPosition(spineIndex: 0, charOffset: 429)

    private func page(_ position: CoreTextReadingPosition?, placeholder: Bool = false) -> Page {
        Page(position: position, isPlaceholder: placeholder)
    }

    @Test func userPageTurnMovesFocusToTheNewPage() {
        #expect(ReaderPageVoiceOverFocus.movesFocus(
            to: page(second), from: page(first), voiceOverRunning: true, pageIsCovered: false
        ))
    }

    @Test func firstPageTakesFocus() {
        #expect(ReaderPageVoiceOverFocus.movesFocus(
            to: page(first), from: nil, voiceOverRunning: true, pageIsCovered: false
        ))
    }

    /// The report: the menu is open and a page appears — a chapter arriving, or a turn from the
    /// menu's own 下一章. VoiceOver stays on the menu.
    @Test func noPageTakesFocusWhileTheMenuCoversIt() {
        for (appeared, focused) in [(page(second), page(first)), (page(first), nil),
                                    (page(first), page(first, placeholder: true))] {
            #expect(!ReaderPageVoiceOverFocus.movesFocus(
                to: appeared, from: focused, voiceOverRunning: true, pageIsCovered: true
            ))
        }
    }

    /// A chapter arriving or a relayout puts the page being read back on screen: not a turn.
    @Test func samePagePlacedAgainKeepsFocus() {
        #expect(!ReaderPageVoiceOverFocus.movesFocus(
            to: page(first), from: page(first), voiceOverRunning: true, pageIsCovered: false
        ))
        #expect(!ReaderPageVoiceOverFocus.movesFocus(
            to: page(first, placeholder: true), from: page(first, placeholder: true),
            voiceOverRunning: true, pageIsCovered: false
        ))
    }

    /// The text replacing the 載入中 placeholder VoiceOver was on: focus moves to the text rather
    /// than staying on a view that has left the screen.
    @Test func textReplacingThePlaceholderTakesFocus() {
        #expect(ReaderPageVoiceOverFocus.movesFocus(
            to: page(first), from: page(first, placeholder: true), voiceOverRunning: true, pageIsCovered: false
        ))
    }

    @Test func nothingMovesWithoutVoiceOver() {
        #expect(!ReaderPageVoiceOverFocus.movesFocus(
            to: page(second), from: page(first), voiceOverRunning: false, pageIsCovered: false
        ))
    }
}
