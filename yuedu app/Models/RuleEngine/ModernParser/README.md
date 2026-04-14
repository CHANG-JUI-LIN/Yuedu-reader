# ModernParser

A modular, Legado-compatible rule engine for parsing book sources. Coexists with the legacy `RuleEngine` via a feature flag — the legacy path remains the default.

## Feature Flag

```swift
// ParserSettings.swift
ParserSettings.useModernParser = true   // enable modern engine
ParserSettings.useModernParser = false  // use legacy (default)
```

`BookSourceParsingPipeline` checks the flag on every call and routes to `ModernParserBridge` or the legacy `DefaultWebNovelParserService`.

## Architecture

```
BookSourceParsingPipeline
  │
  ├─ [modern]  ModernParserBridge
  │                └─ ModernRuleEngine ──▶ Extractors
  │                └─ JSCoreEngine
  │                └─ BookSourceRuleData
  │
  └─ [legacy]  DefaultWebNovelParserService
                   └─ RuleEngine (enum)
```

## Components

### Core

| File | Purpose |
|------|---------|
| `ModernRuleEngine.swift` | Central orchestrator — splits rules by JS boundaries, routes segments to extractors by mode, manages variable storage |
| `ModernParserBridge.swift` | Adapter between `ModernRuleEngine` and `BookSourceParsingPipeline` interface |
| `RuleAnalyzer.swift` | Rule-string tokenizer (port of Legado `RuleAnalyzer.kt`) — splits by `\|\|`, `&&`, `%%` respecting brackets/quotes |
| `RuleSyntaxParser.swift` | Bracket-aware split utilities for rule operator parsing |
| `SourceRule.swift` | Parsed rule segment: execution mode, regex replacements, `@put` directives, template params |

### Extractors (all implement `RuleExtractor` protocol)

| File | Mode | Dependency |
|------|------|------------|
| `RuleExtractor.swift` | — | Protocol: `canHandle()`, `extractList()`, `extractValue()` |
| `CssExtractor.swift` | CSS | SwiftSoup |
| `XPathExtractor.swift` | XPath | Fuzi |
| `JsonExtractor.swift` | JSONPath | Foundation (pure-Swift JSONPath) |
| `JsoupDefaultExtractor.swift` | Default (JSOUP-like) | SwiftSoup |
| `RegexExtractor.swift` | Regex | Foundation + RegexCache |
| `LegacyFallbackExtractor.swift` | Fallback | Delegates to legacy `RuleEngine` |

### JavaScript

| File | Purpose |
|------|---------|
| `JS/JSCoreEngine.swift` | JavaScriptCore wrapper with Legado-compatible `java.*` bridge |
| `JS/JSSandbox.swift` | Security sandbox — removes unsafe globals, enforces 10 s timeout |
| `JS/LegadoJSBridge.swift` | `java` bridge object: `ajax()`, `put()`, `get()`, crypto utilities |

### URL Handling

| File | Purpose |
|------|---------|
| `URL/AnalyzeUrl.swift` | Parses Legado custom URL format → `URLRequest` (method, body, headers, charset) |
| `URL/CustomUrl.swift` | Separates URL from its JSON option block |

### Variables

| File | Purpose |
|------|---------|
| `Variables/RuleDataInterface.swift` | Protocol for runtime variable storage across rule chains |
| `Variables/RuleData.swift` | Default transient implementation (no persistence) |
| `Variables/BookSourceRuleData.swift` | Adapts `BookSource` (struct) → `RuleDataInterface` (class protocol) |

### Cache

| File | Purpose |
|------|---------|
| `Cache/LRUCache.swift` | Thread-safe generic LRU cache (NSLock) |
| `Cache/RegexCache.swift` | Compiled `NSRegularExpression` cache (capacity: 64) |
| `Cache/SelectorCache.swift` | Parsed JSOUP rule cache (capacity: 32) |
| `Cache/ScriptCache.swift` | Compiled `JSValue` function cache (capacity: 16) |

### Login

| File | Purpose |
|------|---------|
| `Login/LoginManager.swift` | Book-source authentication: login execution, cookie persistence, login-check |
| `Login/LoginUiBuilder.swift` | Builds login forms from Legado `loginUi` JSON, substitutes credentials |

## Dependency Graph

```
ModernRuleEngine
 ├── RuleAnalyzer
 ├── RuleSyntaxParser
 ├── SourceRule
 ├── RuleDataInterface ← BookSourceRuleData / RuleData
 ├── Extractors[]
 │    ├── CssExtractor ──────── SwiftSoup
 │    ├── XPathExtractor ────── Fuzi
 │    ├── JsonExtractor
 │    ├── JsoupDefaultExtractor ─ SwiftSoup, SelectorCache
 │    ├── RegexExtractor ─────── RegexCache
 │    └── LegacyFallbackExtractor ─ legacy RuleEngine
 ├── JSCoreEngine
 │    ├── JSSandbox
 │    ├── LegadoJSBridge
 │    └── ScriptCache
 └── AnalyzeUrl
      └── CustomUrl

LRUCache ← used by RegexCache, SelectorCache, ScriptCache
```

## Naming Conventions

Legacy types that overlap are scoped `private` inside `LegacyParser/`:
- `LegacyRuleMode` (was `RuleMode`)
- `LegacySourceRule` (was `SourceRule`)

ModernParser owns the public names `RuleMode`, `SourceRule`, `RuleExtractor`.
