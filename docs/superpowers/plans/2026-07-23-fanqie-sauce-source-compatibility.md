# Fanqie Sauce Source Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two missing Legado Java bridge primitives so the provided `🌙 番茄酱` source can authenticate requests and complete search, detail, table-of-contents, and chapter-text loading through the existing source pipeline.

**Architecture:** Extend `LegadoJSBridgeExport` and `LegadoJSBridge` with generic HMAC-to-Base64 and Base64-to-byte-array operations implemented by CryptoKit and Foundation. Keep source execution inside `BookSourceSession` and prove the compatibility at two levels: deterministic bridge tests that run JavaScriptCore exports, and an opt-in fixture/live test that loads the user's unchanged source JSON.

**Tech Stack:** Swift 6, JavaScriptCore, CryptoKit, Foundation, Swift Testing, existing `BookSourceFetcher`/`BookSourceSession`.

---

## File Structure

- Modify `Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift`
  - Export and implement the two missing Legado-compatible Java APIs.
  - Normalize HMAC algorithm names and keep all secret-bearing inputs out of logs.
- Modify `Tests/iOS/yuedu appTests/ModernParserTests.swift`
  - Add deterministic Swift and JavaScriptCore regression coverage for the bridge APIs.
- Create `Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift`
  - Load the provided source JSON without copying it into the repository.
  - Prove its obfuscated `buildRequest` emits a non-empty authorization value.
  - Offer an explicitly enabled live basic-flow test.

No parser, network, cache, session, UI, or localization file changes are required.

### Task 1: Specify the Missing JavaScript Bridge Behavior

**Files:**
- Modify: `Tests/iOS/yuedu appTests/ModernParserTests.swift:1838-1846`
- Modify: `Tests/iOS/yuedu appTests/ModernParserTests.swift:2110-2142`

- [ ] **Step 1: Add JavaScriptCore export tests**

Add these tests to `JSCoreEngineTests` immediately after `javaBase64Bridge()`:

```swift
@Test("java.HMacBase64 exports HMAC-SHA256 to JavaScript")
func javaHMACBase64Bridge() {
    let engine = JSCoreEngine()
    let result = engine.evaluate(
        "java.HMacBase64('The quick brown fox jumps over the lazy dog', 'HmacSHA256', 'key')"
    )

    #expect(result == "97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg=")
}

@Test("java.base64DecodeToByteArray exports unsigned bytes to JavaScript")
func javaBase64ByteArrayBridge() {
    let engine = JSCoreEngine()
    let result = engine.evaluate(
        "JSON.stringify(java.base64DecodeToByteArray('AH+A/w=='))"
    )

    #expect(result == "[0,127,128,255]")
}
```

- [ ] **Step 2: Add direct bridge semantic tests**

Add these tests to `LegadoJSBridgeTests` immediately after `base64DecodeInvalid()`:

```swift
@Test("HMacBase64 supports Legado HMAC algorithm names")
func hmacBase64Algorithms() {
    let bridge = LegadoJSBridge()
    let content = "The quick brown fox jumps over the lazy dog"
    let vectors: [(algorithm: String, expected: String)] = [
        ("HmacSHA1", "3nybhbi3iqa8ino29wqQcBydtNk="),
        ("HmacSHA256", "97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg="),
        ("HmacSHA384", "1/RyfiwLOa4PHkDMlvYCQtW3gBhBzqb8WSxdPhrlBwBYKpbPNeHlVJlf5OAzgcI3"),
        ("HmacSHA512", "tCrwkFe6weLUFwjkipAuCbX/fxKrQopP6GZTxz3SSPuC+UilSfe3kaW0GRXuTR7Dk1NX5OIxclDQNyr6Lr7rOg=="),
    ]

    for vector in vectors {
        #expect(bridge.HMacBase64(content, vector.algorithm, "key") == vector.expected)
    }
    #expect(
        bridge.HMacBase64(content, "hmac-sha-256", "key")
            == vectors[1].expected
    )
    #expect(bridge.HMacBase64(content, "unsupported", "key").isEmpty)
}

@Test("base64DecodeToByteArray preserves unsigned byte values")
func base64DecodeToByteArray() {
    let bridge = LegadoJSBridge()

    #expect(bridge.base64DecodeToByteArray("AH+A/w==") == [0, 127, 128, 255])
    #expect(bridge.base64DecodeToByteArray("A").isEmpty)
}
```

- [ ] **Step 3: Hand the focused red-test command to the user**

Project instructions prohibit the agent from directly running long `xcodebuild` commands. Ask the user to run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:'yuedu appTests/JSCoreEngineTests' \
  -only-testing:'yuedu appTests/LegadoJSBridgeTests'
```

Expected result before production code: compilation fails because `LegadoJSBridge` has no members named `HMacBase64` and `base64DecodeToByteArray`. Record that result before Task 2.

### Task 2: Implement the Shared Legado Bridge Primitives

**Files:**
- Modify: `Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:58-70`
- Modify: `Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:653-680`
- Test: `Tests/iOS/yuedu appTests/ModernParserTests.swift`

- [ ] **Step 1: Export both APIs to JavaScriptCore**

Add the following declarations under the `// Encoding / Decoding` section of `LegadoJSBridgeExport`:

```swift
func HMacBase64(_ content: String, _ algorithm: String, _ key: String) -> String
func base64DecodeToByteArray(_ str: String) -> [Int]
```

- [ ] **Step 2: Implement HMAC-to-Base64**

Add this method immediately after `base64Encode(_:)`:

```swift
func HMacBase64(_ content: String, _ algorithm: String, _ key: String) -> String {
    let normalized = algorithm.uppercased().filter { $0.isLetter || $0.isNumber }
    let message = Data(content.utf8)
    let symmetricKey = SymmetricKey(data: Data(key.utf8))

    switch normalized {
    case "HMACSHA1", "SHA1":
        return Data(
            HMAC<Insecure.SHA1>.authenticationCode(
                for: message,
                using: symmetricKey
            )
        ).base64EncodedString()
    case "HMACSHA256", "SHA256":
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: message,
                using: symmetricKey
            )
        ).base64EncodedString()
    case "HMACSHA384", "SHA384":
        return Data(
            HMAC<SHA384>.authenticationCode(
                for: message,
                using: symmetricKey
            )
        ).base64EncodedString()
    case "HMACSHA512", "SHA512":
        return Data(
            HMAC<SHA512>.authenticationCode(
                for: message,
                using: symmetricKey
            )
        ).base64EncodedString()
    default:
        AppLogger.parse(
            "Legado bridge rejected unsupported HMAC algorithm",
            context: ["algorithm": normalized]
        )
        return ""
    }
}
```

The log intentionally includes only the normalized algorithm identifier. Do not log `content`, `key`, the digest, or a generated request header.

- [ ] **Step 3: Implement Base64-to-unsigned-byte-array**

Add this method immediately after `base64Decode(_:)`:

```swift
func base64DecodeToByteArray(_ str: String) -> [Int] {
    guard let data = Data(
        base64Encoded: str,
        options: .ignoreUnknownCharacters
    ) else {
        AppLogger.parse("Legado bridge rejected invalid Base64 byte-array input")
        return []
    }
    return data.map(Int.init)
}
```

The result must remain `[Int]` so JavaScriptCore exposes values as `0...255`; do not use `[Int8]` or convert the data to text.

- [ ] **Step 4: Perform static checks before requesting the green test**

Run the non-building checks:

```bash
git diff --check
rg -n 'HMacBase64|base64DecodeToByteArray' \
  Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift \
  'Tests/iOS/yuedu appTests/ModernParserTests.swift'
rg -n 'content|key|digest|Authorization' \
  Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift
```

Expected result:

- `git diff --check` prints nothing.
- Both API names appear once in the export protocol, once in the implementation, and in focused tests.
- Review every matching log statement from the final command and confirm the new methods do not emit secret-bearing values.

- [ ] **Step 5: Hand the focused green-test command to the user**

Ask the user to rerun the Task 1 command.

Expected result: `JSCoreEngineTests` and `LegadoJSBridgeTests` pass with parallel testing disabled.

- [ ] **Step 6: Commit the bridge implementation and focused tests**

```bash
git add \
  Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift \
  'Tests/iOS/yuedu appTests/ModernParserTests.swift'
git commit -m "fix: add Legado HMAC byte bridge"
```

### Task 3: Prove Compatibility with the Provided Source

**Files:**
- Create: `Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift`
- Test: `/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json`

- [ ] **Step 1: Add the source-fixture test suite**

Create `Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift` with:

```swift
import Foundation
import Testing
@testable import yuedu_app

@Suite("Fanqie Sauce source compatibility", .serialized)
struct FanqieSauceSourceTests {

    static var jsonPath: String {
        ProcessInfo.processInfo.environment["FANQIE_SAUCE_SOURCE_JSON"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_FANQIE_SAUCE_SOURCE_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json"
    }

    static var runLiveTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["RUN_LIVE_FANQIE_SAUCE_TESTS"] == "1"
            || env["TEST_RUNNER_RUN_LIVE_FANQIE_SAUCE_TESTS"] == "1"
    }

    private func loadSource() throws -> BookSource? {
        guard FileManager.default.fileExists(atPath: Self.jsonPath) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.jsonPath))
        if let source = try? JSONDecoder().decode(BookSource.self, from: data) {
            return source
        }
        return try JSONDecoder().decode([BookSource].self, from: data)
            .first { $0.bookSourceName == "🌙 番茄酱" }
    }

    @Test("provided source buildRequest emits authorization")
    func buildRequestEmitsAuthorization() throws {
        guard let source = try loadSource() else { return }
        let engine = JSCoreEngine()
        engine.bookSource = source

        _ = engine.evaluate(
            source.jsLib,
            bindings: ["baseUrl": source.bookSourceUrl]
        )
        #expect(engine.lastError == nil)
        #expect(engine.evaluate("typeof buildRequest") == "function")

        let request = try #require(engine.evaluate(
            """
            (function () {
                const value = buildRequest(
                    backend + '/fq/detail?book_id=7045187140329671720'
                );
                return typeof value === 'string' ? value : JSON.stringify(value);
            })()
            """
        ))
        let authorizationPattern = try NSRegularExpression(
            pattern: #""Authorization"\s*:\s*"[^"]+""#
        )
        let range = NSRange(request.startIndex..., in: request)

        #expect(authorizationPattern.firstMatch(in: request, range: range) != nil)
        #expect(engine.lastError == nil)
    }

    @Test("live source completes the basic reading flow")
    func liveBasicReadingFlow() async throws {
        guard Self.runLiveTests, let source = try loadSource() else { return }
        let fetcher = BookSourceFetcher.shared

        let books = try await fetcher.search(
            query: "重生医妃一睁眼，全京城排队抢亲",
            in: source
        )
        let book = try #require(
            books.first { $0.name.contains("重生医妃一睁眼") }
                ?? books.first
        )
        let info = try await fetcher.fetchBookInfoPackage(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        #expect(info.name.contains("重生医妃一睁眼"))

        let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: info.runtimeVariables
        )
        let chapter = try #require(
            toc.chapters.first {
                $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator
            }
        )
        #expect(chapter.title.contains("第1章"))

        let bookID = UUID()
        defer {
            fetcher.clearAllChapterCache(bookId: bookID)
        }
        let package = try await fetcher.fetchChapterPackage(
            ref: chapter,
            bookId: bookID,
            source: source,
            chapterReferer: tocURL
        )

        #expect(!package.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty)
        #expect(!package.content.contains("请求失败"))
        #expect(!package.content.contains("undefined is not an object"))
    }
}
```

- [ ] **Step 2: Review the fixture test for isolation**

Run:

```bash
git diff --check
rg -n '🌙 番茄酱|bookSourceName|bookSourceUrl' \
  Modules Targets \
  'Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift'
```

Expected result:

- Production code contains no `🌙 番茄酱` source-name or source-URL branch.
- The source name appears only in the local fixture test and documentation.
- The fixture test uses `BookSourceFetcher.shared`, which already routes parsing through `BookSourceSession`.

- [ ] **Step 3: Hand the deterministic fixture-test command to the user**

Ask the user to run:

```bash
TEST_RUNNER_FANQIE_SAUCE_SOURCE_JSON='/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json' \
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:'yuedu appTests/FanqieSauceSourceTests/buildRequestEmitsAuthorization'
```

Expected result: the test passes and the source's unchanged `jsLib` produces a non-empty authorization value.

- [ ] **Step 4: Hand the opt-in full-flow command to the user**

Ask the user to run:

```bash
TEST_RUNNER_FANQIE_SAUCE_SOURCE_JSON='/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json' \
TEST_RUNNER_RUN_LIVE_FANQIE_SAUCE_TESTS=1 \
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:'yuedu appTests/FanqieSauceSourceTests/liveBasicReadingFlow'
```

Expected result: search returns the target book, detail and TOC load, the first non-volume chapter is `第1章`, and chapter content is non-empty without the original JavaScript error.

- [ ] **Step 5: Commit the source compatibility tests**

```bash
git add 'Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift'
git commit -m "test: cover Fanqie Sauce source flow"
```

### Task 4: Final Static Verification and Handoff

**Files:**
- Review: `Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift`
- Review: `Tests/iOS/yuedu appTests/ModernParserTests.swift`
- Review: `Tests/iOS/yuedu appTests/FanqieSauceSourceTests.swift`

- [ ] **Step 1: Verify the final diff**

Run:

```bash
git diff HEAD~2 --check
git diff HEAD~2 --stat
git status --short --untracked-files=all
```

Expected result:

- No whitespace errors.
- The diff is limited to the bridge implementation and focused tests.
- The worktree is clean after the two implementation commits.

- [ ] **Step 2: Verify architecture and safety constraints**

Run:

```bash
rg -n '🌙 番茄酱|7045187140329671720' Modules Targets
rg -n 'Task\\.sleep|sleep\\(|retry|fallback' \
  Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift
rg -n 'HMacBase64|base64DecodeToByteArray' \
  Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift
```

Expected result:

- No source-specific production branch or hard-coded book identifier.
- No retry, delay, second loader, or fallback was added.
- Both compatibility APIs are present in the shared export protocol and implementation.

- [ ] **Step 3: Report verification evidence**

The final response must include:

- Root cause: missing `java.HMacBase64` and `java.base64DecodeToByteArray`.
- Files changed and the fact that the fix is generic.
- Focused test results supplied by the user.
- Live basic-flow result, or an explicit note if the user has not run the opt-in live command.
- The exact command the user can rerun later.
