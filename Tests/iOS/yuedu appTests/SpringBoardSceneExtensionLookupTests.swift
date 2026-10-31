import Foundation
import ObjectiveC
import Testing
@testable import yuedu_app

/// The getClass hook answers only UIKit's two SpringBoard names, and passes every other name
/// on to the Swift runtime.
@Suite("SpringBoard scene extension lookup")
struct SpringBoardSceneExtensionLookupTests {
    @Test("the two SpringBoard extension names are answered as absent")
    func springBoardNamesAreAbsent() {
        for absent in SpringBoardSceneExtensionLookup.absentClasses {
            // The premise: an app process does not load the framework that defines it.
            #expect(!SpringBoardSceneExtensionLookup.frameworkIsLoaded(absent.framework))
            let name = UnsafeRawPointer(absent.name.utf8Start).assumingMemoryBound(to: CChar.self)
            let (answered, found) = lookUp(name)
            #expect(!answered)
            #expect(found == nil)
        }
    }

    @Test("any other name goes on to the Swift runtime")
    func otherNamesReachSwiftRuntime() {
        // The mangled name Objective-C would ask with; the Swift runtime's hook resolves it.
        let (answered, found) = lookUp(class_getName(RSSAppNotificationDelegate.self))
        #expect(answered)
        #expect(found.map(ObjectIdentifier.init) == ObjectIdentifier(RSSAppNotificationDelegate.self))
    }

    @Test("the app installs the hook at launch, and lookups by name still resolve")
    func installedAtLaunch() {
        #expect(SpringBoardSceneExtensionLookup.isInstalled)
        for absent in SpringBoardSceneExtensionLookup.absentClasses {
            #expect(NSClassFromString(absent.name.description) == nil)
        }
        #expect(NSClassFromString("yuedu_app.RSSAppNotificationDelegate").map(ObjectIdentifier.init)
            == ObjectIdentifier(RSSAppNotificationDelegate.self))
    }

    @Test("a framework the app loads is seen as loaded")
    func loadedFrameworkIsSeen() {
        #expect(SpringBoardSceneExtensionLookup.frameworkIsLoaded("Foundation"))
    }

    /// Calls the hook the way Objective-C does. The out-pointer is allocated by hand: passing
    /// `&` of an `AnyClass?` as an autoreleasing pointer crashes the Swift 6 compiler in
    /// AllocStackHoisting (Xcode 27, 2026-10-31).
    private func lookUp(_ name: UnsafePointer<CChar>) -> (answered: Bool, found: AnyClass?) {
        let found = UnsafeMutablePointer<AnyClass?>.allocate(capacity: 1)
        found.initialize(to: nil)
        defer { found.deallocate() }
        let answered = springBoardSceneExtensionGetClassHook(name, AutoreleasingUnsafeMutablePointer(found)).boolValue
        return (answered, found.pointee)
    }
}
