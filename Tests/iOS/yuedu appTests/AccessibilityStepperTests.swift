import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The elements VoiceOver reads as one stepper named `title` alone.
@MainActor
private func steppers(named title: String, in host: UIView) -> [NSObject] {
    accessibilityElements(in: host).filter {
        $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.adjustable)
    }
}

/// What VoiceOver read near `title`, for a failure message.
@MainActor
private func readings(around title: String, in host: UIView) -> [String] {
    accessibilityElements(in: host)
        .filter { ($0.accessibilityLabel ?? "").contains(title) }
        .map { "\($0.accessibilityLabel ?? "") | \($0.accessibilityValue ?? "")" }
}

/// `View.accessibilityStepper`: a stepping row, read as one adjustable element named and
/// valued apart.
///
/// A Stepper reads everything in its label into the name of both its buttons, and adds an
/// `.accessibilityLabel` to that rather than replacing it: 「字重、400, 增量」 and then 400 again
/// as the value.
@Suite("Accessibility stepper", .serialized)
@MainActor
struct AccessibilityStepperTests {
    @MainActor @Observable
    final class Weight {
        var value = 400
        var editsEnded = 0
        var increments = 0
        var decrements = 0
    }

    private struct Row: View {
        let weight: Weight

        var body: some View {
            let binding = Binding(get: { weight.value }, set: { weight.value = $0 })
            List {
                Stepper(value: binding, in: 100...900, step: 100) {
                    ThemedLabeledContent(localized("字重"), value: "\(weight.value)")
                }
                .accessibilityStepper(
                    localized("字重"), value: binding, in: 100...900, step: 100,
                    valueText: "\(weight.value)",
                    onEditingChanged: { if !$0 { weight.editsEnded += 1 } }
                )
            }
        }
    }

    private struct ClosureRow: View {
        let weight: Weight

        var body: some View {
            HStack {
                Button("−") {}
                Text("\(weight.value)")
                Button("+") {}
            }
            .accessibilityStepper(
                localized("字重"), valueText: "\(weight.value)",
                onIncrement: { weight.increments += 1 },
                onDecrement: { weight.decrements += 1 }
            )
        }
    }

    @Test("the row is one adjustable element, named alone, valued once")
    func readsNameAndValueOnce() async throws {
        try await withAccessibilityHost(in: Row(weight: Weight())) { host in
            #expect(await eventually(host) { !accessibilityElements(in: host).isEmpty })
            let elements = accessibilityElements(in: host)
            #expect(elements.count == 1, "read: \(readings(around: localized("字重"), in: host))")
            #expect(elements.first?.accessibilityLabel == localized("字重"))
            #expect(elements.first?.accessibilityValue == "400")
            #expect(elements.first?.accessibilityTraits.contains(.adjustable) == true)
        }
    }

    @Test("a swipe moves a step, ends one edit, and goes no further than the bound")
    func swipeStepsWithinTheBounds() async throws {
        let weight = Weight()
        weight.value = 800
        try await withAccessibilityHost(in: Row(weight: weight)) { host in
            var stepper: NSObject?
            #expect(await eventually(host) {
                stepper = steppers(named: localized("字重"), in: host).first
                return stepper != nil
            })
            stepper?.accessibilityIncrement()
            #expect(await eventually(host) { weight.value == 900 })
            #expect(weight.editsEnded == 1)
            stepper?.accessibilityIncrement()
            settle(host)
            #expect(weight.value == 900)
            stepper?.accessibilityDecrement()
            #expect(await eventually(host) { weight.value == 800 })
            #expect(await eventually(host) {
                steppers(named: localized("字重"), in: host).first?.accessibilityValue == "800"
            })
        }
    }

    @Test("a row that moves its own value hears each swipe")
    func closuresHearEachSwipe() async throws {
        let weight = Weight()
        try await withAccessibilityHost(in: ClosureRow(weight: weight)) { host in
            var stepper: NSObject?
            #expect(await eventually(host) {
                stepper = steppers(named: localized("字重"), in: host).first
                return stepper != nil
            })
            #expect(accessibilityElements(in: host).count == 1)
            stepper?.accessibilityIncrement()
            stepper?.accessibilityDecrement()
            stepper?.accessibilityDecrement()
            #expect(weight.increments == 1)
            #expect(weight.decrements == 2)
        }
    }
}

/// Each stepping row in the app, in its own screen, as VoiceOver reads it.
@Suite("Stepper rows read by VoiceOver", .serialized)
@MainActor
struct StepperRowVoiceOverTests {
    private func expectStepper(_ title: String, valued value: String? = nil,
                               in view: some View, height: CGFloat? = nil) async throws {
        try await withAccessibilityHost(in: view, height: height) { host in
            let found = await eventually(host, within: .seconds(3)) {
                !steppers(named: title, in: host).isEmpty
            }
            #expect(found, "read: \(readings(around: title, in: host))")
            if let value {
                for stepper in steppers(named: title, in: host) {
                    #expect(stepper.accessibilityValue == value)
                }
            }
        }
    }

    @Test("網路設定's three rows each say what they step")
    func networkSettingsRows() async throws {
        let settings = GlobalSettings.shared
        let view = NetworkSettingsView().environmentObject(BookStore())
        try await withAccessibilityHost(in: view) { host in
            let rows = [
                (localized("並發數"), settings.searchConcurrency),
                (localized("自動暫停"), settings.searchAutoPauseCount),
                (localized("搜索結果快取天數"), settings.searchCacheDays),
            ]
            for (title, value) in rows {
                let found = await eventually(host, within: .seconds(3)) {
                    !steppers(named: title, in: host).isEmpty
                }
                #expect(found, "\(title) read: \(readings(around: title, in: host))")
                #expect(steppers(named: title, in: host).first?.accessibilityValue == "\(value)")
            }
            // The description under each row is still read.
            #expect(accessibilityElements(in: host).contains {
                $0.accessibilityLabel == localized("搜索/缓存/下载/校验等网络请求并发数，建议16个")
            })
        }
    }

    @MainActor @Observable
    final class FontSize {
        var value: CGFloat = 18
    }

    private struct QuickPanel: View {
        let size: FontSize

        var body: some View {
            ReaderQuickThemePanelView(
                fontSize: Binding(get: { size.value }, set: { size.value = $0 }),
                readerTheme: .constant(.white),
                pageTurnOption: .curl,
                isVerticalWritingMode: false,
                onSelectPageTurnOption: { _ in },
                onStartAutoRead: {},
                onCustomize: {}
            )
        }
    }

    @Test("the quick panel reads 字體大小 and its size, and a swipe changes it")
    func quickPanelFontSize() async throws {
        let size = FontSize()
        try await withAccessibilityHost(in: QuickPanel(size: size)) { host in
            let title = localized("字體大小")
            var stepper: NSObject?
            let found = await eventually(host, within: .seconds(3)) {
                stepper = steppers(named: title, in: host).first
                return stepper != nil
            }
            #expect(found, "read: \(accessibilityElements(in: host).map { $0.accessibilityLabel ?? "" })")
            #expect(stepper?.accessibilityValue == String(format: localized("ReaderOverlay.Format.Points"), 18))
            stepper?.accessibilityIncrement()
            #expect(await eventually(host) { size.value == 19 })
            #expect(await eventually(host) {
                steppers(named: title, in: host).first?.accessibilityValue
                    == String(format: localized("ReaderOverlay.Format.Points"), 19)
            })
        }
    }

    @Test("the rule debugger's page is 頁碼")
    func debuggerPage() async throws {
        try await expectStepper(localized("頁碼"), valued: "1", in: BookSourceRuleDebugView(
            source: BookSource(bookSourceUrl: "https://example.com", bookSourceName: "示例來源"),
            initialTab: .search
        ))
    }

    @Test("對話氣泡's 氣泡字重 is read once")
    func dialogueBubbleWeight() async throws {
        try await expectStepper(localized("氣泡字重"), valued: "400", in: NavigationStack {
            ReaderDialogueBubbleSettingsView(style: ReaderDialogueBubbleStyle(isEnabled: true)) { _ in }
        }, height: 6000)
    }

    @Test("the highlight rule editor's 字重 is read once")
    func highlightRuleWeight() async throws {
        try await expectStepper(localized("字重"), valued: "400", in: NavigationStack {
            RegexHighlightRuleEditorView(rule: .custom(name: "Preview", pattern: "Sample")) { _ in }
        }, height: 6000)
    }

    @Test("the chapter title inspector's 字重 is read once")
    func chapterTitleWeight() async throws {
        let model = ChapterTitleDesignerModel(initial: .default, onSave: { _ in })
        model.selectedLayerID = model.draft.layers.first?.id
        try await expectStepper(localized("字重"), in: ChapterTitleInspectorView(model: model), height: 6000)
    }

    @MainActor @Observable
    final class Chapter {
        var index = 2
    }

    private struct ChapterRow: View {
        let chapter: Chapter

        var body: some View {
            List {
                AIMemoryViewChapterStepper(
                    chapter: Binding(get: { chapter.index }, set: { chapter.index = $0 }),
                    lastChapter: 10
                )
            }
        }
    }

    @Test("人物記憶's chapter is read as the chapter it shows, not the one before it")
    func aiMemoryChapter() async throws {
        let chapter = Chapter()
        try await withAccessibilityHost(in: ChapterRow(chapter: chapter)) { host in
            let title = localized("章節進度")
            var stepper: NSObject?
            let found = await eventually(host, within: .seconds(3)) {
                stepper = steppers(named: title, in: host).first
                return stepper != nil
            }
            #expect(found, "read: \(accessibilityElements(in: host).map { "\($0.accessibilityLabel ?? "") | \($0.accessibilityValue ?? "")" })")
            #expect(stepper?.accessibilityValue == String(format: localized("第 %d 章"), 3))
            stepper?.accessibilityIncrement()
            #expect(await eventually(host) { chapter.index == 3 })
        }
    }
}
