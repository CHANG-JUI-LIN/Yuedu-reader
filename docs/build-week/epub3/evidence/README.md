# EPUB 3 Build Week evidence contract

Every compatibility fix claimed as `build-week-fixed` must have one committed
evidence package in this directory. Evidence package IDs are stable and match
`BW-EPUB3-[0-9]{3}`; never reuse an ID for a different failure family.

The compatibility matrix must link the same ID from both its `Issue` and
`Evidence` cells, name the regression test, and record the fix commit. The
package directory contains exactly the durable review evidence:

```text
evidence/BW-EPUB3-001/
├── README.md
├── before.png
└── after.png
```

Raw `.xcresult` bundles, downloaded official EPUB files, extracted resources,
and intermediate screenshots remain under the ignored `.build-week/` tree.
Only the selected before/after pair is committed. Prefer a synthetic
`EPUBTestFixtures` book in tests; never copy an official sample binary into Git.

## Capture rules

- Capture before from `build-week-baseline` (`dd62d80`) and after from the
  recorded fix commit.
- Use the same simulator model, iOS version, reader settings, page or scroll
  mode, viewport, orientation, chapter, and zoom/crop for both images.
- Show the smallest checkpoint that proves the change while retaining enough
  surrounding UI to identify the product state.
- Do not enhance, retouch, or reconstruct rendered book content. Cropping and
  lossless format conversion are allowed when applied equally to both images.
- If an image shows official sample content, retain the sample's license and
  attribution from `sample-manifest.json` in the package README.
- If a feature remains unsupported, the evidence must show the safe fallback:
  no crash, no lost body text, and preserved `alt` or static fallback content.

## Package README template

Keep the following field labels exact because `matrix-check` validates them.
Use a full 64-character manifest SHA-256. `Official content visible` accepts
only `yes` or `no`; `License attribution` is mandatory when it is `yes`.

```markdown
# BW-EPUB3-001 — Short failure-family title

- Sample/checkpoint: sample-id / chapter, target, or interaction
- Sample checksum: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 0123456789abcdef0123456789abcdef01234567
- Fixture: `EPUBTestFixtures+Feature.swift` / fixture function
- Test command: `xcodebuild test ... -only-testing:'yuedu appTests/TestName'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, defaults
- Expected behavior: What the checkpoint must visibly or programmatically do.
- Observed behavior: What changed between before and after.
- Official content visible: yes
- License attribution: License and attribution copied from `sample-manifest.json`.
```

Validate manifest coverage, matrix outcomes, and every linked evidence package:

```bash
python3 scripts/epub3_samples.py matrix-check
```

An evidence package documents one verified improvement; it does not imply full
EPUB 3 support or support for every feature used by the official sample.
