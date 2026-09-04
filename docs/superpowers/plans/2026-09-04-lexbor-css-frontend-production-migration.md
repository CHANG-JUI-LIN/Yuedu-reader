# Lexbor CSS Frontend Production Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vend official Lexbor `v3.0.0`, adapt its DOM/CSS/selector/style output into Yuedu's existing `ComputedStyleNode`, prove Current/Lexbor semantic and geometry attribution across the complete corpus, and change the production frontend default only if every cutover gate passes.

**Architecture:** `PublicationSession` and `EPUBStyleResolver` remain the only EPUB resource path. A typed `CSSFrontendInput` feeds either `CurrentCSSFrontend` or `LexborCSSFrontend`; both produce a pointer-free `CSSFrontendResult` containing the same neutral DOM snapshots, computed style tree, semantic metadata, diagnostics, and scanner facts. `BoxTreeBuilder` and every layout/fragmentation/paint stage consume that result without knowing Lexbor exists and without changing layout algorithms.

**Tech Stack:** Swift 6, Swift Testing, SwiftSoup (retained Current frontend), vendored Lexbor C `v3.0.0`, SwiftPM C target, CoreText BrowserLayout, Xcode 16+, iOS 17+.

---

## Guardrails and fixed identities

- Geometry baseline: `b674e672 browser-layout: close horizontal correctness baseline`.
- Upstream: `https://github.com/lexbor/lexbor.git`, lightweight tag `v3.0.0`, commit `2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe`.
- Upstream hashes:
  - `single.pl`: `8bf7856ea4195ad41945a81d3b37343a2ef489a5ff8f9abdffd481979d1c7ea2`
  - `version`: `6c4ca09e0d3549711034c2ce201cd27153bdd686cd57a60db8d7aed76068e087`
  - `LICENSE`: `7321caa1f366dfbebf799b6c6c2604772dbb12ef10ed6a6b7cbb384b3401c4dd`
  - `NOTICE`: `b87f965fd2eba846a0a502d633dd7e7a680b93de5c514c404c948ccf1e5c9dc7`
- Generator command: `LC_ALL=C TZ=UTC perl single.pl --port=posix html css selectors style`.
- Resolved module closure: `core css dom html ns selectors style tag`.
- No independent DerivedData. Every `xcodebuild` command below uses Xcode's existing shared/default DerivedData.
- No Xcode build phase or SwiftPM plugin may invoke `single.pl`, regenerate files, clone, or download. Lexbor Layout is never included.
- No production changes to `BlockLayout.swift`, `InlineLayout.swift`, `PageFragmentation.swift`, `PageWalker`, `DisplayList.swift`, or paint.
- Keep unrelated dirty worktree files out of every phase commit by staging exact paths only.

## File map

### Vendored package and reproducibility

- Create `Packages/CLexbor/Package.swift`: local C package; compiles committed source only.
- Create `Packages/CLexbor/LICENSE` and `Packages/CLexbor/NOTICE`: byte-copies of upstream legal files.
- Create `Packages/CLexbor/VENDOR-MANIFEST.json`: tag, commit, generator hashes/arguments, release timestamp, modules, and output hashes.
- Create `Packages/CLexbor/Sources/CLexbor/include/CLexbor.h`: narrow opaque Yuedu bridge API.
- Create `Packages/CLexbor/Sources/CLexbor/CLexborBridgeImplementation.inc`: bridge implementation included by the one C translation unit.
- Create `Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.h`: deterministic header half.
- Create `Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.c`: deterministic source half and only compiled C source.
- Create `Packages/CLexbor/Tests/CLexborTests/CLexborSmokeTests.swift`: version, parse, traversal, style, and lifetime tests.
- Create `scripts/vendor_lexbor.sh`: manual verified regeneration; never called by SwiftPM/Xcode.
- Create `scripts/verify_vendored_lexbor.sh`: offline manifest/hash verifier.

### Frontend-neutral models and Current parity

- Create `Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift`: typed input, stylesheet identity, neutral DOM snapshot, diagnostics, capability facts, and style-source identity.
- Create `Modules/Core/ReaderCore/BrowserLayout/CurrentCSSFrontend.swift`: named Current facade.
- Modify `Modules/Core/ReaderCore/BrowserLayout/CSSFrontend.swift`: typed protocol and Legacy compatibility facade.
- Modify `Modules/Core/ReaderCore/BrowserLayout/ComputedStyleTreeBuilder.swift`: snapshot neutral DOM values.
- Modify `Modules/Core/ReaderCore/BrowserLayout/BoxTreeBuilder.swift`: consume neutral attributes/SVG facts instead of SwiftSoup objects.
- Modify `Modules/Core/ReaderCore/HTML/SwiftSoupHTMLSemanticAdapter.swift`: snapshot current DOM semantics.
- Modify `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutDocument.swift`: accept typed input or prepared result.

### Resource ingestion and Lexbor frontend

- Modify `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutResourceProviding.swift` and `EPUBBrowserLayoutResourceAdapter.swift`: typed, ordered stylesheets through the existing resolver.
- Create `Modules/Core/ReaderCore/BrowserLayout/LexborDocumentOwner.swift`, `LexborHTMLSemanticAdapter.swift`, `LexborComputedStyleAdapter.swift`, `LexborCSSFrontend.swift`, and `BrowserLayoutCSSFrontendFactory.swift` in that same directory.
- Modify `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutCapabilityScanner.swift`, `BrowserLayoutPageEngine.swift`, and `BrowserLayoutSession.swift` in that same directory: one frontend evaluation shared by scanner and layout.
- Modify DEBUG reader files and three localization files to expose Current/Lexbor selection.

### Tests and evidence

- Create focused Lexbor package, synthetic, coverage, scanner, corpus, layout, lifetime, performance, and DEBUG-switch suites under `Tests/iOS/yuedu appTests/`.
- Store committed evidence under `docs/browser-layout/lexbor-migration/`.

## Task 1: Capture the pre-integration baseline

**Files:**
- Create: `docs/browser-layout/lexbor-migration/pre-integration.json`
- Reference: `docs/browser-layout/line-break-baseline/closure-2026-08-31.md`

- [ ] **Step 1: Record repository/toolchain identity**

Run:

```bash
git rev-parse HEAD
git status --short
xcodebuild -version
swift --version
xcrun simctl list devices available | rg 'iPhone 17 Pro Max'
```

Expected: identities are explicit; preserve pre-existing dirty paths instead of staging them.

- [ ] **Step 2: Re-run the fixed line-break baseline**

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests'
```

Expected: PASS before vendoring. Do not pass `-derivedDataPath`.

- [ ] **Step 3: Capture pre-integration build timing and executable size**

```bash
/usr/bin/time -p xcodebuild \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -showBuildTimingSummary build | tee /tmp/yuedu-lexbor-pre-build.log

xcodebuild \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -showBuildSettings | rg 'TARGET_BUILD_DIR|EXECUTABLE_PATH'
```

Resolve the executable from build settings; record `stat -f '%z'` and `xcrun size -m`.

- [ ] **Step 4: Write and validate evidence**

Use:

```json
{
  "schemaVersion": 1,
  "geometryBaseline": "b674e672",
  "simulatorUDID": "D787D0F2-DD88-475A-9BC2-D4484B706011",
  "lineBreakBaselinePassed": true,
  "debugExecutableBytes": 123,
  "debugMachOSize": {},
  "buildTimingSeconds": {},
  "recordedAtUTC": "2026-09-04T00:00:00Z"
}
```

Replace example measurements/timestamp with observed values.

```bash
plutil -lint docs/browser-layout/lexbor-migration/pre-integration.json
git diff --check -- docs/browser-layout/lexbor-migration/pre-integration.json
git add docs/browser-layout/lexbor-migration/pre-integration.json
git commit -m "test(browser-layout): capture pre-Lexbor baseline"
```

## Task 2: Vendor deterministic Lexbor `v3.0.0`

**Files:**
- Create: `scripts/vendor_lexbor.sh`
- Create: `scripts/verify_vendored_lexbor.sh`
- Create: `Packages/CLexbor/Package.swift`
- Create: `Packages/CLexbor/LICENSE`
- Create: `Packages/CLexbor/NOTICE`
- Create: `Packages/CLexbor/VENDOR-MANIFEST.json`
- Create: `Packages/CLexbor/Sources/CLexbor/include/CLexbor.h`
- Create: `Packages/CLexbor/Sources/CLexbor/CLexborBridgeImplementation.inc`
- Create: `Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.h`
- Create: `Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.c`
- Create: `Packages/CLexbor/Tests/CLexborTests/CLexborSmokeTests.swift`

- [ ] **Step 1: Write the failing offline verifier**

Core checks:

```bash
#!/bin/bash
set -euo pipefail
package_dir="${1:-Packages/CLexbor}"
manifest="$package_dir/VENDOR-MANIFEST.json"
test "$(plutil -extract upstream.commit raw -o - "$manifest")" = \
  "2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe"
for relative in LICENSE NOTICE \
  Sources/CLexbor/lexbor-amalgamated.generated.h \
  Sources/CLexbor/lexbor-amalgamated.generated.c; do
  key=$(basename "$relative" | tr '.-' '__')
  expected=$(plutil -extract "outputs.$key.sha256" raw -o - "$manifest")
  actual=$(shasum -a 256 "$package_dir/$relative" | awk '{print $1}')
  test "$actual" = "$expected"
done
```

Run `bash scripts/verify_vendored_lexbor.sh`; expected FAIL because outputs are absent.

- [ ] **Step 2: Implement verified manual generation**

`scripts/vendor_lexbor.sh` uses:

```bash
expected_commit=2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe
expected_version='LEXBOR_VERSION=3.0.0'
expected_generator_sha=8bf7856ea4195ad41945a81d3b37343a2ef489a5ff8f9abdffd481979d1c7ea2
expected_license_sha=7321caa1f366dfbebf799b6c6c2604772dbb12ef10ed6a6b7cbb384b3401c4dd
expected_notice_sha=b87f965fd2eba846a0a502d633dd7e7a680b93de5c514c404c948ccf1e5c9dc7
release_date='Tue Mar 31 18:45:44 2026 UTC'
modules=(html css selectors style)
```

It must:

1. accept exactly one already-checked-out upstream directory;
2. verify exact commit, `version`, `single.pl`, `LICENSE`, and `NOTICE`;
3. run `LC_ALL=C TZ=UTC perl single.pl --port=posix html css selectors style` twice;
4. normalize only the generated `Date:` and copyright end-year to v3.0.0 release metadata;
5. byte-compare normalized outputs;
6. split at the first line matching `^/\* Source:`;
7. wrap the header half with `YUEDU_LEXBOR_AMALGAMATED_GENERATED_H`;
8. prefix C with `#include "lexbor-amalgamated.generated.h"` and suffix it with `#include "CLexborBridgeImplementation.inc"`;
9. copy `LICENSE` and `NOTICE` byte-for-byte;
10. emit sorted manifest keys and output SHA-256 values.

The script never clones/downloads, invokes SwiftPM, or edits Xcode.

The manifest uses identifier-safe output keys so offline extraction is unambiguous:

```json
{
  "upstream": {
    "repository": "https://github.com/lexbor/lexbor.git",
    "tag": "v3.0.0",
    "tagType": "lightweight",
    "commit": "2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe"
  },
  "generation": {
    "command": "perl single.pl --port=posix html css selectors style",
    "requestedModules": ["html", "css", "selectors", "style"],
    "resolvedModules": ["core", "css", "dom", "html", "ns", "selectors", "style", "tag"]
  },
  "outputs": {
    "LICENSE": {"path": "LICENSE"},
    "NOTICE": {"path": "NOTICE"},
    "lexbor_amalgamated_generated_h": {"path": "Sources/CLexbor/lexbor-amalgamated.generated.h"},
    "lexbor_amalgamated_generated_c": {"path": "Sources/CLexbor/lexbor-amalgamated.generated.c"}
  }
}
```

The generator adds a 64-character lowercase `sha256` field beside every shown `path`; the value is the direct output of `shasum -a 256` for that committed file.

- [ ] **Step 3: Add the C-only local package**

`Packages/CLexbor/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CLexbor",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CLexbor", targets: ["CLexbor"])],
    targets: [
        .target(
            name: "CLexbor",
            path: "Sources/CLexbor",
            exclude: ["CLexborBridgeImplementation.inc"],
            sources: ["lexbor-amalgamated.generated.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .testTarget(name: "CLexborTests", dependencies: ["CLexbor"])
    ]
)
```

Initial narrow header:

```c
#ifndef YUEDU_CLEXBOR_H
#define YUEDU_CLEXBOR_H
#include <stddef.h>
#include <stdint.h>
const char *ylx_lexbor_version(void);
#endif
```

The implementation returns `LEXBOR_VERSION_STRING`. It exposes no upstream struct.

- [ ] **Step 4: Generate twice and prove byte identity**

```bash
YUEDU_LEXBOR_AUDIT_ROOT=$(mktemp -d /tmp/yuedu-lexbor-v3.0.0.XXXXXX)
export YUEDU_LEXBOR_UPSTREAM="$YUEDU_LEXBOR_AUDIT_ROOT/lexbor"
git clone --depth 1 --branch v3.0.0 \
  https://github.com/lexbor/lexbor.git "$YUEDU_LEXBOR_UPSTREAM"
test "$(git -C "$YUEDU_LEXBOR_UPSTREAM" rev-parse HEAD)" = \
  2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe
bash scripts/vendor_lexbor.sh "$YUEDU_LEXBOR_UPSTREAM"
shasum -a 256 Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.{h,c} \
  Packages/CLexbor/VENDOR-MANIFEST.json > /tmp/yuedu-lexbor-first.sha
bash scripts/vendor_lexbor.sh "$YUEDU_LEXBOR_UPSTREAM"
shasum -a 256 Packages/CLexbor/Sources/CLexbor/lexbor-amalgamated.generated.{h,c} \
  Packages/CLexbor/VENDOR-MANIFEST.json > /tmp/yuedu-lexbor-second.sha
cmp /tmp/yuedu-lexbor-first.sha /tmp/yuedu-lexbor-second.sha
bash scripts/verify_vendored_lexbor.sh
```

Expected: identical hashes and offline verification PASS.

- [ ] **Step 5: Add/run the package smoke test**

```swift
import CLexbor
import Testing

@Test func reportsPinnedVersion() {
    #expect(String(cString: ylx_lexbor_version()) == "3.0.0")
}
```

Run `swift test --package-path Packages/CLexbor`; expected PASS without network fetch.

- [ ] **Step 6: Commit every generation input/output together**

```bash
git add Packages/CLexbor scripts/vendor_lexbor.sh scripts/verify_vendored_lexbor.sh
git diff --cached --check
git commit -m "build(lexbor): vendor deterministic v3.0.0 amalgamation"
```

## Task 3: Link the package and establish opaque lifetime ownership

**Files:**
- Modify: `Yuedu-Reader.xcodeproj/project.pbxproj`
- Modify: `Packages/CLexbor/Sources/CLexbor/include/CLexbor.h`
- Modify: `Packages/CLexbor/Sources/CLexbor/CLexborBridgeImplementation.inc`
- Modify: `Packages/CLexbor/Tests/CLexborTests/CLexborSmokeTests.swift`
- Create: `Modules/Core/ReaderCore/BrowserLayout/LexborDocumentOwner.swift`
- Create: `Tests/iOS/yuedu appTests/LexborCSSFrontendLifetimeTests.swift`

- [ ] **Step 1: Write package parse/destruction tests**

Public contract:

```c
typedef struct YLXDocument YLXDocument;
typedef enum {
    YLX_STATUS_OK = 0,
    YLX_STATUS_INVALID_ARGUMENT = 1,
    YLX_STATUS_PARSE_ERROR = 2,
    YLX_STATUS_OUT_OF_MEMORY = 3
} YLXStatus;

YLXDocument *ylx_document_create(const uint8_t *, size_t, YLXStatus *);
void ylx_document_destroy(YLXDocument *);
size_t ylx_document_element_count(const YLXDocument *);
size_t ylx_debug_live_document_count(void);
```

Test valid XHTML, malformed recovery, empty input failure, six sequential create/destroy cycles, and live count zero.

- [ ] **Step 2: Verify tests fail before implementation**

`swift test --package-path Packages/CLexbor --filter CLexborSmokeTests`

Expected: compile failure for missing `ylx_document_*`.

- [ ] **Step 3: Implement one cleanup path**

The private `YLXDocument` owns one `lxb_html_document_t` plus a `styleInitialized` flag. Creation allocates the wrapper, creates/initializes the HTML document, parses bytes without enabling the style module, and unwinds every acquired resource on failure. Task 6 enables style after DOM parse so inline `<style>` is not auto-attached out of order. Destruction calls `lxb_style_destroy` only when the flag is set, then `lxb_html_document_destroy` and frees the wrapper. Live-count accounting increments only after complete creation and decrements exactly once.

- [ ] **Step 4: Implement Swift non-escaping ownership**

```swift
import CLexbor

final class LexborDocumentOwner {
    enum Error: Swift.Error, Equatable { case invalidInput, parseFailed, outOfMemory }
    private var ref: OpaquePointer?

    init(html: String) throws {
        var status = YLX_STATUS_OK
        ref = html.utf8CString.withUnsafeBytes { bytes in
            ylx_document_create(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                max(0, bytes.count - 1),
                &status
            )
        }
        guard ref != nil else { throw Self.error(for: status) }
    }

    deinit { ylx_document_destroy(ref) }

    func withDocument<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try body(ref!)
    }

    private static func error(for status: YLXStatus) -> Error {
        switch status {
        case YLX_STATUS_INVALID_ARGUMENT: .invalidInput
        case YLX_STATUS_OUT_OF_MEMORY: .outOfMemory
        default: .parseFailed
        }
    }
}
```

No method returns the pointer and no callback escapes.

- [ ] **Step 5: Add local package using Xcode's local-package workflow**

Use Xcode **File → Add Package Dependencies… → Add Local…**, choose `Packages/CLexbor`, product `CLexbor`, target `Yuedu-Reader`. Do not hand-edit `.pbxproj` and do not add a remote URL.

```bash
rg -n 'XCLocalSwiftPackageReference|Packages/CLexbor|CLexbor in Frameworks' \
  Yuedu-Reader.xcodeproj/project.pbxproj
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -resolvePackageDependencies
```

Expected: one local reference/product/link entry; no Lexbor fetch.

- [ ] **Step 6: Run package, lifetime, simulator, and device compilation**

```bash
swift test --package-path Packages/CLexbor
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendLifetimeTests'
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Expected: PASS/link on arm64 simulator and generic arm64 device.

- [ ] **Step 7: Commit exact bridge/project paths**

```bash
git add Packages/CLexbor/Sources/CLexbor/include/CLexbor.h \
  Packages/CLexbor/Sources/CLexbor/CLexborBridgeImplementation.inc \
  Packages/CLexbor/Tests/CLexborTests/CLexborSmokeTests.swift \
  Modules/Core/ReaderCore/BrowserLayout/LexborDocumentOwner.swift \
  'Tests/iOS/yuedu appTests/LexborCSSFrontendLifetimeTests.swift' \
  Yuedu-Reader.xcodeproj/project.pbxproj
git commit -m "feat(browser-layout): add opaque Lexbor document owner"
```

## Task 4: Make Current frontend output DOM-neutral with exact parity

**Files:**
- Create: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift`
- Create: `Modules/Core/ReaderCore/BrowserLayout/CurrentCSSFrontend.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontend.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/ComputedStyleTreeBuilder.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BoxTreeBuilder.swift`
- Modify: `Modules/Core/ReaderCore/HTML/SwiftSoupHTMLSemanticAdapter.swift`
- Modify: `Tests/iOS/yuedu appTests/BrowserLayoutTestSupport.swift`
- Modify: `Tests/iOS/yuedu appTests/BrowserLayoutLineBreakBaselineTests.swift`
- Modify: `Tests/iOS/yuedu appTests/BrowserLayoutInlineFormattingContextCorpusTests.swift`
- Create: `Tests/iOS/yuedu appTests/CurrentCSSFrontendNeutralDOMParityTests.swift`

- [ ] **Step 1: Write failing neutral-DOM tests**

Create the final typed input/diagnostic identities before changing the protocol:

```swift
struct CSSFrontendInput {
    let html: String
    let stylesheets: [AuthorStylesheet]
}

struct AuthorStylesheet: Equatable {
    enum Source: Equatable {
        case inline(nodeOrdinal: Int)
        case linked(href: String)
    }
    let source: Source
    let text: String
    let sourceOrder: Int
    let currentCompatibilityOrder: Int?
    let currentCompatibilityOnly: Bool
    let media: String?
    let isAlternate: Bool
}

struct StylesheetIdentity: Hashable, Codable {
    let sourceOrder: Int
    let label: String
}

struct CSSFrontendDiagnostic: Equatable {
    enum Stage { case html, css, selector, style, ingestion, adapter, allocation }
    let stage: Stage
    let stylesheet: StylesheetIdentity?
    let semanticPath: String?
    let property: String?
    let message: String
}
```

Then add the neutral element model:

```swift
struct HTMLDOMElementSnapshot: Equatable {
    let semanticPath: String
    let tagName: String
    let namespace: String?
    let attributes: [String: String]
    let svgRenderability: SVGRenderability?

    func attribute(_ name: String) -> String? {
        attributes[name.lowercased()]
    }
}

enum SVGRenderability: Equatable {
    case rasterWrapper(source: String)
    case unsupportedVector
}
```

Tests cover tag/namespace/all attributes, sibling ordinal path, child/text order, href, `epub:type`, role, image src, SVG wrapper, id, and classes. `CSSFrontendResult` must retain no SwiftSoup `Element`.

- [ ] **Step 2: Run new and existing semantic tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/CurrentCSSFrontendNeutralDOMParityTests' \
  -only-testing:'yuedu appTests/BrowserLayoutImageTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLinkInteractionTests'
```

Expected: neutral tests fail before the model exists.

- [ ] **Step 3: Snapshot Current DOM before return**

`SwiftSoupHTMLSemanticAdapter` enumerates all authored attributes. `ComputedStyleTreeBuilder` may match with SwiftSoup internally but constructs `ComputedStyleNode.semanticElement` as a value. Link semantics read snapshot values:

```swift
extension HTMLDOMElementSnapshot {
    var linkSemantic: LinkSemantic {
        let epub = LinkSemantic.from(epubType: attribute("epub:type") ?? "")
        if epub != .plain { return epub }
        let roles = (attribute("role") ?? "").lowercased().split(separator: " ")
        return roles.contains("doc-noteref") ? .noteref : .plain
    }
}
```

Presentational hints still receive `HTMLSemanticElement`.

Keep the existing post-order `nodeID` assignment exactly unchanged, including the root id/node-count contract. Lexbor must reproduce that assignment after its value snapshot is complete; semantic paths are differential keys, not a reason to renumber production fragments.

- [ ] **Step 4: Move layout-side DOM reads to neutral values**

Change `BoxTreeBuilder` image/src/class and SVG-wrapper reads to `HTMLDOMElementSnapshot`. It must not import `CLexbor` or `SwiftSoup`. This changes data ownership only; box semantics/geometry remain unchanged.

- [ ] **Step 5: Add Current facade and Legacy compatibility facade**

```swift
final class CurrentCSSFrontend: CSSFrontend {
    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        // Existing SwiftSoup, CSSParser, and ComputedStyleTreeBuilder path.
    }
}

final class LegacyCSSFrontend: CSSFrontend {
    private let current = CurrentCSSFrontend()
    func buildStyleTree(
        input: CSSFrontendInput,
        config: BrowserLayoutConfig,
        metrics: inout LayoutMetrics
    ) throws -> CSSFrontendResult {
        try current.buildStyleTree(input: input, config: config, metrics: &metrics)
    }
}
```

- [ ] **Step 6: Prove Current geometry/source parity**

Run neutral, image, link, selection, source mapping, and line-break suites. Expected: all PASS without golden updates.

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/CurrentCSSFrontendNeutralDOMParityTests' \
  -only-testing:'yuedu appTests/BrowserLayoutImageTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLinkInteractionTests' \
  -only-testing:'yuedu appTests/BrowserLayoutSelectionContractTests' \
  -only-testing:'yuedu appTests/BrowserLayoutSourceMappingTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests'
```

- [ ] **Step 7: Commit the refactor**

```bash
git add Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift \
  Modules/Core/ReaderCore/BrowserLayout/CurrentCSSFrontend.swift \
  Modules/Core/ReaderCore/BrowserLayout/CSSFrontend.swift \
  Modules/Core/ReaderCore/BrowserLayout/ComputedStyleTreeBuilder.swift \
  Modules/Core/ReaderCore/BrowserLayout/BoxTreeBuilder.swift \
  Modules/Core/ReaderCore/HTML/SwiftSoupHTMLSemanticAdapter.swift \
  'Tests/iOS/yuedu appTests/BrowserLayoutTestSupport.swift' \
  'Tests/iOS/yuedu appTests/BrowserLayoutLineBreakBaselineTests.swift' \
  'Tests/iOS/yuedu appTests/BrowserLayoutInlineFormattingContextCorpusTests.swift' \
  'Tests/iOS/yuedu appTests/CurrentCSSFrontendNeutralDOMParityTests.swift'
git commit -m "refactor(browser-layout): make frontend DOM output neutral"
```

## Task 5: Preserve typed stylesheet ingestion/source order

**Files:**
- Modify: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutResourceProviding.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/EPUBBrowserLayoutResourceAdapter.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontend.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutDocument.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift`
- Modify: `Tests/iOS/yuedu appTests/BrowserLayoutPageEngineTests.swift`
- Create: `Tests/iOS/yuedu appTests/BrowserLayoutStylesheetIngestionTests.swift`

- [ ] **Step 1: Write failing ingestion tests**

```swift
struct CSSFrontendInput {
    let html: String
    let stylesheets: [AuthorStylesheet]
}

struct AuthorStylesheet: Equatable {
    enum Source: Equatable {
        case inline(nodeOrdinal: Int)
        case linked(href: String)
    }
    let source: Source
    let text: String
    let sourceOrder: Int
    let currentCompatibilityOrder: Int?
    let currentCompatibilityOnly: Bool
    let media: String?
    let isAlternate: Bool
}
```

Use `<head>` order linked A, inline B, linked C targeting one element. Assert B beats A and C beats B at equal cascade weight. Add `style=""`, relative href, local `@import`, remote import rejection, `media="all"`, unsupported media, and alternate stylesheet.

- [ ] **Step 2: Confirm `[String]` ingestion fails the new tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/BrowserLayoutStylesheetIngestionTests'
```

Expected: compile/test failure because metadata/order are absent.

- [ ] **Step 3: Return typed input through the existing resource path**

Replace `processedCSS(forChapter:) -> [String]` with:

```swift
func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput
```

Build one author list carrying true `<head>` `sourceOrder`, while `currentCompatibilityOrder` preserves the exact pre-migration array order used by Current. Any manifest-global sheet or duplicated raw inline block needed only to reproduce the Current baseline is marked `currentCompatibilityOnly`; Lexbor excludes it and records the difference as an ingestion standards correction. Every fetched sheet still goes through the existing `EPUBStyleResolver`. Emit explicit diagnostics for load failure, remote import, unsupported media, and inactive alternate sheet. Do not add ZIP/font/image loaders.

- [ ] **Step 4: Keep Current test compatibility explicit**

Current sorts by `currentCompatibilityOrder`, includes compatibility-only entries, and preserves its existing raw-inline replay. Lexbor sorts active non-compatibility entries by `sourceOrder` and consumes each inline `<style>` once. Test `[String]` maps to monotonically ordered active synthetic linked entries. Inline `style=""` remains inline origin.

- [ ] **Step 5: Run ingestion/resource/geometry regressions**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/BrowserLayoutStylesheetIngestionTests' \
  -only-testing:'yuedu appTests/HTMLPresentationalHintProductionEPUBTests' \
  -only-testing:'yuedu appTests/EPUBStyleResolverPerformanceTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests'
```

Expected: PASS; no unexplained Current geometry change.

- [ ] **Step 6: Commit typed ingestion**

Stage the six production paths, focused mocks, and ingestion test by exact name; commit:

```bash
git commit -m "refactor(browser-layout): preserve stylesheet source identity"
```

## Task 6: Implement Lexbor DOM/cascade snapshots

**Files:**
- Modify: `Packages/CLexbor/Sources/CLexbor/include/CLexbor.h`
- Modify: `Packages/CLexbor/Sources/CLexbor/CLexborBridgeImplementation.inc`
- Modify: `Packages/CLexbor/Tests/CLexborTests/CLexborSmokeTests.swift`
- Create: `Modules/Core/ReaderCore/BrowserLayout/LexborHTMLSemanticAdapter.swift`
- Create: `Modules/Core/ReaderCore/BrowserLayout/LexborCSSFrontend.swift`
- Create: `Tests/iOS/yuedu appTests/LexborCSSFrontendSyntheticTests.swift`

- [ ] **Step 1: Write failing DOM/selector/cascade tests**

Cover tag/class/id/attribute, descendant/child/adjacent/general sibling, `:not()`, `:is()`, `:nth-child()`, specificity, duplicate declarations, source order, inline, `!important`, invalid selector, and invalid declaration. Assert stable semantic path and winning source.

- [ ] **Step 2: Add callback-only C snapshot API**

```c
typedef struct { const uint8_t *bytes; size_t length; } YLXBytes;
typedef struct {
    uint64_t node_id;
    uint64_t parent_node_id;
    uint32_t sibling_ordinal;
    YLXBytes namespace_name;
    YLXBytes tag_name;
} YLXElementSnapshot;
typedef struct {
    YLXBytes property;
    YLXBytes value;
    YLXBytes selector;
    uint32_t specificity;
    uint32_t source_order;
    uint8_t origin;
    uint8_t important;
} YLXWinningDeclaration;

typedef int (*YLXElementCallback)(const YLXElementSnapshot *, void *);
typedef int (*YLXAttributeCallback)(uint64_t, YLXBytes, YLXBytes, void *);
typedef int (*YLXTextCallback)(uint64_t, YLXBytes, void *);
typedef int (*YLXDeclarationCallback)(uint64_t, const YLXWinningDeclaration *, void *);

YLXStatus ylx_document_attach_stylesheet(
    YLXDocument *, const uint8_t *, size_t, uint32_t source_order
);
YLXStatus ylx_document_walk(
    const YLXDocument *, YLXElementCallback, YLXAttributeCallback,
    YLXTextCallback, void *
);
YLXStatus ylx_document_walk_winning_declarations(
    const YLXDocument *, YLXDeclarationCallback, void *
);
```

The first stylesheet operation initializes Lexbor style after DOM parsing, traverses authored `style=""` attributes and parses each as inline origin, then parses/attaches active typed sheets in ascending source order. Because style was disabled during HTML parse, inline `<style>` elements were not auto-attached; their processed text arrives exactly once through `AuthorStylesheet`. Enumerate Lexbor winning declarations and serialize only winning values; Swift does not reparse selectors/replay cascade.

- [ ] **Step 3: Copy every callback span into Swift values**

`LexborHTMLSemanticAdapter` converts `YLXBytes` to `String` inside callbacks. `LexborCSSFrontend` performs bridge calls inside `owner.withDocument`; result has no C pointer/enum/struct.

Define the Swift snapshots consumed by the adapter/scanner:

```swift
struct StyleSourceIdentity: Hashable, Codable {
    enum Origin: String, Codable { case authorStylesheet, inlineStyle }
    let origin: Origin
    let stylesheet: StylesheetIdentity?
    let selector: String?
    let specificity: UInt32
    let sourceOrder: Int
    let important: Bool
}

struct FrontendWinningDeclaration: Equatable {
    let property: String
    let value: String
    let source: StyleSourceIdentity
}

enum FrontendDOMFeature: String, Hashable {
    case table, mathML, scriptedInteractive, unsupportedSVG
}

struct FrontendUnsupportedDeclaration: Equatable {
    let semanticPath: String
    let property: String
    let value: String
    let source: StyleSourceIdentity
    let feature: UnsupportedFeature
}

struct FrontendCapabilityFacts: Equatable {
    var unsupportedDeclarations: [FrontendUnsupportedDeclaration] = []
    var domFeatures: Set<FrontendDOMFeature> = []
    var ingestionFailures: [StylesheetIdentity] = []
}
```

- [ ] **Step 4: Reuse presentational hint extractor**

```swift
let semantic = HTMLSemanticElement(
    tagName: snapshot.tagName,
    attributes: snapshot.attributes
)
let hints = HTMLPresentationalHintExtractor.extract(from: semantic)
```

Prove `<img width="15%">` is `.percent(0.15)`, author 40% wins, inline 30% wins, and `!important` wins.

- [ ] **Step 5: Run package and initial synthetic tests**

```bash
swift test --package-path Packages/CLexbor
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests'
```

Expected: PASS.

- [ ] **Step 6: Commit bridge/frontend**

Stage the five implementation/test paths listed above and commit:

```bash
git commit -m "feat(browser-layout): add Lexbor DOM and cascade frontend"
```

## Task 7: Complete centralized ComputedStyle mapping

**Files:**
- Create: `Modules/Core/ReaderCore/BrowserLayout/LexborComputedStyleAdapter.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/LexborCSSFrontend.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift`
- Modify: `Tests/iOS/yuedu appTests/LexborCSSFrontendSyntheticTests.swift`
- Create: `Tests/iOS/yuedu appTests/LexborComputedStyleCoverageTests.swift`

- [ ] **Step 1: Write failing coverage table**

```swift
let requiredProperties: Set<String> = [
    "display", "visibility", "float", "clear",
    "font-family", "font-size", "font-style", "font-weight", "line-height",
    "color", "background-color", "background-image", "background-size",
    "background-position", "background-repeat", "background-attachment",
    "white-space", "text-align", "text-indent",
    "width", "height", "min-width", "max-width", "min-height", "max-height",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
    "border-color", "border-radius", "ruby-align", "ruby-position", "ruby-merge"
]
#expect(LexborComputedStyleAdapter.coveredProperties == requiredProperties)
```

Properties lacking a current `ComputedStyle` field must enter `FrontendCapabilityFacts` and scanner fallback, not disappear.

- [ ] **Step 2: Verify adapter tests fail**

Run coverage and synthetic classes; expected FAIL until adapter exists.

- [ ] **Step 3: Implement one property-specific mapping point**

```swift
enum LexborComputedStyleAdapter {
    static let coveredProperties: Set<String> = [
        "display", "visibility", "float", "clear",
        "font-family", "font-size", "font-style", "font-weight", "line-height",
        "color", "background-color", "background-image", "background-size",
        "background-position", "background-repeat", "background-attachment",
        "white-space", "text-align", "text-indent",
        "width", "height", "min-width", "max-width", "min-height", "max-height",
        "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
        "border-color", "border-radius", "ruby-align", "ruby-position", "ruby-merge"
    ]

    static func apply(
        _ declaration: FrontendWinningDeclaration,
        to style: inout ComputedStyle,
        parent: ComputedStyle,
        config: BrowserLayoutConfig,
        facts: inout FrontendCapabilityFacts
    ) {
        switch declaration.property {
        case "display": applyDisplay(declaration, to: &style, facts: &facts)
        case "font-size": applyFontSize(declaration, to: &style, parent: parent, config: config)
        case "width": applyLength(declaration, to: &style.width, facts: &facts)
        default: facts.recordAdapterGap(declaration)
        }
    }
}
```

Expand the switch with one explicit branch for every asserted property. Preserve `px/em/rem/%/auto` in `CSSLength`; preserve URL case; implement CSS-wide `inherit/initial/unset`.

- [ ] **Step 4: Apply values in the existing computed-style order**

```text
parent inheritance
→ UserAgentStyle
→ rt UA font adjustment
→ HTMLPresentationalHintExtractor
→ Lexbor winning author/inline declarations
→ finalize line-height and border lengths
```

- [ ] **Step 5: Add shorthands/unit/inheritance/string/URL cases**

Cover margin/padding/border/font/background shorthands, em/rem/percentage, text-indent, float/clear, escaped identifiers, comments, strings, and URLs.

- [ ] **Step 6: Run coverage and existing property regressions**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborComputedStyleCoverageTests' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests' \
  -only-testing:'yuedu appTests/BrowserLayoutFloatStyleTests' \
  -only-testing:'yuedu appTests/BrowserLayoutTextIndentTests' \
  -only-testing:'yuedu appTests/HTMLPresentationalHintProductionEPUBTests'
```

Expected: PASS.

- [ ] **Step 7: Commit adapter coverage**

Stage the adapter, frontend/models, and two test files; commit:

```bash
git commit -m "feat(browser-layout): map Lexbor cascade to ComputedStyle"
```

## Task 8: Share one evaluation with scanner/layout

**Files:**
- Create: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutCSSFrontendFactory.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/CSSFrontendModels.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutCapabilityScanner.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutDocument.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutSession.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutResourceProviding.swift`
- Modify: `Modules/Core/ReaderCore/BrowserLayout/EPUBBrowserLayoutResourceAdapter.swift`
- Modify: `Tests/iOS/yuedu appTests/BrowserLayoutCapabilityScannerTests.swift`
- Create: `Tests/iOS/yuedu appTests/BrowserLayoutFrontendAdmissionTests.swift`

- [ ] **Step 1: Write failing one-evaluation/scanner tests**

A counting frontend must observe exactly one build per `(layoutGeneration, spineIndex)`. Add unsupported facts for table, positioned, flex/grid, vertical writing, media/functions, MathML, complex SVG, scripts, unsupported ruby/text-indent/float, and adapter gaps; assert whole-chapter fallback.

- [ ] **Step 2: Define pointer-free facts/result**

```swift
struct CSSFrontendResult {
    let rootNode: ComputedStyleNode
    let linkAnchors: [Int: LinkAnchorInfo]
    let footnotes: [String: String]
    let imageSources: Set<String>
    let nodeCount: Int
    let capabilityFacts: FrontendCapabilityFacts
    let diagnostics: [CSSFrontendDiagnostic]
}

struct FrontendCapabilityFacts: Equatable {
    var unsupportedDeclarations: [FrontendUnsupportedDeclaration]
    var domFeatures: Set<FrontendDOMFeature>
    var ingestionFailures: [StylesheetIdentity]
}
```

- [ ] **Step 3: Make scanner consume the result**

```swift
static func scan(
    _ result: CSSFrontendResult,
    writingMode: ReaderWritingMode
) -> BrowserLayoutCapabilityResult
```

The old `scan(html:cssTexts:)` remains test compatibility and delegates through Current. Production scanner invokes neither parser nor DOM library.

- [ ] **Step 4: Cache result between decision/session**

`BrowserLayoutPageEngine` stores results by spine inside one generation. `decideEngine` evaluates/scans once; `layoutBrowserChapter` transfers the value result into `BrowserLayoutSession`. Generation change/eviction releases it.

Change resource prefetch to `prefetchImages(forChapter:sources:renderWidth:)`, using `CSSFrontendResult.imageSources`; the EPUB adapter no longer parses chapter DOM with SwiftSoup merely to rediscover `<img>`/SVG sources. Root background loading remains driven by the computed root style.

- [ ] **Step 5: Add factory with Current default**

```swift
enum BrowserLayoutCSSFrontendMode: String { case current, lexbor }

enum BrowserLayoutCSSFrontendFactory {
    #if DEBUG
    static var mode: BrowserLayoutCSSFrontendMode = .current
    #else
    static let mode: BrowserLayoutCSSFrontendMode = .current
    #endif

    static func make(_ override: BrowserLayoutCSSFrontendMode? = nil) -> CSSFrontend {
        switch override ?? mode {
        case .current: CurrentCSSFrontend()
        case .lexbor: LexborCSSFrontend()
        }
    }
}
```

- [ ] **Step 6: Run admission/session/engine tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/BrowserLayoutFrontendAdmissionTests' \
  -only-testing:'yuedu appTests/BrowserLayoutCapabilityScannerTests' \
  -only-testing:'yuedu appTests/BrowserLayoutSessionTests' \
  -only-testing:'yuedu appTests/BrowserLayoutPageEngineTests'
```

Expected: one evaluation and no unsupported admission.

- [ ] **Step 7: Commit orchestration/scanner**

Stage exact listed paths and commit:

```bash
git commit -m "refactor(browser-layout): share frontend evaluation with scanner"
```

## Task 9: Add DEBUG Current/Lexbor switch

**Files:**
- Modify: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutFeature.swift`
- Modify: `Modules/Features/Reader/ReaderDebugLayoutAB.swift`
- Modify: `Modules/Features/Reader/ReaderView+DebugLayoutAB.swift`
- Modify: `Modules/Core/ReaderCore/EPUBPageRenderer.swift`
- Modify: `Resources/{zh-Hant,zh-Hans,en}.lproj/Localizable.strings`
- Create: `Tests/iOS/yuedu appTests/BrowserLayoutFrontendDebugSwitchTests.swift`

- [ ] **Step 1: Write failing default/reload tests**

Assert Current default, explicit Lexbor selection, effective label, and reload preservation of `(spineIndex,charOffset)`, viewport, font, font size, line height, and page margins.

- [ ] **Step 2: Add frontend state beside engine A/B**

```swift
enum ReaderDebugCSSFrontend: String, CaseIterable, Identifiable {
    case current
    case lexbor
    var id: Self { self }
}
```

Show effective engine and frontend. Switching frontend keeps `browserForced`, captures current reading position, changes only frontend mode, and uses existing stable-position reload.

- [ ] **Step 3: Localize all labels**

Add `"CSS Frontend"`, `"Current"`, and `"Lexbor"` to all three localization files through `localized(...)`.

- [ ] **Step 4: Run switch/A-B regressions**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/BrowserLayoutFrontendDebugSwitchTests' \
  -only-testing:'yuedu appTests/BrowserLayoutABHarnessTests'
```

Expected: PASS; production remains Current.

- [ ] **Step 5: Commit DEBUG switch**

Stage only the four Swift files, three localization files, and test; commit:

```bash
git commit -m "feat(reader): add Current and Lexbor frontend debug switch"
```

## Task 10: Exhaustive synthetic differential

**Files:**
- Create: `Tests/iOS/yuedu appTests/LexborCSSFrontendDifferentialSupport.swift`
- Modify: `Tests/iOS/yuedu appTests/LexborCSSFrontendSyntheticTests.swift`
- Create: `docs/browser-layout/lexbor-migration/synthetic-differential.json`
- Create: `docs/browser-layout/lexbor-migration/standards-corrections.md`

- [ ] **Step 1: Define classifications/fingerprints**

```swift
enum CSSFrontendDifferenceClassification: String, Codable {
    case identical = "IDENTICAL"
    case semanticallyEquivalent = "SEMANTICALLY_EQUIVALENT"
    case lexborSpecCorrection = "LEXBOR_SPEC_CORRECTION"
    case currentSpecCorrect = "CURRENT_SPEC_CORRECT"
    case lexborIntegrationBug = "LEXBOR_INTEGRATION_BUG"
    case adapterGap = "ADAPTER_GAP"
}

struct ComputedStyleFingerprint: Codable, Equatable {
    let semanticPath: String
    let fields: [String: String]
    let winners: [String: StyleSourceIdentity]
}
```

Colors use fixed RGBA bytes; numbers use locale-independent fixed decimals; sets/maps sort.

- [ ] **Step 2: Add complete specification fixture matrix**

Every requested selector, cascade, invalid recovery, shorthand, inheritance, font/unit, width, float/clear, text-indent, hints, comments, escaped identifier, string, and URL case contains HTML, typed sheets, expected Current/Lexbor values, classification, and standards source when different.

- [ ] **Step 3: Fail unsafe classifications**

Fail on unclassified, `LEXBOR_INTEGRATION_BUG`, `ADAPTER_GAP`, or `CURRENT_SPEC_CORRECT`.

- [ ] **Step 4: Run twice and byte-compare**

```bash
YUEDU_LEXBOR_SYNTHETIC_OUTPUT=/tmp/lexbor-synthetic-1.json xcodebuild test \
  -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests'
YUEDU_LEXBOR_SYNTHETIC_OUTPUT=/tmp/lexbor-synthetic-2.json xcodebuild test \
  -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests'
cmp /tmp/lexbor-synthetic-1.json /tmp/lexbor-synthetic-2.json
```

Expected: PASS and byte identity.

- [ ] **Step 5: Commit verified evidence**

Copy run 1 to the docs path, document each correction with rule/Current/Lexbor/spec result, stage tests/evidence, and commit:

```bash
git commit -m "test(browser-layout): classify Lexbor synthetic differences"
```

## Task 11: Complete 23-book style differential

**Files:**
- Create: `Tests/iOS/yuedu appTests/LexborCSSFrontendCorpusTests.swift`
- Create: `docs/browser-layout/lexbor-migration/style-differential-summary.json`
- Create: `docs/browser-layout/lexbor-migration/style-differences.ndjson`

- [ ] **Step 1: Build corpus harness**

Reuse Phase 4C discovery and `PublicationSession`. For every chapter build one typed input, evaluate Current/Lexbor, pair nodes by semantic path, and compare identity, complete style, inheritance, winning source, hints, diagnostics, and scanner result.

- [ ] **Step 2: Bound artifacts while preserving provenance**

Summary records 23 EPUB, 7,350 chapters, total elements, classification counts, scanner counts, ingestion failures, and NDJSON hash. NDJSON stores every non-identical element/property difference and no book text.

- [ ] **Step 3: Run corpus twice**

```bash
YUEDU_LEXBOR_STYLE_OUTPUT=/tmp/lexbor-style-1 xcodebuild test \
  -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendCorpusTests'
YUEDU_LEXBOR_STYLE_OUTPUT=/tmp/lexbor-style-2 xcodebuild test \
  -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendCorpusTests'
diff -ru /tmp/lexbor-style-1 /tmp/lexbor-style-2
```

Expected: 23/7,350 twice, byte-identical, no unsafe/unclassified difference.

- [ ] **Step 4: Commit harness/evidence**

Copy verified summary/NDJSON, run `git diff --cached --check`, and commit:

```bash
git commit -m "test(browser-layout): classify full Lexbor style corpus"
```

## Task 12: Prove geometry, lifetime, performance, and build gates

**Files:**
- Create: `Tests/iOS/yuedu appTests/LexborBrowserLayoutDifferentialTests.swift`
- Modify: `Tests/iOS/yuedu appTests/LexborCSSFrontendLifetimeTests.swift`
- Create: `Tests/iOS/yuedu appTests/LexborCSSFrontendPerformanceTests.swift`
- Create: `docs/browser-layout/lexbor-migration/layout-differential-summary.json`
- Create: `docs/browser-layout/lexbor-migration/performance-memory.json`
- Create: `docs/browser-layout/lexbor-migration/build-matrix.json`

- [ ] **Step 1: Implement exact layout fingerprints**

```swift
struct BrowserLayoutFrontendGeometryFingerprint: Codable, Equatable {
    let scannerDecision: String
    let pageCount: Int
    let logicalLineCount: Int
    let lineSourceRanges: [String]
    let pageSourceRanges: [String]
    let fragmentCount: Int
    let geometrySHA256: String
}
```

For identical/equivalent chapters, feed each result to the same existing BrowserLayout and require exact equality. Never record a new layout golden.

For each `LEXBOR_SPEC_CORRECTION`, require the Task 10 synthetic fixture/spec citation and record the resulting chapter-level geometry fields as attributed differences. A correction without that provenance fails the suite.

- [ ] **Step 2: Run layout corpus twice**

Run `LexborBrowserLayoutDifferentialTests` twice to `/tmp/lexbor-layout-1.json` and `-2.json`, then `cmp`. Expected: exact decisions/pages/lines/ranges/fragments/geometry and byte identity.

- [ ] **Step 3: Expand lifetime/cancellation tests**

Cover every C failure stage, snapshot-boundary cancellation, repeated open/close, and all chapters sequentially. After batches, C/Swift live-owner counters are zero.

- [ ] **Step 4: Run normal and ASan lifetime tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendLifetimeTests'
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -enableAddressSanitizer YES \
  -only-testing:'yuedu appTests/LexborCSSFrontendLifetimeTests'
```

Expected: PASS, no leak/use-after-free, counters zero.

- [ ] **Step 5: Measure Current/Lexbor performance**

Run both frontends on identical synthetic/corpus input. Record medians/sample count for HTML parse, CSS parse, style tree, total frontend, initialization, peak physical footprint, and sequential-chapter footprint.

```bash
YUEDU_LEXBOR_PERF_OUTPUT=/tmp/lexbor-performance-memory.json xcodebuild test \
  -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendPerformanceTests' \
  -only-testing:'yuedu appTests/BrowserLayoutPerfTests'
```

- [ ] **Step 6: Run build matrix with upstream checkout unavailable**

```bash
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Yuedu-Reader-Lexbor.xcarchive CODE_SIGNING_ALLOWED=NO
```

Expected: simulator/device Debug, device Release, and archive/link PASS without generation/download.

- [ ] **Step 7: Record post-integration size/build deltas**

Repeat Task 1 commands under identical settings. Record absolute/delta values and whether a physical-device Debug launch/parse was completed.

- [ ] **Step 8: Run focused regression/determinism**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests' \
  -only-testing:'yuedu appTests/LexborComputedStyleCoverageTests' \
  -only-testing:'yuedu appTests/BrowserLayoutCapabilityScannerTests' \
  -only-testing:'yuedu appTests/HTMLPresentationalHintProductionEPUBTests' \
  -only-testing:'yuedu appTests/BrowserLayoutFloatLayoutTests' \
  -only-testing:'yuedu appTests/BrowserLayoutRubyLayoutTests' \
  -only-testing:'yuedu appTests/BrowserLayoutTextIndentTests' \
  -only-testing:'yuedu appTests/BrowserLayoutSelectionContractTests' \
  -only-testing:'yuedu appTests/BrowserLayoutSourceMappingTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests' \
  -only-testing:'yuedu appTests/BrowserLayoutDeterminismTests'
```

Expected: PASS; no golden regeneration.

- [ ] **Step 9: Commit tests/evidence**

Stage three test files and three evidence files; commit:

```bash
git commit -m "test(browser-layout): verify Lexbor production gates"
```

## Task 13: Make/document the cutover decision

**Files:**
- Modify only on YES: `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutCSSFrontendFactory.swift`
- Create: `docs/browser-layout/lexbor-migration/cutover-report.md`

- [ ] **Step 1: Evaluate all gates**

Mark PASS/FAIL for build matrix, synthetic classifications, style corpus, equivalent geometry, unexplained style/layout differences, scanner safety, hints, lifetime/ASan, focused regression, determinism, `git diff --check`, and absence of book/class/src/spine special cases.

- [ ] **Step 2: Apply the only permitted YES change**

Only if all PASS:

```swift
#if DEBUG
static var mode: BrowserLayoutCSSFrontendMode = .lexbor
#else
static let mode: BrowserLayoutCSSFrontendMode = .lexbor
#endif
```

Keep Current/Legacy and DEBUG switch. On any failure leave `.current` and record exact blockers.

- [ ] **Step 3: Final verification**

```bash
git diff --check
bash scripts/verify_vendored_lexbor.sh
swift test --package-path Packages/CLexbor
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,id=D787D0F2-DD88-475A-9BC2-D4484B706011' \
  -only-testing:'yuedu appTests/LexborCSSFrontendSyntheticTests' \
  -only-testing:'yuedu appTests/BrowserLayoutCapabilityScannerTests' \
  -only-testing:'yuedu appTests/HTMLPresentationalHintProductionEPUBTests' \
  -only-testing:'yuedu appTests/BrowserLayoutLineBreakBaselineTests' \
  -only-testing:'yuedu appTests/BrowserLayoutDeterminismTests'
```

A YES requires real Debug device launch/parse evidence; missing it means NO.

- [ ] **Step 4: Commit report and optional one-line cutover**

YES:

```bash
git add Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutCSSFrontendFactory.swift \
  docs/browser-layout/lexbor-migration/cutover-report.md
git commit -m "feat(browser-layout): cut production frontend to Lexbor"
```

NO:

```bash
git add docs/browser-layout/lexbor-migration/cutover-report.md
git commit -m "docs(browser-layout): record Lexbor cutover blockers"
```

- [ ] **Step 5: Report only requested fields**

Report Lexbor version/integration, binary size, DOM adapter, stylesheet ingestion, presentational hints, ComputedStyle coverage, synthetic differential, 23-book style differential, standards corrections, scanner changes, geometry differential, performance/memory, focused regression, determinism, and `production cutover: YES/NO`. Include cutover hash only on YES and only blockers on NO.
