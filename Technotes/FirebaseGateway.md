# Firebase Gateway (China relay) — audit & design

Status: **code complete, not deployed, not validated on a mainland-China
network.** See the end for the exact status split.

## 1. Audit: actual Firebase dependencies

| Feature / entry | Service | Enabled today | Blocks sign-in / core account? | Decision |
| --- | --- | --- | --- | --- |
| Email sign-in / sign-up — `FirebaseAuthManager.signInWithEmail/signUpWithEmail`, `LoginView` | Firebase Auth SDK → identitytoolkit | Yes | Yes (direct path) | Gateway via `accounts:signInWithPassword` / `accounts:signUp` |
| Apple sign-in — `signInWithApple`, `prepareAppleRequest` | ASAuthorization + Firebase Auth `signIn(with: OAuthProvider.appleCredential)` | Yes | Yes | Keep native Apple sheet; credential exchange via `accounts:signInWithIdp` (nonce + fullName preserved) |
| Google sign-in — `signInWithGoogle`, `GIDSignIn` | GoogleSignIn SDK + Firebase Auth | Yes | Yes | Keep GIDSignIn (the Google authorization page itself may still be unreachable; documented, not fixed); credential exchange via Gateway |
| Token refresh / relaunch restore | Firebase Auth SDK internal | Yes | Yes | Gateway refresh token in Keychain + `securetoken` refresh |
| Link / unlink / switch account — `UserDetailView`, `link(_:with:)`, `unlink` | Firebase Auth SDK | Yes | Yes (account mgmt) | Gateway `accounts:update`, `accounts:signInWithIdp` (link), Admin `providersToUnlink`; recent-auth enforced |
| Re-auth / delete account — `deleteAccount` | Firebase Auth SDK + callable + Firestore + Storage | Yes | Yes | Gateway `/v1/account/delete`, Auth user deleted last, staged job |
| Profile read/write — `FirestoreSyncManager.upsertCurrentProfile` / `pullAll` | Firestore `users/{uid}` | Profile only | Yes (display/prefs) | Gateway `/v1/profile` with field whitelist |
| Avatar — `FirestoreSyncManager.uploadAvatar`, `AccountAvatarView` | Cloud Storage `avatars/{uid}.jpg` | Yes | No (UI only) | Gateway `/v1/avatar` authenticated; old Storage URLs rewritten client-side |
| Subscription account token — `SubscriptionAccountService.accountToken` | Callable `getSubscriptionAccountToken` | Yes | Yes for binding | Gateway proxies the callable (whitelist) |
| Purchase binding — `bind` | Callable `bindSubscriptionPurchase` | Yes | Yes for account Pro | Same proxy; StoreKit verification stays in the function |
| Entitlement query — `refreshEntitlement` | Firestore `entitlements/{uid}` (`.server`) | Yes | Yes for Pro display | Gateway `/v1/subscription/entitlement` (environment-scoped fields) |
| Delete subscription data | Callable `deleteSubscriptionAccountData` | Yes | No | Same proxy |
| TestFlight request — `TestFlightApplyView` | Callable `requestTestFlightAccess` | Yes | No | Same proxy |
| Entitlement drop diagnostics — `SubscriptionStore.reportEntitlementDrop` | Firestore `entitlementDiagnostics` | Fires only on Pro drop | No (best effort) | Left direct; a failed write is already non-fatal |
| Firestore **data** sync (books/sources/RSS/positions) | Firestore | **OFF** (`FirestoreSyncManager.dataSyncEnabled = false`) | No | Untouched — iCloud is the source of truth |
| Crashlytics — `CrashContext`, `MetricKitDiagnosticReporter` | Crashlytics | Yes (non-fatal reporting) | No | Left direct; unreachable crash upload must not block anything |
| App Check | — | **未確認**：repo 內無客戶端整合、callable 無 `enforceAppCheck`，但專案/服務層 enforcement 無法從 repo 判定 | n/a | 部署前必須在 Console 核對並記錄；不得假設已關閉或已開啟，也不得為此變更 production enforcement；若已啟用則列為部署阻塞 |
| Remote Config | — | **Not used anywhere** | n/a | Route selection uses local state only |
| Analytics | — | Not used | n/a | n/a |
| MFA / reCAPTCHA | — | Not configured in client | n/a | Not expanded |
| Forgot password / email action links | — | **No UI exists** | n/a | Not built (no existing requirement) |

## 2. Request paths

Direct (unchanged, overseas):

```
App → Firebase Auth SDK / Firestore / Storage / callable Cloud Functions
```

Gateway (new, for networks where Google endpoints are unreachable):

```
App → HTTPS Gateway (Hong Kong candidate)
        ├─ identitytoolkit.googleapis.com  (email, idp exchange, refresh, account:update, revokeToken)
        ├─ firebase-admin Auth             (verifyIdToken(checkRevoked), link/unlink, deleteUser)
        ├─ firebase-admin Firestore        (users/{uid}, entitlements/{uid}, deletion jobs)
        ├─ firebase-admin Storage          (avatars/{uid}.jpg only)
        └─ whitelisted callables           (custom-token exchange → callable, standard protocol)
```

## 3. Session design

- `AccountUser` is the shared model; `FirebaseAuthManager.accountUser` is the
  single published account state for both routes.
- Direct route: SDK user remains; the SDK auth listener drives state.
- Gateway route: refresh token in Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), cached `AccountUser`
  beside it for offline launch, ID token in memory only.
- While a Gateway session is active, SDK `Auth` state events (including nil) are
  ignored and any leftover SDK session is signed out locally.
- Refresh is single-flight; a transport failure keeps the session and retries
  later; only `unauthenticated` / `user-disabled` / `user-not-found` clears it.
- Sensitive operations (link/unlink/delete) require `auth_time` within 10
  minutes, enforced server-side from the verified token. Deletion re-verifies a
  real credential (password/Apple/Google) before doing anything.

## 4. Compatibility guarantees

- UID, provider identities, Firestore document shape, Storage object path and
  entitlement field semantics are unchanged; nothing is migrated or copied.
- StoreKit `appAccountToken` comes from the same `accountTokens/{uid}` document
  through the same callable.
- Environment separation (`isProActive` vs `sandboxIsProActive`), per-UID
  keychain cache and the "missing document ≠ not Pro" rule are preserved on both
  routes.
- Local books, iCloud/CloudKit, WebDAV, OPDS and reading are untouched; offline
  reading never touches Gateway code.
- Existing SDK sessions are adopted as-is on the direct route; no forced
  re-login.

## 5. Verification performed

- `gateway`: `npm run typecheck`, `npm test` (39 tests) — policy, error mapping,
  body-size mapping, rate limiter, readiness credential/timeout behavior with
  an assertion that no `unhandledRejection` fires, data-plane credentials gate,
  and proxy-trust/XFF spoofing behavior.
- `gateway`: local process smoke test (`npm run smoke`, compiled artifact, dummy
  config, no credentials) — `/healthz` 200, `/readyz` degraded 503 reporting
  `credentials: unavailable`, `/v1` gated 503 before authentication, unknown
  route 404, malformed body 400, auth rate limit 429, server alive, SIGTERM
  shutdown clean. Root-cause fix: the Admin credential is validated at startup
  via `credential.getAccessToken()`; Firestore/Storage are never called while it
  is unavailable, which removes both the SDK's leaked rejection and its
  timer-thrown exception instead of relying on a global listener. An unexpected
  unhandled rejection now logs and shuts down (supervisor restarts);
  `uncaughtException` is not swallowed.
- `gateway`: real-account integration script (`npm run integration:auth`)
  prepared for a deployed gateway (sign-in, refresh, session, profile,
  entitlement; read-only). **未執行** — no credentials/host; it exits 2 with a
  `NOT EXECUTED` marker when the env vars are missing.
- iOS: build succeeded; 21 new unit tests pass (route policy including the
  "no relay entry point" fallback, error classification, profile decoding,
  avatar rewriting, session single-flight / invalidation / offline retention /
  401 retry); account+subscription regression suites pass (56 tests in the
  combined run). No iOS code changed in this deployment-hardening round.
- **Capacity/traffic:** not measured. Sizing and DAU/traffic numbers in
  `gateway/README.md` are explicitly labelled assumptions pending a load test;
  the only real measurements are local smoke-test latencies and contract
  payload sizes.
- **Not executed:** any real client → Gateway → Firebase round trip, staging or
  production deployment, mainland-China-network smoke test, real Apple/Google
  authorization through the Gateway, load test. No Firebase credentials were
  available and no production resources were created.

## 6. Deployment blockers (owner-supplied)

See `gateway/DEPLOYMENT_RUNBOOK.md` for the operational checklist and
`gateway/README.md` → "Sizing, traffic and host requirements" /
"Configuration checklist". Summary:

1. Linux VPS (Hong Kong first test candidate, China-optimized line preferred).
2. HTTPS entry domain + TLS certificate + DNS you control (no Google CNAME).
3. Service account (Auth Admin, Cloud Datastore User, avatar-bucket Storage
   Object Admin).
4. A **dedicated server API key** restricted to **Identity Toolkit API and Token
   Service API** (plus IP restriction if egress IPs are fixed) — do not weaken
   the iOS client key.
5. App Check enforcement state confirmed from the Console; if enabled for any
   used API, deployment is blocked until a supported server approach exists.
6. Build setting `GATEWAY_BASE_URL` for a **dedicated test build only**; release
   builds keep it empty (this is what keeps them on the direct route).
7. Privacy disclosure / host-location confirmation for App Store review.

## 7. Rollback

- Set `authRouteMode` to `直連 Firebase` (direct) in the app and/or ship a build
  with `GATEWAY_BASE_URL` empty. The direct path is untouched.
- Server rollback per `gateway/README.md` (previous container tag).
