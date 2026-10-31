import Darwin
import MachO
import ObjectiveC

/// Answers "no such class" at once for the two SpringBoard scene extensions UIKit asks every
/// app for by Swift name, instead of letting the Swift runtime search for them.
///
/// Every scene-settings update (each move to inactive, to the background and back) has
/// FrontBoardServices list its scene extensions by `NSClassFromString` on about 33
/// SpringBoard class names, uncached: `-[FBSSettings _allSceneExtensions]`, reached from
/// `_UIKeyboardInputSceneClientComponent` through `ui_safeAreaSettings`. Two of the names are
/// Swift names (`Module.Class`). Objective-C cannot find them and asks the Swift runtime's
/// getClass hook, which finds no such type and then searches every protocol conformance
/// record of every loaded image (this app alone has about 9,100). It does not remember the
/// miss. That is two full searches per update, on the main thread: 200–850 ms together
/// (median about 540) when the app has sat idle for two minutes first, 5–10 ms when it has
/// not. Measured with Time Profiler on the iOS 27.0 simulator, Release build, 2026-10-31
/// (Crashlytics 6f607251, `phase background`). Only iOS 27 has these two classes; the iOS
/// 17.5, 18.6 and 26 simulator runtimes do not.
///
/// ShellSceneKit and AppRestrictionsCore, the frameworks that define the two classes, are
/// not loaded in an app process, so "not found" is the answer the search would have reached.
/// If one of them is loaded, its name goes on to the real lookup, which finds the type.
///
/// Delete this once FrontBoardServices stops asking app processes for these names, or once
/// the Swift runtime caches failed lookups. To check, profile a trip to the background and
/// look for `_searchConformancesByMangledTypeName` under `_allSceneExtensions`.
enum SpringBoardSceneExtensionLookup {
    /// Each class name as UIKit asks for it, with the framework that defines it.
    nonisolated static let absentClasses: [(name: StaticString, framework: StaticString)] = [
        ("ShellSceneKit.DisplayTraitsSceneExtension", "ShellSceneKit"),
        ("AppRestrictionsCore.SceneHostedPreflightSceneExtension", "AppRestrictionsCore"),
    ]

    /// Once, at launch. Hooks run newest first, so this one answers before the Swift
    /// runtime's, which it calls for every other name.
    static func install() {
        objc_setHook_getClass(springBoardSceneExtensionGetClassHook, &previousGetClassHook)
    }

    /// Whether `install()` has run: the hook it replaced is kept for every other name.
    static var isInstalled: Bool { previousGetClassHook != nil }

    /// Whether an image of `framework` (`…/<framework>.framework/<framework>`) is loaded.
    nonisolated static func frameworkIsLoaded(_ framework: StaticString) -> Bool {
        "/\(framework).framework/\(framework)".withCString { suffix in
            let suffixLength = strlen(suffix)
            for index in 0..<_dyld_image_count() {
                guard let path = _dyld_get_image_name(index) else { continue }
                let length = strlen(path)
                if length >= suffixLength, strcmp(path + (length - suffixLength), suffix) == 0 { return true }
            }
            return false
        }
    }
}

/// The hook installed before this one: the Swift runtime's.
nonisolated(unsafe) private var previousGetClassHook: objc_hook_getClass?

/// Objective-C calls this only for a name it could not find itself, on any thread.
nonisolated func springBoardSceneExtensionGetClassHook(
    _ name: UnsafePointer<CChar>,
    _ outClass: AutoreleasingUnsafeMutablePointer<AnyClass?>
) -> ObjCBool {
    for absent in SpringBoardSceneExtensionLookup.absentClasses
    where strcmp(name, UnsafeRawPointer(absent.name.utf8Start).assumingMemoryBound(to: CChar.self)) == 0 {
        if !SpringBoardSceneExtensionLookup.frameworkIsLoaded(absent.framework) { return false }
    }
    return previousGetClassHook?(name, outClass) ?? false
}
