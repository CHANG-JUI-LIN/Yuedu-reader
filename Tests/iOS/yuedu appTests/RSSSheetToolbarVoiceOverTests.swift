import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver reads for the ✕ and ✓ in the toolbars of the RSS sheets. Each was a bare
/// `Image(systemName:)`, so VoiceOver read the symbol, not what the button does. XCUITest lists
/// elements VoiceOver never reaches, so this reads the window's own accessibility elements.
@Suite("RSS sheet toolbar VoiceOver labels", .serialized)
@MainActor
struct RSSSheetToolbarVoiceOverTests {
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// The buttons VoiceOver finds outside the navigation stack's page — the bars' — in reading
    /// order. Where the bars sit varies: on iOS 17 the items are in `UINavigationBar`; from iOS 26
    /// in a floating bar beside it, which runs down the side on iPhone Duo. The bars are UIKit's
    /// and join the tree after the sheet's SwiftUI content, so this waits for the buttons themselves.
    private func barButtons(in window: UIWindow, count: Int) async throws -> [NSObject] {
        func navigationController(in controller: UIViewController) -> UINavigationController? {
            controller as? UINavigationController ?? controller.children.lazy.compactMap(navigationController(in:)).first
        }
        func buttons(in object: NSObject, outside page: UIView) -> [NSObject] {
            if object === page { return [] }
            if object.isAccessibilityElement {
                return object.accessibilityTraits.contains(.button) ? [object] : []
            }
            if let children = object.accessibilityElements as? [NSObject] {
                return children.flatMap { buttons(in: $0, outside: page) }
            }
            return (object as? UIView)?.subviews.flatMap { buttons(in: $0, outside: page) } ?? []
        }
        func found() -> [NSObject] {
            guard let root = window.rootViewController,
                  let page = navigationController(in: root)?.topViewController?.viewIfLoaded else { return [] }
            return buttons(in: window, outside: page)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var result = found()
        while result.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            result = found()
        }
        return result
    }

    private func spokenBarButtons(of view: some View, expected: [String]) async throws {
        try await withAutomation {
            let window = try host(view)
            defer { window.isHidden = true; window.rootViewController = nil }
            let buttons = try await barButtons(in: window, count: expected.count)
            expectSpoken(buttons, expected)
        }
    }

    /// The names, and no selected state: the bare ✓ symbol carried one, so VoiceOver read
    /// "Selected" for it, and would go on reading it beside a name.
    private func expectSpoken(_ buttons: [NSObject], _ expected: [String]) {
        #expect(buttons.map { $0.accessibilityLabel ?? "" } == expected)
        #expect(buttons.filter { $0.accessibilityTraits.contains(.selected) }.map(\.accessibilityLabel) == [])
    }

    /// SwiftUI builds no accessibility elements until something reads them — VoiceOver, or
    /// XCUITest's automation. Turned on here as XCUITest does it, and back off after.
    private func withAutomation(_ body: () async throws -> Void) async throws {
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)
        defer { setAutomationEnabled(wasEnabled) }
        try await body()
    }

    private func withStore(_ body: (RSSStore) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(RSSStore(storageDirectory: folder))
    }

    @Test("匯入 OPML: close")
    func opmlImport() async throws {
        try await spokenBarButtons(
            of: RSSOPMLImportSheet(isPresented: .constant(true), onFileCompletion: { _ in }, onDataImport: { _ in }),
            expected: [localized("關閉")]
        )
    }

    @Test("從網址匯入 Legado JSON: cancel, import")
    func legadoJSONImport() async throws {
        try await withStore { store in
            try await spokenBarButtons(
                of: ImportLegadoJSONURLSheet(isPresented: .constant(true), store: store),
                expected: [localized("取消"), localized("匯入")]
            )
        }
    }

    @Test("新增 RSS 訂閱: cancel, add")
    func addSource() async throws {
        try await withStore { store in
            try await spokenBarButtons(
                of: AddRSSSourceSheet(isPresented: .constant(true), store: store, gs: GlobalSettings.shared, folders: []),
                expected: [localized("取消"), localized("動作：新增")]
            )
        }
    }

    @Test("新增資料夾: cancel, add")
    func addFolder() async throws {
        try await withStore { store in
            try await spokenBarButtons(
                of: AddRSSFolderSheet(isPresented: .constant(true), store: store),
                expected: [localized("取消"), localized("動作：新增")]
            )
        }
    }

    @Test("重新命名: cancel, save")
    func renameFolder() async throws {
        try await withStore { store in
            try await spokenBarButtons(
                of: RenameRSSFolderSheet(folder: RSSFolder(name: "科技"), store: store),
                expected: [localized("取消"), localized("儲存")]
            )
        }
    }

    @Test("編輯訂閱: cancel, save")
    func editSource() async throws {
        try await withStore { store in
            try await spokenBarButtons(
                of: EditRSSSourceSheet(source: RSSSource(name: "Example", url: "https://example.com/feed.xml"), store: store),
                expected: [localized("取消"), localized("儲存")]
            )
        }
    }

    /// The leading button turns reordering on and off. Off it reads 編輯; on, 退出編輯 — not
    /// 完成, which is already the trailing button that closes the sheet.
    @Test("整理訂閱: edit or exit editing, done")
    func organize() async throws {
        try await withStore { store in
            try await withAutomation {
                let window = try host(RSSOrganizeSheet(store: store))
                defer { window.isHidden = true; window.rootViewController = nil }
                let idle = try await barButtons(in: window, count: 2)
                expectSpoken(idle, [localized("編輯"), localized("完成")])

                // VoiceOver presses with accessibilityActivate(); a UIKit bar button declines it,
                // and VoiceOver then taps the button instead.
                let toggle = try #require(idle.first)
                if !toggle.accessibilityActivate() {
                    try #require(toggle as? UIControl).sendActions(for: .touchUpInside)
                }
                let exitLabel = localized("退出編輯")
                let deadline = ContinuousClock.now + .seconds(5)
                var editing = try await barButtons(in: window, count: 2)
                while editing.first?.accessibilityLabel != exitLabel, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    editing = try await barButtons(in: window, count: 2)
                }
                expectSpoken(editing, [exitLabel, localized("完成")])
            }
        }
    }
}
