import Foundation
import Testing
@testable import yuedu_app

/// The 模組 page's 首頁欄目引用 (M6): the home sections whose module is no longer installed, in
/// every 首頁配置, and their removal.
@MainActor
@Suite("Home sections of uninstalled modules")
struct HomeModuleReferencesTests {
    private func section(_ title: String, module: String) -> HomeSection {
        HomeSection(layout: .row, title: title, binding: .module(moduleID: module, entryID: "new"))
    }

    @Test("sections bound to a module that is not installed, in every configuration")
    func references() {
        let kept = section("留下", module: "a.one")
        let gone = section("不見了", module: "gone.module")
        let elsewhere = section("別的配置", module: "gone.module")
        let mine = HomeConfigurationID(rawValue: "mine")
        var home = HomeConfigurations(sections: [kept, gone, HomeSection(layout: .row, binding: .related)],
                                      configurations: [HomeConfiguration(id: mine, name: "我的", sections: [elsewhere])])

        let references = home.moduleReferences(installed: ["a.one"])
        #expect(references.map(\.section.title) == ["不見了", "別的配置"])
        #expect(references.map(\.configuration.name) == [localized("預設"), "我的"])
        #expect(references.allSatisfy { $0.moduleID == "gone.module" })

        home.removeSections(Set(references.map(\.id)))
        #expect(home.moduleReferences(installed: ["a.one"]).isEmpty)
        #expect(home.sections(of: .defaults).map(\.title) == ["留下", ""])
        #expect(home.sections(of: mine).isEmpty)
    }

    @Test("the store removes them for good")
    func store() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeReferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("explore_home.json")
        let gone = section("不見了", module: "gone.module")
        let store = HomePageStore(fileURL: file)
        store.save(HomePage(sections: [section("留下", module: "a.one"), gone]))

        store.removeSections([gone.id])
        store.waitForPendingWritesForTesting()

        #expect(HomePageStore(fileURL: file).page?.sections.map(\.title) == ["留下"])
    }
}
