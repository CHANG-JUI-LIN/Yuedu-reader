# Fanqie Sauce Book Source Compatibility Design

## Goal

Support the provided `🌙 番茄酱` Legado book source through Yuedu's existing online-source pipeline, covering the complete basic reading flow:

1. Search for a book.
2. Load book details.
3. Load the table of contents.
4. Load chapter text.

The fix must improve general Legado compatibility instead of recognizing this source by name or bypassing the shared rule engine.

## Confirmed Root Cause

The chapter failure shown by the user originates inside the source's imported and obfuscated `to.js` helper. The visible error:

```text
undefined is not an object (evaluating 'f[...]')
```

is a downstream virtual-machine failure rather than the actionable cause.

Tracing the helper's request builder shows that it calls two Legado Java bridge APIs that Yuedu does not currently export:

```javascript
java.HMacBase64(content, "HmacSHA256", key)
java.base64DecodeToByteArray(base64)
```

The helper uses them to create the request `Authorization` value. When both APIs are implemented with their expected semantics, the source builds a non-empty authorization header and the signed request succeeds against the source backend. A signed detail request for book ID `7045187140329671720` returned `code: 0` and the expected book metadata, confirming that the source and backend are valid.

The existing `org.jsoup.Jsoup` JavaScript polyfill is therefore insufficient for this source: it solves a separate compatibility surface and does not provide the missing cryptographic bridge operations.

## Scope

### In scope

- Add `HMacBase64` to the shared `LegadoJSBridgeExport` interface and `LegadoJSBridge` implementation.
- Add `base64DecodeToByteArray` to the same shared bridge.
- Support the cryptographic algorithm spellings normally used by Legado rules, including the source's exact `HmacSHA256` spelling.
- Return JavaScript-compatible unsigned byte arrays for decoded Base64 data.
- Add focused bridge tests and a fixture-driven compatibility test for the provided source.
- Verify that the existing `BookSourceSession` path can execute the source's basic flow.

### Out of scope

- Source-name checks or hard-coded handling for `🌙 番茄酱`.
- Reimplementing the source's request protocol in native Swift.
- Adding a second loader, request cache, retry path, or delayed fallback.
- Bundling or rewriting the source's remotely imported obfuscated helper.
- UI, design-token, or localization changes.
- Guarantees for source-specific paid-content actions or image decryption beyond the basic text-reading flow.

## Architecture

The compatibility behavior belongs in the existing shared JavaScript bridge:

```text
BookSourceSession
  -> rule execution
  -> JavaScriptCore
  -> LegadoJSBridge
  -> HMAC/Base64 primitives
  -> AnalyzeUrl
  -> signed source request
```

`LegadoJSBridgeExport` defines the Objective-C-visible method signatures JavaScriptCore can call. `LegadoJSBridge` implements those methods using Foundation and CryptoKit. All existing online-source execution continues through `BookSourceSession.session(for:)`; no alternate network or parser path is introduced.

This placement makes the behavior available to any compatible Legado source that relies on the same APIs and keeps source rules responsible for composing their own headers and request options.

## Bridge API Semantics

### `HMacBase64`

JavaScript signature:

```javascript
java.HMacBase64(content, algorithm, key)
```

Behavior:

- Interpret `content` and `key` as UTF-8 strings.
- Normalize the algorithm name case-insensitively while accepting common spellings with or without punctuation.
- Support `HmacSHA1`, `HmacSHA256`, `HmacSHA384`, and `HmacSHA512`.
- Compute the HMAC using CryptoKit.
- Return the raw authentication code as standard padded Base64.
- On an unsupported algorithm, log a concise compatibility error and return an empty string, matching the bridge's existing non-throwing JavaScript API style.
- Never log the content, key, authentication code, or authorization header.

The provided source specifically requires:

```text
HMAC-SHA256(UTF8(content), UTF8(key)) -> standard Base64
```

### `base64DecodeToByteArray`

JavaScript signature:

```javascript
java.base64DecodeToByteArray(base64)
```

Behavior:

- Decode standard Base64 using Foundation.
- Ignore harmless unknown characters in the same forgiving style as the bridge's existing Base64 helpers.
- Return an array of integer values in the inclusive range `0...255`.
- Return an empty array for invalid input and log only a concise compatibility error.
- Do not convert the decoded bytes to UTF-8 text.

Returning unsigned integers is important because the source uses the result as raw key material rather than as a string.

## Request Flow

For the provided source, the resulting execution is:

1. The source imports its existing `to.js` helper.
2. The helper builds a timestamped HMAC payload.
3. `java.HMacBase64` returns the Base64-encoded HMAC-SHA256 digest.
4. `java.base64DecodeToByteArray` converts that digest into unsigned raw bytes.
5. The helper produces a non-empty `Authorization` value.
6. The existing `AnalyzeUrl` machinery sends the signed request.
7. Existing source rules parse search, detail, table-of-contents, and chapter responses.

No fallback is needed. A missing or unsupported algorithm remains visible through logging and the resulting invalid request instead of being masked by retries.

## Testing Strategy

Implementation follows test-driven development: add the focused tests first, confirm that they describe currently missing behavior, then add the bridge implementation.

### Unit tests

- Assert `HMacBase64` matches a known HMAC-SHA256 test vector.
- Assert algorithm matching is case-insensitive and accepts common Legado spellings.
- Assert each supported HMAC family returns the expected Base64 value.
- Assert an unsupported algorithm returns an empty string.
- Assert `base64DecodeToByteArray` returns the expected unsigned bytes, including values above `127`.
- Assert invalid Base64 returns an empty array.
- Execute representative JavaScript through JavaScriptCore so the exported method names and argument bridging are tested, not only Swift helpers.

### Source compatibility test

Use the provided source JSON as a local test fixture without copying its remotely imported obfuscated script into the repository. The test should:

1. Import the source through the normal source model.
2. Execute its existing request-building rule.
3. Assert that the generated request options contain a non-empty `Authorization` header.
4. Exercise search, detail, table-of-contents, and first-chapter parsing through the existing session path when live-source tests are enabled.

The deterministic header-generation assertion is the primary regression test. Live network assertions remain opt-in because they depend on an external source and backend.

## Verification

Static verification performed by the agent will include:

- Reviewing all changed bridge/export signatures and call sites.
- Confirming no source-name special case or alternate request path was added.
- Running formatting and diff checks.
- Reviewing the new tests against the proven request semantics.

Because project instructions reserve long `xcodebuild` runs for the user, the final handoff will provide targeted commands for:

- The focused JavaScript bridge tests.
- The opt-in `🌙 番茄酱` source compatibility test.

## Security and Operational Considerations

- HMAC keys remain transient values supplied by source JavaScript.
- Logs must never contain source secrets, signed payloads, or authorization values.
- The change does not broaden network access; source requests continue through the existing source-session and URL-analysis layers.
- The fix adds deterministic local primitives only, so no new caching, persistence, concurrency, or retry behavior is introduced.

## Acceptance Criteria

- The provided source no longer fails because `HMacBase64` or `base64DecodeToByteArray` is absent.
- Its request builder produces a non-empty authorization header through the shared bridge.
- Search, detail, table-of-contents, and chapter text use the existing online-source pipeline.
- Focused regression tests cover both JavaScript-exported APIs and their byte-level semantics.
- No source-specific native implementation, fallback loader, retry, or delayed workaround is added.
