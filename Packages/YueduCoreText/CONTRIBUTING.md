# Contributing to YueduCoreText

Thanks for helping improve native long-form reading on Apple platforms.

## Development requirements

- Xcode 16 or later
- Swift 6
- An iOS 17 or later Simulator

Run the standalone test suite before opening a pull request:

```bash
xcodebuild test \
  -scheme YueduCoreText \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -parallel-testing-enabled NO
```

Changes to vertical typography must preserve UTF-16 offsets. Performance
changes need reproducible before/after measurements, including the Xcode
version, build configuration, device, corpus, median, and p95. Do not include
copyrighted books, application secrets, or private test documents in issues or
fixtures.

## Dependency boundary

The typography target may import Apple frameworks only. Readium, SwiftSoup,
WebKit, Firebase, app settings, networking, persistence, and app logging belong
in consumer adapters. The boundary test rejects these dependencies.

## Contributions and releases

By submitting a contribution, you agree to license it under MPL-2.0 and confirm
that you have the right to do so. Releases follow semantic versioning. During
the 0.x series, a minor version may contain API changes; migration notes are
required for any public API change.
