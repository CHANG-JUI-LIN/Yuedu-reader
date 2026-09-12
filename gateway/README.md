# Yuedu Firebase Gateway

Finite-purpose HTTPS API in front of the **existing** Firebase project. It lets
the Yuedu iOS app sign in and reach account / profile / avatar / subscription
data from networks where `*.googleapis.com` and `*.cloudfunctions.net` are
unreachable, without creating a second account system.

- Existing Firebase UIDs, providers, users, subscriptions and Console remain
  authoritative.
- Email/password and Apple sign-in exchange through Firebase's own Identity
  Toolkit REST API (`accounts:signInWithPassword`, `accounts:signUp`,
  `accounts:signInWithIdp`, `securetoken` refresh). Admin SDK is used for
  token verification and account management, never as a password checker.
- Subscription callables (`getSubscriptionAccountToken`,
  `bindSubscriptionPurchase`, `deleteSubscriptionAccountData`,
  `requestTestFlightAccess`) are called as-is, server-to-server, so entitlement
  logic stays in one place.
- No generic proxy: every route touches a fixed collection, bucket prefix or
  whitelisted function for the **verified** uid.

## API contract (v1)

All bodies are JSON. Errors use
`{"error":{"code":"...","message":"...","details":{...}}}`; HTTP status matches
the code. Protected routes require `Authorization: Bearer <Firebase ID token>`,
verified with `checkRevoked: true` on every request (Console disable/revoke
takes effect on the next call).

Public:

| Route | Body | Result |
| --- | --- | --- |
| `POST /v1/auth/email/signin` | `{email,password}` | session |
| `POST /v1/auth/email/signup` | `{email,password}` | session |
| `POST /v1/auth/idp` | `{provider:"apple"\|"google", idToken, rawNonce?, accessToken?, fullName?}` | session |
| `POST /v1/auth/pending` | `{pendingToken}` | session (switch to the account owning a conflicted credential) |
| `POST /v1/auth/refresh` | `{refreshToken}` | session (upstream `securetoken` refresh) |
| `GET /healthz` | — | liveness |
| `GET /readyz` | — | Firestore + Storage readiness (metadata only) |

Session payload:
`{idToken, refreshToken, expiresIn, user:{uid,email,displayName,photoURL,emailVerified,providerIds,disabled}}`

Protected:

| Route | Body | Result |
| --- | --- | --- |
| `GET /v1/session` | — | `{authenticated,uid}` |
| `GET /v1/account/me` | — | server-authoritative user record |
| `POST /v1/auth/logout` | `{revokeAllDevices?}` | local sign-out; optional global revoke |
| `POST /v1/auth/link/email` | `{email,password}` (recent auth) | `{linked:true}` |
| `POST /v1/auth/link/idp` | `{provider,idToken,rawNonce?,accessToken?}` (recent auth) | `{linked:true}` |
| `POST /v1/auth/unlink` | `{providerId}` (recent auth) | `{unlinked,user}` |
| `POST /v1/account/delete` | `{reauth:{provider,password?/idToken?,rawNonce?,accessToken?,appleAuthorizationCode?}}` | `{deleted,job}` |
| `GET /v1/account/deletion-status` | — | last deletion job stages |
| `GET /v1/profile` | — | `{profile}` or `{profile:null}` |
| `PUT /v1/profile` | `{displayName?,preferences?}` | whitelisted merge |
| `GET /v1/avatar` | — | JPEG bytes for the signed-in uid |
| `PUT /v1/avatar` | JPEG body (`image/jpeg`, ≤ `AVATAR_MAX_BYTES`) | `{photoURL}` |
| `DELETE /v1/avatar` | — | `{deleted:true}` |
| `GET /v1/subscription/entitlement?environment=production\|sandbox` | — | `{exists,...}`; missing document is **never** "not Pro" |
| `GET /v1/subscription/account-token` | — | `{token}` |
| `POST /v1/subscription/bind` | `{signedTransaction}` | entitlement for the transaction environment |
| `DELETE /v1/subscription/account-data` | — | `{deleted:true}` |
| `POST /v1/subscription/testflight-request` | `{email}` | `{alreadySubmitted,status}` |

`recent auth` means the verified ID token's `auth_time` is within 10 minutes.
Sensitive routes return `reauth-required` otherwise; the client re-authenticates
through `/v1/auth/idp` or the email flow and retries.

## Security notes

- The uid used for every read/write comes from the verified token. Client-supplied
  uids, collection names, buckets and function names are ignored or rejected.
- Firestore Admin access bypasses Security Rules, so routes implement equivalent
  ownership: profile documents and avatar objects are only ever touched at
  `users/{uid}` / `avatars/{uid}.jpg`. Profile writes are whitelisted
  (`displayName`, known preference keys); privilege fields are rejected.
- App Check: the repository has no client integration and the callables do not
  declare `enforceAppCheck`, but project/service-level enforcement cannot be
  verified from the repository — status is **unconfirmed**. Read it from the
  Console before deploying; if any used API enforces it, deployment is blocked
  until a supported server-side approach exists. Never fabricate tokens or fail
  open, and never change production enforcement for this work.
- Passwords, provider credentials, ID/refresh tokens and transaction JWTs are
  never logged, stored or echoed. Logs contain request id, route, status and
  latency only.
- Rate limits are per-instance. Run one instance per region or accept
  `instances × limit`; set `TRUST_PROXY_HOPS=1` only for exactly one trusted
  proxy hop (the bundled Caddy/Docker topology), never a blanket trust.
- Account deletion removes subscription rows → Firestore user data → avatar →
  revokes Apple authorization → deletes the Auth user **last**, recording each
  stage in `accountDeletionJobs/{uid}` so a partial failure can be retried.

## Run locally

```bash
cd gateway
npm install
npm run typecheck
npm test
cp .env.example .env   # fill in values
npm run dev
curl -s localhost:8080/healthz
```

## Build and deploy (Hong Kong VPS example)

Full step-by-step: [`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md).

1. Provision an HTTPS entry domain whose TLS certificate is valid (e.g.
   `gateway.example.com`). The domain must **not** CNAME to a Google-hosted
   endpoint — clients must reach this host directly.
2. Create a service account with the minimum roles: `Firebase Authentication
   Admin`, `Cloud Datastore User` (Firestore), and `Storage Object Admin` on the
   avatar bucket only. Do not use project Owner.
3. Deploy with the bundled topology (`docker-compose.yml` + `Caddyfile`):

   ```bash
   cd gateway
   cp .env.example gateway.env   # fill in values; never commit it
   # Edit Caddyfile: replace gateway.example.com with the real hostname.
   docker compose up -d --build
   ```

   The compose file keeps the Node port on the internal Docker network only
   (`expose`, no `ports`), so it cannot be reached directly from the internet.
   Caddy is the only published service and replaces the forwarded client
   address. `TRUST_PROXY_HOPS=1` in compose matches that single hop.

   If you run the container outside Compose instead, bind it to loopback:
   `docker run -p 127.0.0.1:8080:8080 ...` — **never** `-p 8080:8080`.
4. Verify:

   ```bash
   curl -fsS https://gateway.example.com/healthz
   curl -fsS https://gateway.example.com/readyz
   npm run integration:auth        # needs test-account env vars; prints NOT EXECUTED otherwise
   ```

   Then run the client-side checks in `Technotes/FirebaseGateway.md`.

## Monitoring

- `GET /healthz` for liveness, `GET /readyz` for upstream + credential readiness.
- stdout is JSON lines: `{severity,msg,method,route,status,durationMs}`. Ship it
  to any log collector; alert on 5xx rate, p95 latency, and any
  `unhandled promise rejection` line (that path shuts the process down and the
  container restart policy brings it back).
- Run with `restart: unless-stopped` (the compose default) so a crash restarts.
- Add an external uptime check on `/healthz` from at least one vantage point and,
  once a China vantage point exists, from there too.

## Update and rollback

- Update: `docker compose build gateway`, then `docker compose up -d gateway`.
  Keep the previous image tag for rollback.
- Rollback: pin the previous image tag in `docker-compose.yml` (or
  `docker tag` the old image back to the running tag), then
  `docker compose up -d gateway`. No data migration is needed — the gateway owns
  no durable state beyond the `accountDeletionJobs` bookkeeping documents, which
  are forward-compatible.

## Sizing, traffic and host requirements

> **No load test has been run.** Everything below except the per-request payload
> sizes (taken from the API contract) is an **assumption to validate**, not
> measured capacity. Do not claim a DAU figure until a load test and a real
> China test have been recorded; see `DEPLOYMENT_RUNBOOK.md` for the load-test
> step.

The gateway is a thin, stateless relay (no database of its own; the only durable
state is `accountDeletionJobs/{uid}` in the existing Firestore).

### Recommended starting server (assumption, not a capacity claim)

| Tier | Spec | Rationale |
| --- | --- | --- |
| Start | 1–2 vCPU (shared is fine), 1–2 GB RAM, 20–40 GB SSD, 1–3 TB/month transfer, ≥100 Mbps port | Node + firebase-admin is mostly idle; this is a safe first box to test with |
| Grow (only after measurement) | 2 vCPU, 4 GB RAM | Decide from real CPU/RSS/throughput data |
| HA (only if needed) | 2× small instances + L4/L7 LB | Rate limits become per-instance (`instances × max`) unless a shared store is added |

- Node 22 + `firebase-admin` has been observed at ~150–250 MB RSS locally, but
  that is a local measurement, not a production capacity measurement.
- Location: **Hong Kong is the first candidate to test, not a promise of
  reachability.** Prefer a provider/line advertised as China-optimized
  (CN2 GIA / CMI / "China Premium" BGP) and verify from real China networks
  before committing.
- The entry domain must resolve to this host directly. Do **not** CNAME the
  gateway domain to any Google-hosted endpoint.

### Traffic: assumptions vs measured

**Measured:** none for production traffic. The only measured numbers are the
local smoke-test latencies (sub-10 ms for health/validation paths) and contract
payload sizes below; no load generator has been run against this service.

**Assumed** (per active user per day: 1.5 h of app use, ~5 foregrounds):

| Operation | Frequency | Size | Daily |
| --- | --- | --- | --- |
| Token refresh (`/v1/auth/refresh`) | ~2×/day | ~4 KB round trip (assumed) | ~8 KB |
| Profile read/write | 1–2× | ~3 KB | ~6 KB |
| Entitlement check | per foreground | ~1 KB | ~5 KB |
| Avatar (first load per device) | once, then cached | ≤200 KB download / ≤2 MB upload cap | one-off |

Assumed totals: **~20 KB/day/user of steady traffic, plus ~0.2 MB one-off per
new device.** At 1,000 / 10,000 DAU that would be ~0.6 GB / ~6 GB per month —
these are projections, not measurements. Budget 5–10× for retries and larger
payloads; validate with a load test before sizing up.

### Firebase quotas from a centralized egress IP (risk, verify in Console)

- All clients now share the gateway's egress IP(s). Firebase Auth applies
  **project-level** rate quotas to Identity Toolkit/Token Service, and its abuse
  detection also looks at source IPs; concentrating every sign-in behind one IP
  can trigger per-IP throttling even when the project quota has room.
- Email/password **registration** traffic is especially sensitive: a burst of
  new sign-ups from one IP is exactly the pattern identity providers throttle.
- Do not assume the numbers: read the actual quotas for the project in Google
  Cloud Console → APIs & Services → **Identity Toolkit API** and **Token Service
  API** → Quotas, before launch and after any spike. If throttling appears
  (HTTP 429 / `TOO_MANY_ATTEMPTS_TRY_LATER`), consider additional egress IPs or
  a quota increase request — do not disable protections.
- The dedicated server API key is what these requests are billed/limited
  against; monitor 429 rates per endpoint.

### What to rent / create

1. **One Linux VPS** (Docker-capable), Hong Kong candidate, with a China-optimized
   route if available.
2. **One domain or subdomain** you control, e.g. `gateway.example.com`, with an
   A/AAAA record to the VPS. No CDN required; if you put one in front, it must
   not be a Google-hosted endpoint and must forward `Authorization` unchanged.
3. **TLS certificate** for that hostname (Caddy issues it automatically;
   certbot is fine too).
4. **Firebase service account** with the minimum roles listed below.
5. **A dedicated server API key** (see checklist item 6) — do not reuse a
   client-restricted key.

## Configuration checklist

Server environment (`gateway/.env`, never committed):

| Item | Value / how to obtain | Verify |
| --- | --- | --- |
| `FIREBASE_PROJECT_ID` | `yuedu-readerr` (same as `GoogleService-Info.plist`) | `/readyz` reaches Firestore |
| `FIREBASE_API_KEY` | **Dedicated server key** (checklist item 6), not the iOS key | email sign-in works |
| `PUBLIC_BASE_URL` | `https://gateway.example.com` (exact entry URL, no trailing slash) | avatar URL returned by `PUT /v1/avatar` is fetchable |
| `GOOGLE_APPLICATION_CREDENTIALS` or `FIREBASE_SERVICE_ACCOUNT_JSON` | Mounted service-account JSON / base64 | `/readyz` = ready |
| `FUNCTIONS_REGION` | `asia-east1` (current callables region) | account-token returns a UUID |
| `TRUST_PROXY_HOPS` | `1` with the bundled Caddy/Docker topology; `0` if the Node process is exposed directly (do not do that) | forged `X-Forwarded-For` cannot change the rate-limit key |
| `PORT`, `RATE_LIMIT_*`, `UPSTREAM_TIMEOUT_MS`, `BODY_LIMIT_BYTES`, `AVATAR_MAX_BYTES` | defaults are safe | optional tuning |

Google Cloud / Firebase console:

1. **Service account roles** (minimum): `roles/firebaseauth.admin`,
   `roles/datastore.user`, and `roles/storage.objectAdmin` scoped to the avatar
   bucket. Do not grant Owner.
2. **Firestore**: existing rules stay unchanged. The gateway uses Admin
   credentials and enforces ownership itself.
3. **Storage**: existing rules stay unchanged.
4. **Auth providers**: Email/Password, Apple and Google stay enabled and
   configured exactly as the iOS app uses them.
5. **App Check — status unconfirmed.** The repository contains no client App
   Check integration and no `enforceAppCheck` on the callables, but project- or
   service-level enforcement (Firestore, Storage, Identity Toolkit) cannot be
   verified from the repository. Treat the current state as **unknown**:
   check Firebase Console → App Check for this project and record what you find.
   Do not assume enforcement is off, and do not change production enforcement
   for this deployment. If any API the gateway uses has enforcement enabled, the
   deployment is blocked until a supported server-side approach is chosen;
   never fabricate App Check tokens or fail open.
6. **API key**: if the `GoogleService-Info.plist` key is restricted to iOS
   apps, it will reject server-side calls. Create a second API key restricted to
   **both** APIs the gateway uses — **Identity Toolkit API**
   (`identitytoolkit.googleapis.com`, sign-in/sign-up/refresh/account updates)
   and **Token Service API** (`securetoken.googleapis.com`, token refresh).
   Restricting only Identity Toolkit breaks `/v1/auth/refresh` with
   `API_KEY_SERVICE_BLOCKED`. If the VPS has fixed egress IPs, add an IP
   restriction as well. Point `FIREBASE_API_KEY` at that server key. Do not
   remove restrictions from the client key.
7. **Quotas**: see "Firebase quotas from a centralized egress IP" above —
   project-level QPS is shared, per-IP abuse detection is the new risk, and the
   real numbers must be read from the Console.

iOS release configuration (current state):

8. `GATEWAY_BASE_URL = https://gateway.yuedureader.com` is set for **both Debug
   and Release**; `GatewayBaseURL` is injected at build time. Routing stays on
   the existing automatic policy: direct is preferred by default and by
   remembered success; the region hint selects the Gateway only when there is no
   memory yet. Release never forces the Gateway, and the forced-route launch
   argument is DEBUG-only. Apple/Google sign-in remain on the direct path until
   their Gateway exchange is interactively verified; only email may resolve to
   the Gateway.
9. Before shipping, re-run the account regression tests and, from a real China
   network, record carrier/city/time/operation/success-rate/latency.

Operations:

10. Open inbound 443 (and 80 for ACME if used); allow outbound 443 to
    `*.googleapis.com`, `identitytoolkit.googleapis.com`,
    `securetoken.googleapis.com` and
    `<region>-<project>.cloudfunctions.net`. No database ports; restrict SSH.
11. Keep the clock synchronized (chrony or systemd-timesyncd); token checks
    depend on it.
12. Enable log rotation (Docker `json-file` `max-size`/`max-file` or logrotate)
    and an uptime monitor on `/healthz`; alert on `/readyz` != ready.
13. Back up nothing on the host: the service is stateless. Firestore holds the
    deletion-job bookkeeping.
14. Keep the previous container image tagged for rollback.

## Local verification without a server

The gateway can be exercised locally without any Firebase credentials:

```bash
cd gateway
npm install
npm run smoke     # build + process smoke test, no credentials needed
npm test          # unit tests
```

`npm run smoke` starts the compiled server with a dummy project and verifies:
`/healthz` 200, `/readyz` degraded 503 reporting `credentials: unavailable`,
`/v1` gated with 503 before authentication, unknown route 404, malformed body
400, auth rate limit 429, and that the process survives the missing-credential
path. Manual equivalent:

```bash
FIREBASE_PROJECT_ID=smoke FIREBASE_API_KEY=dummy PUBLIC_BASE_URL=http://127.0.0.1:8080 npm start
curl -s localhost:8080/healthz           # {"status":"ok"}
curl -s localhost:8080/readyz            # 503 degraded (no credentials)
curl -s localhost:8080/v1/account/me     # 503 upstream-unavailable (data plane gated)
```

Real-account integration test (against a deployed gateway, read-only):

```bash
GATEWAY_BASE_URL=https://gateway.example.com \
TEST_ACCOUNT_EMAIL=... TEST_ACCOUNT_PASSWORD=... \
npm run integration:auth
```

Without those variables it prints `NOT EXECUTED` and exits 2 — record that as
"未執行", never as a pass.

## What the owner must provide

- The VPS, domain, DNS record and TLS certificate described above.
- The service-account JSON and a dedicated server API key (the deployment
  currently uses the project's public client key; replace before a wide
  rollout).
- `GATEWAY_BASE_URL` (currently set for Debug and Release).
- Privacy disclosure and host-location confirmation for the App Store listing.
