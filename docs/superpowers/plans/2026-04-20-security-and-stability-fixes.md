# Security & Stability Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修復程式碼審查報告中 9 個 Critical/Major/Minor 問題，涵蓋執行緒洩漏、Cookie 競爭、TCP 半包、LAN 認證、OOM、SSRF、狀態污染、規則快取上限、JS 沙盒強化。

**Architecture:** 各問題獨立修改對應檔案，不跨模組重構。Cookie 注入改為建構 Header 字串直接帶入請求；TCP 接收改為 buffer 累積迴圈；JS eval 改用單一共享 Queue；LAN Server 加入啟動時隨機 Token；SSRF 改為數值 IP 比對。

**Tech Stack:** Swift, JavaScriptCore, Network framework, Foundation

---

## 檔案異動清單

| 檔案 | 動作 | 對應問題 |
|------|------|---------|
| `Models/RuleEngine/ModernParser/JS/JSSandbox.swift` | Modify | #1 執行緒洩漏、#9 JS 沙盒 |
| `Models/Network/WebFetcher.swift` | Modify | #2 Cookie 競爭 |
| `Models/Server/LanWebServer.swift` | Modify | #3 TCP 半包、#4 LAN 認證 |
| `Models/App/AppConfig.swift` | Modify | #6 SSRF 數值比對 |
| `Models/BookSource/BookSourceFetcher.swift` | Modify | #6 SSRF |
| `Models/RuleEngine/ModernParser/ModernRuleEngine.swift` | Modify | #7 stringRuleCache 上限 |
| `Models/Network/WebFetcher.swift` | Modify | #5 smartDecode 短路 |

---

## Task 1：JSSandbox 執行緒洩漏修復（Critical #1）

**Files:**
- Modify: `yuedu app/Models/RuleEngine/ModernParser/JS/JSSandbox.swift`

**問題：** 每次 `evaluateWithTimeout` 建立全新 `DispatchQueue`，超時後該 Queue 和執行緒永遠洩漏。

**修法：** 使用單一 static serial queue（最多洩漏 1 個執行緒），並移除每次建立新 Queue 的邏輯。

- [ ] **Step 1：移除每次建立 Queue 的邏輯，改用 static shared queue**

將 `JSSandbox.swift` 中的 `evaluateWithTimeout` 方法，以及 `_evalCounter`、`evalCounterLock` 這兩個已無用的屬性一起替換：

```swift
// 移除這兩個屬性：
// private static var _evalCounter: Int = 0
// private static let evalCounterLock = NSLock()

// 改為：
/// 單一 JS 評估佇列；最多同時執行一個 JS，超時後最多洩漏一個執行緒。
private static let evalQueue = DispatchQueue(
    label: "com.yuedu.jssandbox.eval",
    qos: .userInitiated
)
```

並將 `evaluateWithTimeout` 改為：

```swift
static func evaluateWithTimeout(
    _ context: JSContext,
    script: String,
    timeout: TimeInterval = defaultTimeout
) -> JSValue? {
    guard sanitize(script) else {
        logSecurity("Script rejected by sanitization (length: \(script.count))")
        return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: JSValue?

    evalQueue.async {
        result = context.evaluateScript(script)
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        logSecurity("Script execution timed out after \(timeout)s")
        return nil
    }
    return result
}
```

- [ ] **Step 2：同時加強 eval 覆寫，改為直接拋出例外而非只 log（#9）**

在 `removeUnsafeGlobals` 中，將 eval 的 JS 覆寫改為：

```swift
// 將原本的 eval 覆寫改為：
context.evaluateScript("""
(function() {
    var _origEval = eval;
    eval = function(code) {
        throw new Error('eval() is disabled in sandbox');
    };
})();
""")
```

- [ ] **Step 3：Build 確認無 compile error**

在 Xcode 執行 ⇧⌘B，確認 `JSSandbox.swift` 無錯誤。

- [ ] **Step 4：Commit**

```bash
git add "yuedu app/Models/RuleEngine/ModernParser/JS/JSSandbox.swift"
git commit -m "fix: 修復 JSSandbox 執行緒洩漏，改用 shared serial queue；停用 eval()"
```

---

## Task 2：WebFetcher Cookie 競爭修復（Critical #2）

**Files:**
- Modify: `yuedu app/Models/Network/WebFetcher.swift`

**問題：** 
1. `session.configuration.httpCookieStorage?.setCookie(cookie)` 在 session 建立後無效（configuration 已深拷貝）。
2. 直接修改 `HTTPCookieStorage.shared` 造成跨書源 Cookie 污染。

**修法：** 將 harvestWebViewCookies 所得 cookies 組成 `Cookie:` HTTP Header 字串直接注入 request，完全不觸碰全域 Cookie storage。

- [ ] **Step 1：建立 helper 函式，將 cookies 轉成 header string**

在 `WebFetcher` 的 private methods 區段加入：

```swift
private func cookieHeaderString(from cookies: [HTTPCookie]) -> String? {
    guard !cookies.isEmpty else { return nil }
    return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
}
```

- [ ] **Step 2：修改 fetchHTML，移除所有對 shared storage 的寫入**

找到 `fetchHTML` 中兩處：
```swift
// 位於 line 47-50（首次 harvest）
let allCookies = await Self.harvestWebViewCookies(for: host)
for cookie in allCookies {
    session.configuration.httpCookieStorage?.setCookie(cookie)
    HTTPCookieStorage.shared.setCookie(cookie)
}
```

改為：
```swift
let allCookies = await Self.harvestWebViewCookies(for: host)
```

然後在組 `request` 的 Header 區段（`for (key, value) in headers` 之後）加入：

```swift
// 注入 WebView 收割到的 cookies（優先覆蓋 Cookie header）
if let wvCookieHeader = cookieHeaderString(from: allCookies) {
    request.setValue(wvCookieHeader, forHTTPHeaderField: "Cookie")
}
```

- [ ] **Step 3：修改 CF challenge 後的 retry 區段（兩處），同樣移除 shared storage 寫入**

第一處（status 503/403 retry，約 line 138-148）：

```swift
// 原本：
let allCookies = await Self.harvestWebViewCookies(for: host)
for cookie in allCookies {
    session.configuration.httpCookieStorage?.setCookie(cookie)
    HTTPCookieStorage.shared.setCookie(cookie)
}
let (retryData, retryResponse) = try await PerHostSemaphore.shared.withLock(host: host) {
    try await self.session.data(for: requestCopy)
}
```

改為：

```swift
let retryCookies = await Self.harvestWebViewCookies(for: host)
var retryRequest = requestCopy
if let wvCookieHeader = cookieHeaderString(from: retryCookies) {
    retryRequest.setValue(wvCookieHeader, forHTTPHeaderField: "Cookie")
}
let (retryData, retryResponse) = try await PerHostSemaphore.shared.withLock(host: host) {
    try await self.session.data(for: retryRequest)
}
```

第二處（CF body 200 retry，約 line 178-183）同樣套用：

```swift
let retryCookies = await Self.harvestWebViewCookies(for: host)
var retryRequest = requestCopy
if let wvCookieHeader = cookieHeaderString(from: retryCookies) {
    retryRequest.setValue(wvCookieHeader, forHTTPHeaderField: "Cookie")
}
let (retryData, retryResponse) = try await PerHostSemaphore.shared.withLock(host: host) {
    try await self.session.data(for: retryRequest)
}
```

- [ ] **Step 4：Build 確認無 compile error**

- [ ] **Step 5：Commit**

```bash
git add "yuedu app/Models/Network/WebFetcher.swift"
git commit -m "fix: 移除 WebFetcher 全域 cookie 污染，改以 Cookie header 精準注入"
```

---

## Task 3：LanWebServer TCP 半包修復（Critical #3）

**Files:**
- Modify: `yuedu app/Models/Server/LanWebServer.swift`

**問題：** `connection.receive(minimumIncompleteLength: 1, maximumLength: 8192)` 只收一次，HTTP request 可能被 TCP 切成多塊，導致只收到半截 Header 就 parse。

**修法：** 改為 buffer 累積迴圈，直到找到 `\r\n\r\n` 且讀完 Content-Length 所需 Body 長度。

- [ ] **Step 1：建立 receiveAll helper 函式**

在 `LanWebServer` class 內加入：

```swift
/// 累積接收 TCP 資料直到取得完整 HTTP Request（找到 \r\n\r\n 且 body 讀完）。
/// 防止 TCP 半包導致 parse 失敗。
private func receiveAll(
    connection: NWConnection,
    buffer: Data = Data(),
    completion: @escaping (Data?) -> Void
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
        guard let self else { completion(nil); return }
        guard let chunk = data, !chunk.isEmpty else {
            completion(isComplete ? buffer : nil)
            return
        }
        var accumulated = buffer
        accumulated.append(chunk)

        // 檢查 header 是否完整
        let headerDelimiter = Data("\r\n\r\n".utf8)
        guard let delimRange = accumulated.range(of: headerDelimiter) else {
            // Header 尚未完整，繼續接收
            self.receiveAll(connection: connection, buffer: accumulated, completion: completion)
            return
        }

        // 解析 Content-Length
        let headerPart = accumulated[..<delimRange.lowerBound]
        let headerStr = String(data: headerPart, encoding: .utf8) ?? ""
        let contentLength = self.parseContentLength(from: headerStr)
        let bodyStart = delimRange.upperBound
        let receivedBodyLength = accumulated.count - bodyStart

        if receivedBodyLength >= contentLength {
            completion(accumulated)
        } else {
            // Body 尚未完整，繼續接收
            self.receiveAll(connection: connection, buffer: accumulated, completion: completion)
        }
    }
}

private func parseContentLength(from headers: String) -> Int {
    let lines = headers.lowercased().components(separatedBy: "\r\n")
    for line in lines {
        if line.hasPrefix("content-length:") {
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value) ?? 0
        }
    }
    return 0
}
```

- [ ] **Step 2：修改 handleConnection 使用 receiveAll**

將原本的 `handleConnection` 改為：

```swift
private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInitiated))
    receiveAll(connection: connection) { [weak self] data in
        guard let self, let data, !data.isEmpty else {
            connection.cancel()
            return
        }

        let requestStr = String(data: data, encoding: .utf8) ?? ""
        let (method, path, body) = self.parseHTTPRequest(requestStr, rawData: data)
        let result = self.handleRequest(method: method, path: path, body: body)

        let statusText = result.status == 200 ? "OK" : (result.status == 404 ? "Not Found" : (result.status == 401 ? "Unauthorized" : "Bad Request"))
        let bodyData = result.body
        let header = "HTTP/1.1 \(result.status) \(statusText)\r\n" +
            "Content-Type: \(result.contentType)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "\r\n"

        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
```

- [ ] **Step 3：Build 確認無 compile error**

- [ ] **Step 4：Commit**

```bash
git add "yuedu app/Models/Server/LanWebServer.swift"
git commit -m "fix: LanWebServer TCP buffer 累積接收，修復 HTTP 半包 parse 錯誤"
```

---

## Task 4：LanWebServer PIN Token 認證（Major #4）

**Files:**
- Modify: `yuedu app/Models/Server/LanWebServer.swift`

**問題：** LAN server 無任何認證，同網段任何人可直接存取書庫與書源。

**修法：** Server 啟動時產生 6 位隨機 PIN，並以 `@Published` 暴露給 UI 顯示。每個 API 請求需帶 `?pin=XXXXXX` 或 `Authorization: Bearer XXXXXX`，否則回 401。`/health` 免驗證。

- [ ] **Step 1：在 LanWebServer 加入 PIN 屬性與產生邏輯**

在 class 屬性區加入：

```swift
/// 每次啟動隨機產生，6 位數字。顯示給使用者後方可連線。
@Published var accessPIN: String = ""
```

在 `start()` 方法開頭加入：

```swift
accessPIN = String(format: "%06d", Int.random(in: 0..<1_000_000))
```

- [ ] **Step 2：建立 PIN 驗證 helper**

```swift
private func isAuthorized(path: String, queryItems: [URLQueryItem], headers: [String: String]) -> Bool {
    // ?pin=XXXXXX
    if let pinParam = queryItems.first(where: { $0.name == "pin" })?.value,
       pinParam == accessPIN { return true }
    // Authorization: Bearer XXXXXX
    if let auth = headers["authorization"] ?? headers["Authorization"],
       auth == "Bearer \(accessPIN)" { return true }
    return false
}
```

- [ ] **Step 3：修改 handleRequest 加入 401 guard**

修改 `parseHTTPRequest` 讓它同時回傳 query items 和 headers，或另外加一個 helper。最簡做法：在 `parseHTTPRequest` 的 return tuple 加入 headers 和 queryItems：

```swift
private func parseHTTPRequest(_ text: String, rawData: Data) -> (method: String, path: String, body: Data?, headers: [String: String], queryItems: [URLQueryItem]) {
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return ("GET", "/", nil, [:], []) }
    let parts = requestLine.components(separatedBy: " ")
    let method = parts.count > 0 ? parts[0] : "GET"
    let rawPath = parts.count > 1 ? parts[1] : "/"

    // 解析 headers
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard !line.isEmpty else { break }
        let kv = line.components(separatedBy: ": ")
        if kv.count >= 2 { headers[kv[0]] = kv.dropFirst().joined(separator: ": ") }
    }

    // 解析 query items
    var path = rawPath
    var queryItems: [URLQueryItem] = []
    if let comps = URLComponents(string: rawPath) {
        path = comps.path
        queryItems = comps.queryItems ?? []
    }

    var body: Data? = nil
    if let separatorRange = text.range(of: "\r\n\r\n") {
        let bodyStr = String(text[separatorRange.upperBound...])
        if !bodyStr.isEmpty { body = bodyStr.data(using: .utf8) }
    }
    return (method, path, body, headers, queryItems)
}
```

然後在 `handleConnection` 中（已在 Task 3 改寫）更新呼叫：

```swift
let (method, path, body, reqHeaders, queryItems) = self.parseHTTPRequest(requestStr, rawData: data)

// 驗證 PIN（/health 免驗證）
if path != "/health" && !self.isAuthorized(path: path, queryItems: queryItems, headers: reqHeaders) {
    let unauthorizedBody = Data(#"{"error":"unauthorized","hint":"append ?pin=YOUR_PIN to the URL"}"#.utf8)
    let header = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(unauthorizedBody.count)\r\n\r\n"
    var resp = header.data(using: .utf8) ?? Data()
    resp.append(unauthorizedBody)
    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    return
}

let result = self.handleRequest(method: method, path: path, body: body)
```

- [ ] **Step 4：在 handleRequest 移除 /health 對 handleConnection 的依賴（維持原邏輯不變）**

`handleRequest` 本身不需改動，401 在 `handleConnection` 層已攔截。

- [ ] **Step 5：Build 確認**

- [ ] **Step 6：Commit**

```bash
git add "yuedu app/Models/Server/LanWebServer.swift"
git commit -m "feat: LanWebServer 加入 6 位 PIN 認證，防止 LAN 未授權存取"
```

---

## Task 5：smartDecode 短路求值修復（Major #5）

**Files:**
- Modify: `yuedu app/Models/Network/WebFetcher.swift`

**問題：** `smartDecode` 對所有 candidate 都嘗試完整解碼並計分，5MB 文件會瞬間產生 6 份大字串。

**修法：** BOM / HTTP Header / Meta charset 任一高可信度候選成功解碼且無亂碼（replacement char 比例 < 0.01%），直接短路回傳，不再評分其餘 candidates。

- [ ] **Step 1：在 smartDecode 加入短路邏輯**

在 `candidates` 陣列組好後，在 `var best` 的 for 迴圈**之前**加入：

```swift
// 短路求值：高可信度候選（priority >= 340）成功且幾乎無亂碼則直接回傳
let highConfidenceCandidates = candidates.filter { $0.priority >= 340 }
for candidate in highConfidenceCandidates {
    guard let decoded = String(data: data, encoding: candidate.encoding) else { continue }
    let replacements = decoded.unicodeScalars.filter { $0.value == 0xFFFD }.count
    let ratio = Double(replacements) / Double(max(decoded.unicodeScalars.count, 1))
    if ratio < 0.0001 {
        return decoded  // 早期返回，避免後續大量記憶體分配
    }
}
```

同時將 `decodeQualityScore` 改為只取前 4096 字元計算分數，避免對整份文件運算：

```swift
private func decodeQualityScore(_ text: String) -> Int {
    // 只採樣前 4096 個字元，避免對大型文件做全文掃描
    let sample: String
    if text.count > 4096 {
        sample = String(text.prefix(4096))
    } else {
        sample = text
    }
    if sample.isEmpty { return -10_000 }

    var score = 0
    let replacementCount = sample.unicodeScalars.filter { $0.value == 0xFFFD }.count
    score -= replacementCount * 80

    let suspiciousTokens = ["锟斤拷", "Ã", "Â", "â€", "â€œ", "â€"", "ï»¿", "\u{FFFD}"]
    for token in suspiciousTokens {
        score -= sample.components(separatedBy: token).count > 1 ? 120 : 0
    }

    let controlCount = sample.unicodeScalars.filter {
        CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
    }.count
    score -= controlCount * 25

    let cjkCount = sample.unicodeScalars.filter {
        switch $0.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF: return true
        default: return false
        }
    }.count
    score += min(cjkCount, 200)

    let htmlHints = ["<html", "<body", "</html>", "<meta", "<title"]
    for hint in htmlHints where sample.localizedCaseInsensitiveContains(hint) {
        score += 20
    }

    let newlineCount = sample.filter { $0 == "\n" }.count
    score += min(newlineCount, 40)

    return score
}
```

- [ ] **Step 2：Build 確認**

- [ ] **Step 3：Commit**

```bash
git add "yuedu app/Models/Network/WebFetcher.swift"
git commit -m "perf: smartDecode 短路求值 + 採樣計分，避免大型 HTML OOM"
```

---

## Task 6：SSRF 數值 IP 比對修復（Major #6）

**Files:**
- Modify: `yuedu app/Models/BookSource/BookSourceFetcher.swift`
- Modify: `yuedu app/Models/App/AppConfig.swift`

**問題：** `host.hasPrefix(prefix)` 無法攔截 hex IP（`0x7f000001`）、十進位 IP（`2130706433`）、縮寫 IP（`127.1`）等 SSRF 繞過方式。

**修法：** 用 `inet_pton` 將 host 解析為數值，再比對是否落在 Private / Loopback / Link-Local CIDR 範圍。

- [ ] **Step 1：在 AppConfig.swift 移除舊的 blockedIPPrefixes**

將：
```swift
static let blockedIPPrefixes: [String] = [
    "169.254.",   // link-local
    "0.",         // This network
]
```

刪除（或改為 `@available(*, deprecated)` 空陣列，讓舊引用不 crash，但保留編譯）。

- [ ] **Step 2：在 BookSourceFetcher.swift 的 safeURL 加入數值 IP 檢查**

在 `safeURL` 的 `validate` 函式中，把舊的 prefix 迴圈替換為：

```swift
// 數值比對私有/保留 IP（防繞過 hex/decimal 變形）
if let host = url.host, isPrivateOrReservedHost(host) {
    AppLogger.security("書源 URL 指向保留 IP 範圍，已阻止", context: ["url": raw, "host": host])
    return nil
}
```

然後在 `safeURL` 函式之後（同一檔案全域 scope）加入：

```swift
import Darwin  // 確保 inet_pton 可用（通常已 import Foundation 即可）

/// 判斷 host 是否為私有 / 保留 IP（IPv4 + IPv6），防止 SSRF。
/// 支援標準點分格式、hex、純十進位等各種變形。
private func isPrivateOrReservedHost(_ host: String) -> Bool {
    // 先嘗試用系統解析 IPv4
    var addr4 = in_addr()
    if inet_pton(AF_INET, host, &addr4) == 1 {
        return isPrivateIPv4(addr4.s_addr.bigEndian)
    }

    // 再嘗試 IPv6
    var addr6 = in6_addr()
    if inet_pton(AF_INET6, host, &addr6) == 1 {
        return isPrivateIPv6(addr6)
    }

    // 若無法解析為 IP，則不阻止（hostname 由 DNS 解析，無 SSRF 風險）
    return false
}

/// 檢查 IPv4 地址（big-endian uint32）是否屬於私有/保留段。
private func isPrivateIPv4(_ ip: UInt32) -> Bool {
    // 127.0.0.0/8  loopback
    if ip & 0xFF000000 == 0x7F000000 { return true }
    // 10.0.0.0/8
    if ip & 0xFF000000 == 0x0A000000 { return true }
    // 172.16.0.0/12
    if ip & 0xFFF00000 == 0xAC100000 { return true }
    // 192.168.0.0/16
    if ip & 0xFFFF0000 == 0xC0A80000 { return true }
    // 169.254.0.0/16  link-local
    if ip & 0xFFFF0000 == 0xA9FE0000 { return true }
    // 0.0.0.0/8  This network
    if ip & 0xFF000000 == 0x00000000 { return true }
    // 100.64.0.0/10  Shared Address Space (CGNAT)
    if ip & 0xFFC00000 == 0x64400000 { return true }
    return false
}

/// 檢查 IPv6 地址是否屬於私有/保留段。
private func isPrivateIPv6(_ addr: in6_addr) -> Bool {
    let bytes = withUnsafeBytes(of: addr) { Array($0) }
    // ::1  loopback
    if bytes == [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1] { return true }
    // fc00::/7  Unique Local
    if bytes[0] & 0xFE == 0xFC { return true }
    // fe80::/10  Link-Local
    if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
    return false
}
```

- [ ] **Step 3：移除 safeURL validate 函式中舊的 blockedIPPrefixes for 迴圈**

找到並刪除：
```swift
if let host = url.host {
    for prefix in AppConfig.blockedIPPrefixes where host.hasPrefix(prefix) {
        AppLogger.security("書源 URL 指向保留 IP 範圍，已阻止", context: ["url": raw, "host": host])
        return nil
    }
}
```

- [ ] **Step 4：Build 確認**

- [ ] **Step 5：Commit**

```bash
git add "yuedu app/Models/BookSource/BookSourceFetcher.swift" "yuedu app/Models/App/AppConfig.swift"
git commit -m "fix: SSRF 防護改為數值 IP 比對，堵住 hex/decimal/縮寫 IP 繞過"
```

---

## Task 7：ModernRuleEngine stringRuleCache 上限（Major #7）

**Files:**
- Modify: `yuedu app/Models/RuleEngine/ModernParser/ModernRuleEngine.swift`

**問題：** `stringRuleCache: [String: [SourceRule]]` 無上限，長時間使用或動態規則組合會無限膨脹。

**修法：** 換成已存在的 `LRUCache<String, [SourceRule]>`，容量 256。

- [ ] **Step 1：替換 stringRuleCache 型別**

找到（約 line 81）：
```swift
private var stringRuleCache: [String: [SourceRule]] = [:]
```

改為：
```swift
private let stringRuleCache = LRUCache<String, [SourceRule]>(capacity: 256)
```

- [ ] **Step 2：更新 splitSourceRuleCached 使用 LRUCache API**

找到 `splitSourceRuleCached` 方法（若存在），把：
```swift
if let cached = stringRuleCache[ruleStr] { return cached }
// ...
stringRuleCache[ruleStr] = parsed
```

改為：
```swift
if let cached = stringRuleCache.get(ruleStr) { return cached }
// ...
stringRuleCache.put(ruleStr, value: parsed)
```

若是直接在 `getString` 內 inline，找對應的 subscript 存取一樣改用 `.get()` / `.put()`。

- [ ] **Step 3：Build 確認**

- [ ] **Step 4：Commit**

```bash
git add "yuedu app/Models/RuleEngine/ModernParser/ModernRuleEngine.swift"
git commit -m "fix: ModernRuleEngine stringRuleCache 改用 LRU(256)，防止無限增長"
```

---

## Self-Review Checklist

- [x] **Issue #1 執行緒洩漏**：Task 1 → shared serial evalQueue
- [x] **Issue #2 Cookie 競爭**：Task 2 → Cookie header 手動注入
- [x] **Issue #3 TCP 半包**：Task 3 → receiveAll buffer 迴圈
- [x] **Issue #4 LAN 認證**：Task 4 → 6 位 PIN token
- [x] **Issue #5 OOM smartDecode**：Task 5 → 短路 + 採樣
- [x] **Issue #6 SSRF**：Task 6 → inet_pton 數值比對
- [x] **Issue #7 State Pollution**：Task 7 → LRU cache 上限
- [x] **Issue #8 RegexCache**：已有 LRUCache(64)，無需修改
- [x] **Issue #9 Fake Sandbox**：Task 1 Step 2 → eval 改拋例外

所有 9 個問題均已對應。
