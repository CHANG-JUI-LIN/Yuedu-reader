import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver's rotor offers on a shelf book: 作品詳情, 置頂, 編輯書籍資訊 and 刪除書籍, once
/// each, in the list and in the grid (FB-196).
///
/// The rotor is not the element's `accessibilityCustomActions`. With the app's accessibility
/// runtime loaded, as it is under VoiceOver, UIKit adds a `List` row's swipe actions to the
/// row's own, and on iOS 27 SwiftUI has added them to the element already, so a row with a swipe
/// is read with each swipe button once before iOS 27 and twice on it, whatever the row declares.
/// Reading only the element's own actions is how a4df38b6 passed while the reporter still heard
/// two 置頂 and two 刪除. This reads `_accessibilityCustomActions`, the runtime's assembled list,
/// with VoiceOver turned on for the test, and runs on both sides of iOS 27.
@Suite("Bookshelf rows: VoiceOver actions", .serialized)
@MainActor
struct BookshelfRowVoiceOverActionsTests {
    private static let title = "轉子動作測試書"

    @Test func voiceOverHearsEachListActionOnce() async throws {
        let offered = try await rotorActions(grid: false, voiceOver: true)
        expectEachActionOnce(offered)
    }

    @Test func voiceOverHearsEachGridActionOnce() async throws {
        let offered = try await rotorActions(grid: true, voiceOver: true)
        expectEachActionOnce(offered)
    }

    /// Without VoiceOver or Switch Control the list keeps its 左滑, and the row leaves 置頂 and
    /// the delete to it.
    @Test func theListKeepsItsSwipeWithoutVoiceOver() async throws {
        let offered = try await rotorActions(grid: false, voiceOver: false)
        #expect(offered.contains(localized("刪除")), "\(offered)")
        #expect(offered.contains(BookshelfPinLabel.title(isPinned: false)), "\(offered)")
        #expect(!offered.contains(localized("刪除書籍")), "\(offered)")
    }

    private func expectEachActionOnce(_ offered: [String]) {
        for name in [
            localized("作品詳情"),
            BookshelfPinLabel.title(isPinned: false),
            localized("編輯書籍資訊"),
            localized("刪除書籍"),
        ] {
            #expect(offered.filter { $0 == name }.count == 1, "\(name): \(offered)")
        }
        #expect(!offered.contains(localized("刪除")), "\(offered)")
        #expect(offered.count == 4, "\(offered)")
    }

    /// The actions VoiceOver would list on the test book, with the shelf laid out as asked.
    private func rotorActions(grid: Bool, voiceOver: Bool) async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfRowVoiceOver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var book = ReadingBook(title: Self.title, author: "作者", contentFilename: "")
        book.isOnline = true
        store.replaceBooksFromSync([book])
        store.waitForQueuedWrites()

        let defaults = UserDefaults.standard
        let previousGrid = defaults.object(forKey: "bookLayoutIsGrid")
        defaults.set(grid, forKey: "bookLayoutIsGrid")

        let runtime = try AccessibilityRuntime()
        runtime.enable(voiceOver: voiceOver)
        defer {
            runtime.restore()
            defaults.set(previousGrid, forKey: "bookLayoutIsGrid")
            store.waitForQueuedWrites()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("the test's shelf was not removed: \(error)")
            }
        }
        // SwiftUI's `accessibilityVoiceOverEnabled` follows VoiceOver's switch on a notification,
        // after UIKit's own flag: wait until a view reads the state the shelf is to see.
        let probe = VoiceOverStateProbe.Reading()
        let probeHost = try WindowHost(VoiceOverStateProbe(reading: probe))
        let ready = ContinuousClock.now + .seconds(5)
        while probe.voiceOverEnabled != voiceOver, ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        probeHost.tearDown()
        try #require(probe.voiceOverEnabled == voiceOver, "SwiftUI never saw VoiceOver turn \(voiceOver ? "on" : "off")")

        let host = try WindowHost(HomeView().environmentObject(store))
        defer { host.tearDown() }

        func elements(in object: NSObject) -> [NSObject] {
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject] { return children.flatMap(elements(in:)) }
            return (object as? UIView)?.subviews.flatMap(elements(in:)) ?? []
        }
        func row() -> NSObject? {
            elements(in: host.window).first { ($0.accessibilityLabel ?? "").hasPrefix(Self.title) }
        }
        // The runtime loads on its own after application accessibility is switched on, the
        // first time in a process: wait for the row and for the runtime's reading of it.
        let assembled = NSSelectorFromString("_accessibilityCustomActions")
        let deadline = ContinuousClock.now + .seconds(10)
        while row()?.responds(to: assembled) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstRow = try #require(row(), "the book never reached the accessibility tree")
        try #require(firstRow.responds(to: assembled), "the accessibility runtime never loaded")
        // The runtime adds the cell's swipe actions once the list has configured the cell, not
        // when the row's element first appears: read after the list has settled, or a row that
        // still has its swipe can pass with the swipe's copies missing.
        host.pump(seconds: 0.5)
        let bookRow = try #require(row(), "the book left the accessibility tree")
        let actions = bookRow.perform(assembled)?.takeUnretainedValue() as? [UIAccessibilityCustomAction]
        return (actions ?? []).map(\.name)
    }
}

/// Reports the VoiceOver state SwiftUI hands its views.
private struct VoiceOverStateProbe: View {
    @MainActor final class Reading { var voiceOverEnabled: Bool? }
    let reading: Reading
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Text(verbatim: "probe")
            .onAppear { reading.voiceOverEnabled = voiceOverEnabled }
            .onChange(of: voiceOverEnabled) { _, enabled in reading.voiceOverEnabled = enabled }
    }
}

/// libAccessibility's switches, as VoiceOver and XCUITest flip them: automation makes SwiftUI
/// build its accessibility elements, application accessibility loads the runtime that assembles
/// what VoiceOver reads, and VoiceOver's own switch is what `accessibilityVoiceOverEnabled` reports.
@MainActor
private final class AccessibilityRuntime {
    private typealias GetFlag = @convention(c) () -> Bool
    private typealias SetFlag = @convention(c) (Bool) -> Void

    private let switches: [(get: GetFlag, set: SetFlag)]
    private var previous: [Bool] = []

    init() throws {
        let library = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        func flag(_ getter: String, _ setter: String) throws -> (get: GetFlag, set: SetFlag) {
            (
                unsafeBitCast(try #require(dlsym(library, getter)), to: GetFlag.self),
                unsafeBitCast(try #require(dlsym(library, setter)), to: SetFlag.self)
            )
        }
        switches = [
            try flag("_AXSAutomationEnabled", "_AXSSetAutomationEnabled"),
            try flag("_AXSApplicationAccessibilityEnabled", "_AXSApplicationAccessibilitySetEnabled"),
            try flag("_AXSVoiceOverTouchEnabled", "_AXSVoiceOverTouchSetEnabled"),
        ]
    }

    func enable(voiceOver: Bool) {
        previous = switches.map { $0.get() }
        switches[0].set(true)
        switches[1].set(true)
        switches[2].set(voiceOver)
    }

    func restore() {
        for (flag, value) in zip(switches, previous) { flag.set(value) }
    }
}
