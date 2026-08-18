# Book Source Guide (书源指南 · 書源指南)

How to import, validate, debug, and fix **Legado-format book sources** in Yuedu. If a source works in Legado but fails here, start with the differences page — most breakages come from the rule-engine differences.

## Pages

| Topic | 简体中文 | 繁體中文 |
| --- | --- | --- |
| **Quick start** — import, five-stage validation, rule debugger | [快速開始](quickstart.zh-Hans.md) | [快速開始](quickstart.zh-Hant.md) |
| **Rule syntax cheat sheet** — modes, accessors, chaining, templates | [规则语法速查](rule-syntax.zh-Hans.md) | [規則語法速查](rule-syntax.zh-Hant.md) |
| **Differences from Legado** — JS API surface, Packages whitelist, regex/JSONPath/XPath | [与 Legado 的差异](legado-differences.zh-Hans.md) | [與 Legado 的差異](legado-differences.zh-Hant.md) |
| **Troubleshooting** — symptom → cause → fix table | [常见症状对照表](troubleshooting.zh-Hans.md) | [常見症狀對照表](troubleshooting.zh-Hant.md) |

## Scope

This guide covers **book sources** (text / audiobook / manga, `bookSourceType` 0/1/2) and their five pipeline stages: search, discover (explore), detail, TOC, content. TTS engine sources, RSS feeds, OPDS catalogs, WebDAV, and replacement rules are separate systems with their own formats and UIs.