# Swift Package Dependencies

This document records the Swift Package dependencies configured in the Xcode project and their resolved versions.

## Direct Dependencies (8 items)

| Package Name | Repository URL | Dependency Rule | Current Resolved Version |
|--------------|----------------|-----------------|--------------------------|
| **Firebase** | `https://github.com/firebase/firebase-ios-sdk` | Up to Next Major Version (`12.14.0` < `13.0.0`) | `12.14.0` |
| **ReadiumFuzi** | `https://github.com/readium/Fuzi.git` | Up to Next Major Version (`4.0.0` < `5.0.0`) | `4.0.0` |
| **GoogleSignIn** | `https://github.com/google/GoogleSignIn-iOS` | Up to Next Major Version (`9.1.0` < `10.0.0`) | `9.1.0` |
| **iosMath** | `https://github.com/kostub/iosMath.git` | Up to Next Major Version (`2.3.1` < `3.0.0`) | `2.3.1` |
| **Nuke** | `https://github.com/kean/Nuke` | Up to Next Major Version (`12.0.0` < `13.0.0`) | `12.0.0` |
| **Readium** | `https://github.com/readium/swift-toolkit.git` | Up to Next Major Version (`3.8.0` < `4.0.0`) | `3.8.0` |
| **SwiftSoup** | `https://github.com/scinfu/SwiftSoup` | Up to Next Major Version (`2.11.3` < `3.0.0`) | `2.11.3` |
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
