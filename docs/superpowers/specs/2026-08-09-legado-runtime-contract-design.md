# Legado Runtime Contract Design

## Goal

Replace Yuedu's source-by-source JavaScript compatibility patching with a local,
contract-driven Legado runtime layer. The runtime must support the provided Qimao
and Shuqi sources through the existing online-reading pipeline without source-name
checks, alternate parsers, retries, or a remote Legado service.

The compatibility boundary is the documented Legado JavaScript API plus the common
JVM types required by real book sources. Arbitrary Java packages are not promised.
When a source invokes an API outside that boundary, Yuedu must report the exact API
and execution stage instead of returning an unexplained empty result.

## Confirmed Root Cause

Legado, Legado with MD3, and Sigma share the same fundamental rule-engine lineage:
Kotlin `AnalyzeRule` / `AnalyzeUrl`, Rhino 1.7.14, and direct access to Android/JVM,
Jsoup, and utility-library objects. Yuedu independently implements the rules in
Swift and executes source JavaScript with JavaScriptCore. Its `java.*`, `source.*`,
HTTP response, and `Packages.*` surfaces are therefore partial compatibility
bridges rather than the original runtime.

The two supplied sources expose different symptoms of the same missing contract:

- Shuqi declares a function parameter named `sourceUrl` and redeclares it with
  `let sourceUrl`. Rhino accepts the source, while JavaScriptCore rejects the whole
  `jsLib` with `SyntaxError: Cannot declare a let variable twice: 'sourceUrl'`.
  Its login code also calls `java.get(url, {}).cookies()`. Legado returns a Jsoup
  `Connection.Response`; Yuedu currently returns a response bridge that exposes
  only `body()` and `url`.
- Qimao calls `Packages.java.lang.String`, `Packages.android.util.Base64`,
  `Packages.java.util.UUID`, `Packages.java.util.Arrays`, and
  `Packages.javax.crypto.*`. Yuedu's current generic `Packages` proxy contains
  selected crypto helpers but not the required Java String, UUID, or Android Base64
  semantics. Request-device parameters and signatures are consequently invalid
  before the real search request is sent.

No production fix may branch on either source's name, URL, domain, or fixture path.

## Scope

### In scope

- A narrowly defined Rhino-to-JavaScriptCore source normalizer.
- A typed Jsoup-compatible HTTP connection response object.
- Common Java/Android interop primitives required by the supplied sources.
- A capability registry that names every supported runtime API.
- Explicit unsupported-API errors with source and pipeline-stage context.
- Deterministic unit and fixture-driven tests using the two unchanged source files.
- Opt-in live end-to-end tests for search, detail, TOC, and first-chapter content.

### Out of scope

- Source-name or domain-specific Swift implementations.
- General-purpose JVM, Android framework, or arbitrary `Packages.*` emulation.
- A remote Android/Legado execution service.
- Import-time rejection based only on static source scanning.
- A second parser, loader, request cache, retry path, or empty-result fallback.
- Changes to reader rendering, source UI, localization, or persistence.
- Committing the supplied Qimao and Shuqi JSON files to the repository.

## Architecture

All source execution remains on the existing shared path:

```text
BookSourceFetcher
  -> BookSourceSession.session(for:)
  -> ModernParserBridge
  -> LegadoRhinoNormalizer
  -> JavaScriptCore
  -> LegadoRuntimeCapabilityRegistry
       -> java.* bridge
       -> source / book / chapter bridges
       -> LegadoConnectionResponse
       -> LegadoJavaInteropRuntime
       -> UnsupportedLegadoAPIError
```

`BookSourceSession` remains the single per-source runtime owner. Search, discovery,
book detail, TOC, content, cache-hit parsing, pagination, and download routes must
all use the same bridge and capability contract.

### LegadoRhinoNormalizer

This component performs syntax normalization before JavaScriptCore compiles source
code. It owns only verified language-semantic differences and has no network,
source-model, or parsing responsibilities.

Required behavior:

- Preserve the existing exact `result` TDZ normalization.
- Preserve the existing bare destructuring-arrow normalization.
- Normalize a function parameter redeclared by `let` or `const` in that function's
  top-level body to Rhino-compatible `var` semantics.
- Never rewrite occurrences inside strings, template literals, regular-expression
  literals, line comments, block comments, nested functions, or longer identifiers.
- Return source-location mapping sufficient to report both the original and
  normalized compile locations.

A scanner/token-based implementation is required for parameter redeclarations.
A broad regular-expression replacement would risk corrupting source code.

### LegadoConnectionResponse

Every response-producing JavaScript API must expose one coherent response type:

- `body()`
- `cookies()`
- `headers()`
- `statusCode()`
- `statusMessage()`
- `url()` and `url`
- `isSuccessful()`

`java.get(url, headers)`, `java.post(...)`, and `java.connect(...)` must construct
this type from the real HTTP response. The one-argument `java.get(key)` variable
store overload remains unchanged. Cookies and headers must come from the received
response, not from a second request or a separate cookie loader.

Java collection-shaped return values must support the Legado/Rhino operations used
by sources, including `get`, `put`, `containsKey`, `keySet`, iteration, `size`, and
stable `toString()` behavior where applicable.

### LegadoJavaInteropRuntime

The first compatibility set contains:

- `java.lang.String` constructors from strings and byte arrays, including ranged
  byte-array decoding.
- `String.getBytes(charset)`.
- UTF-8, ISO-8859-1, UTF-16LE, and UTF-16BE charset semantics.
- `android.util.Base64.encodeToString(bytes, flags)` and `decode(value, flags)` for
  the Legado source flag values used by the supplied rules.
- `java.util.UUID.randomUUID().toString()`.
- `java.util.Arrays.copyOfRange`.
- Existing AES/CBC/PKCS5Padding, key, IV, and byte-array behavior corrected so
  `Cipher.doFinal` returns bytes rather than prematurely decoded text.
- Existing Hutool digest and Base64 shims retained behind the same registry.

The implementation may use Swift/Foundation/CryptoKit internally, but JavaScript
must observe the Legado-compatible types and return shapes.

### LegadoRuntimeCapabilityRegistry

The registry is the authoritative inventory of supported JavaScript runtime APIs.
Runtime installation and unsupported-API reporting must derive from this inventory
instead of comments or source-specific setup calls.

An unknown namespace may be traversed so source libraries can define unused helper
functions, but invoking or constructing an unsupported member must throw
`UnsupportedLegadoAPIError`. Returning `undefined`, `{}`, or an empty string for an
unknown invocation is prohibited because it converts compatibility failures into
bad signatures and empty parsing results.

## Data Flow

1. Import decodes and stores the source normally; it does not reject the source via
   static scanning.
2. The first `BookSourceSession` use loads the source `jsLib` through
   `LegadoRhinoNormalizer`.
3. A compile failure records the original location, normalized location, source,
   and stage, then exits through the existing parsing error path.
4. Runtime calls resolve through the capability registry and typed bridge objects.
5. Supported calls execute locally and return Legado-compatible values.
6. An unsupported call throws at the invocation point with the full API path.
7. `ModernParserBridge` propagates the structured error through the existing
   `BookSourceFetcher` route. It must not turn the failure into an empty list or
   empty chapter.

## Error Model

Structured errors must include:

- Source name and source URL identifier.
- Pipeline stage such as `jsLib`, `searchUrl`, `ruleSearch.bookList`,
  `ruleBookInfo.init`, `ruleToc.chapterList`, or `ruleContent.content`.
- Unsupported API path or JavaScript compile error.
- Original and normalized source locations when available.
- A short script preview that excludes credentials and response content.

Secrets, tokens, cookies, request bodies, decrypted content, and authorization
headers must never be logged. Errors are recorded through `AppLogger` and surfaced
by the existing source-debug/error presentation path. No retry is triggered.

## Testing Strategy

### Rhino normalizer tests

- The supplied Shuqi parameter/`let` redeclaration compiles after normalization.
- Existing `result` TDZ and destructuring-arrow cases remain supported.
- Strings, template literals, regex literals, comments, nested functions, and
  similarly named identifiers are unchanged.
- Compile errors retain usable original/normalized location information.

### Runtime contract tests

- `java.get(url, headers)` exposes body, cookies, headers, status, success, and URL.
- The one-argument variable-store `java.get(key)` remains unchanged.
- Java map/list wrappers implement the promised operations.
- Java String byte encoding and decoding match fixed byte-level vectors for every
  supported charset.
- Android Base64 flag behavior, UUID shape, Arrays ranges, and AES byte output match
  deterministic vectors.
- Traversing an unknown package is non-fatal, but invoking or constructing an
  unsupported API throws an error containing its exact path and stage.

### Full-source fixture tests

Tests load the unchanged files from configurable environment variables, with the
user-provided paths as local defaults:

- `QIMAO_SOURCE_JSON` defaults to
  `/Users/zhangruilin/Desktop/Test document/RULE/七猫四合一本地版（同人）.json`.
- `SHUQI_SOURCE_JSON` defaults to
  `/Users/zhangruilin/Desktop/Test document/RULE/书旗（同人）.json`.

Deterministic tests use injected network responses and verify:

- Both complete `jsLib` values compile under the shared runtime.
- Qimao builds valid device parameters and a non-empty, deterministic request-sign
  shape through Java String, Base64, UUID, Arrays, and crypto primitives.
- Shuqi can obtain a token from `java.get(...).cookies()` and produces its signed
  request URL through the shared response bridge.
- Failures carry stage and API context rather than producing empty results.

Live tests are opt-in and exercise the existing
search -> detail -> TOC -> first chapter flow. They do not replace deterministic
tests because external APIs, credentials, paid content, and site availability are
not controlled by the application.

### Required regression execution

After implementation, the agent must personally run the new focused normalizer,
runtime-contract, and fixture test classes with parallel testing disabled. It must
also run the directly affected existing `ModernParserTests` class or the smallest
relevant existing test selection that covers the changed runtime paths. A failing
relevant test blocks completion and commit.

## Security and Operational Constraints

- All execution stays local to the existing source session and request pipeline.
- The capability registry does not grant filesystem or arbitrary native-class
  access.
- Cryptographic inputs and HTTP credentials stay transient and redacted.
- Unknown APIs fail explicitly instead of receiving permissive proxy objects.
- No performance claim is made without `SourcePerfTrace` before/after evidence.
- Full `jsLib` evaluation must continue to reuse one session per source.

## Acceptance Criteria

- Production code contains no Qimao/Shuqi source-name, URL, or domain branch.
- Both supplied `jsLib` scripts compile through the shared runtime.
- Shuqi can read response cookies and build its signed request.
- Qimao can build valid device parameters and request signatures with local common
  Java interop primitives.
- Unsupported APIs report their exact path and execution stage.
- Empty results remain legitimate only when parsing succeeds and the source data is
  genuinely empty.
- Search, discovery, detail, TOC, content, cache, pagination, and download continue
  through `BookSourceSession` and the existing parsing pipeline.
- Focused and directly affected regression tests pass with no fallback, retry,
  alternate parser, or delayed workaround.
