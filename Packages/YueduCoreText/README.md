# YueduCoreText

YueduCoreText is an iOS-native Core Text toolkit for long-form reader
typography. Yuedu Reader consumes this directory as a local Swift package, so
the same public API is exercised by a production reader and by standalone
package tests.

The first product, `YueduCoreTextTypography`, contains:

- CJK punctuation compression and smart punctuation;
- vertical CJK normalization and glyph classification;
- per-font vertical punctuation fallback detection;
- explicit Latin hyphenation language tagging;
- a Core Text framesetter factory for unbounded long-form layout.

## Requirements

- iOS 17 or later
- Swift 6
- Xcode 16 or later

## Integration

Add the package in Xcode and link `YueduCoreTextTypography`:

```swift
import YueduCoreTextTypography

let normalized = "(直排)".normalizedForVerticalLayout()
let framesetter = CoreTextFramesetterFactory.make(for: attributedString)
```

## Scope

This package deliberately does not include publication parsing, persistence,
book-source networking, reader settings, logging, or application UI. Document,
layout-session, pagination, and UIKit reader targets will be added only after
the app itself consumes their stable public APIs.

The package performs no networking, storage, analytics, or telemetry. It has no
third-party runtime dependencies.

## API and concurrency

The 0.x releases use semantic versioning, but may refine public APIs between
minor releases. UTF-16 length preservation is a compatibility guarantee for
vertical normalization and smart punctuation APIs because reading positions
are character-offset based.

Create and consume each Core Text framesetter/frame within one layout operation
or queue. The package does not introduce hidden actors, dispatch queues, global
settings, or retry paths.

## Testing

Run the package tests on an iOS Simulator:

```bash
xcodebuild test \
  -scheme YueduCoreText \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -parallel-testing-enabled NO
```

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE). The Yuedu name and branding
are not granted by the source license.
