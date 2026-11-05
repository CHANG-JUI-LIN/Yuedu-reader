# Swift Package Dependencies

This document records the Swift Package dependencies configured in the Xcode project and their resolved versions.

## Direct Dependencies (9 items)

| Package Name | Repository URL | Dependency Rule | Current Resolved Version |
|--------------|----------------|-----------------|--------------------------|
| **Firebase** | `https://github.com/firebase/firebase-ios-sdk` | Up to Next Major Version (`12.14.0` < `13.0.0`) | `12.14.0` |
| **ReadiumFuzi** | `https://github.com/readium/Fuzi.git` | Up to Next Major Version (`4.0.0` < `5.0.0`) | `4.0.0` |
| **GoogleSignIn** | `https://github.com/google/GoogleSignIn-iOS` | Up to Next Major Version (`9.1.0` < `10.0.0`) | `9.1.0` |
| **iosMath** | `https://github.com/kostub/iosMath.git` | Up to Next Major Version (`2.3.1` < `3.0.0`) | `2.3.1` |
| **Nuke** | `https://github.com/kean/Nuke` | Up to Next Major Version (`12.0.0` < `13.0.0`) | `12.0.0` |
| **Readium** | `https://github.com/readium/swift-toolkit.git` | Up to Next Major Version (`3.8.0` < `4.0.0`) | `3.8.0` |
| **SwiftSoup** | `Packages/SwiftSoup` (vendored from `https://github.com/scinfu/SwiftSoup`) | Local package; also stands in for the copy Readium and YueduCoreText depend on | `2.13.7` + one backported fix, see its `VENDOR-MANIFEST.json` |
| **LNPopupUI** | `Packages/LNPopupUI` (vendored from `https://github.com/LeoNatan/LNPopupUI`, MIT), product `LNPopupUI-Static` | Local package; brings `Packages/LNPopupController` (`4.6.2`), `Packages/LNSwiftUIUtils` (`1.1.5`) and `Packages/LNSystemMarqueeLabel` (`0.1.2`), each vendored beside it | `4.0.4`, sources only — the upstream histories hold ~2 GB of demo media; see each `VENDOR-MANIFEST.json` |
| **ReadiumZIPFoundation** | `https://github.com/readium/ZIPFoundation.git` | Up to Next Major Version (`3.0.1` < `4.0.0`) | `3.0.1` |

## Transitive Dependencies

These are dependencies of our direct dependencies that Xcode Cloud resolves and builds, and which require SCM connection/authorization during Xcode Cloud setup:

*   **From Readium (`swift-toolkit`):**
    *   `stephencelis/SQLite.swift`
    *   `marmelroy/Zip`
    *   `readium/GCDWebServer`
    *   `krzyzanowskim/CryptoSwift`
    *   `ra1028/DifferenceKit`
*   **From GoogleSignIn-iOS:**
    *   `openid/AppAuth-iOS`
    *   `google/GTMAppAuth`
    *   `google/gtm-session-fetcher`
*   **From Firebase (firebase-ios-sdk):**
    *   `google/abseil-cpp-binary`
    *   `google/interop-ios-for-google-sdks`
    *   `google/GoogleDataTransport`
    *   `google/GoogleUtilities`
    *   `google/app-check`
    *   `google/promises`
    *   `google/GoogleAppMeasurement`
    *   `google/grpc-binary`
    *   `firebase/leveldb`
    *   `googleads/google-ads-on-device-conversion-ios-sdk`

## Ported Code

Not a package: source translated into the app, with the original licence kept beside it.

| Origin | Licence | Where | Notes |
|--------|---------|-------|-------|
| **foliate-js** `mobi.js` (`https://github.com/johnfactotum/foliate-js`, commit `9a676796`) | MIT | `Modules/Core/MOBI/` (`foliate-js-LICENSE.txt`) | MOBI/AZW3 reading, ported to Swift for the import-time converter. libmobi was not used: LGPL-3.0 and ships Kindle DRM removal |
