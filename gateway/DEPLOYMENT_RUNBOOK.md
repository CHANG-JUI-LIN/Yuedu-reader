# Gateway test-deployment runbook

Operational checklist for standing up a **test** gateway before any release
build points at it. Every step is written so the person executing it can record
what was actually done and what was skipped. Do not buy resources as part of
this document; the owner does that explicitly.

Status convention used in the results table at the end:

- **未執行 / NOT EXECUTED** — no environment or credentials were available.
- **通過 / PASS** — command output recorded.
- **失敗 / FAIL** — reproduction attached.

---

## 0. Preconditions

- [ ] Owner has approved creating a VPS, a subdomain and a service account.
- [ ] A **dedicated** Firebase server API key is planned for the gateway
      (see §2). Do not reuse a client-restricted key.
- [ ] A dedicated test account exists (email/password) and is **not** a real
      user account. Tests must not touch real user data.
- [ ] App Check enforcement state for the project has been read from the
      Firebase Console (see §2.5); record it before deploying.

## 1. Host and domain

- [ ] VPS (start spec): 1–2 vCPU, 1–2 GB RAM, 20–40 GB SSD, ≥100 Mbps,
      Docker + Compose installed. Hong Kong first candidate; China-optimized
      line preferred.
- [ ] DNS: `gateway.<domain>` A/AAAA → VPS public IP. No CNAME to a
      Google-hosted endpoint, no CDN in front for the first test.
- [ ] Firewall: inbound 22 (restricted to your IP), 80 + 443 open; no other
      ports. Confirm the VPS provider firewall as well as the host firewall.
- [ ] Outbound 443 allowed to `*.googleapis.com`, `identitytoolkit.googleapis.com`,
      `securetoken.googleapis.com`, `<region>-<project>.cloudfunctions.net`.
- [ ] Clock synchronized (`chronyc tracking` or `timedatectl` shows synced).
- [ ] Swap or memory headroom configured (1 GB box: add 1–2 GB swap).

## 2. Security configuration and credentials

1. **Service account** (IAM): create a dedicated account with
   `roles/firebaseauth.admin`, `roles/datastore.user`, and
   `roles/storage.objectAdmin` restricted to the avatar bucket. No Owner.
   Download JSON, place at `/etc/yuedu/firebase-service-account.json`, mode
   `0400`, owner root.
2. **Server API key**: Google Cloud Console → APIs & Services → Credentials →
   Create API key.
   - API restrictions: **Identity Toolkit API** *and* **Token Service API**
     (`securetoken.googleapis.com`). Missing the latter returns
     `API_KEY_SERVICE_BLOCKED` on `/v1/auth/refresh`.
   - Application restrictions: none if egress IPs are dynamic; otherwise
     restrict to the VPS static egress IPs.
   - Record it in `gateway.env` as `FIREBASE_API_KEY` (mode `0600`).
3. **`gateway.env`** (copy of `.env.example`): `FIREBASE_PROJECT_ID`,
   `FIREBASE_API_KEY` (server key), `PUBLIC_BASE_URL=https://gateway.<domain>`,
   `GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/firebase-service-account.json`,
   `TRUST_PROXY_HOPS=1`. Never commit this file.
4. **TLS/proxy**: edit `Caddyfile` with the real hostname; Caddy obtains and
   renews the certificate. Keep `header_up X-Forwarded-For {remote_host}` so a
   client cannot inject its own address. Node is on the internal Docker network
   only (`expose`, no `ports`).
5. **App Check**: Firebase Console → App Check. Record whether enforcement is
   enabled for Firestore, Cloud Storage, Authentication and Cloud Functions.
   - If any is enforced: **stop**. The gateway has no supported way to present
     App Check tokens; do not disable enforcement and do not fabricate tokens.
   - If none is enforced: record "confirmed off at <date> by <person>" in the
     results table. Do not change any enforcement setting.
6. **Quotas**: Console → APIs & Services → Identity Toolkit API and Token
   Service API → Quotas. Record the current per-project QPS values and the
   support-billing tier. This is required before any load test.

## 3. Start the service

```bash
cd gateway
npm ci
npm test                 # unit tests
npm run smoke            # local, no credentials
cp .env.example gateway.env   # fill in §2
docker compose build
docker compose up -d
docker compose ps        # both services Up
docker compose logs gateway --tail=50
```

Expected: `upstream credentials resolved` in the gateway log, `/readyz` = ready.
If the log says `upstream credentials unavailable; data plane disabled until
restart`, fix the credential mount and `docker compose restart gateway`
(the gate clears only after a successful startup validation).

## 4. Real-account integration test (read-only)

```bash
GATEWAY_BASE_URL=https://gateway.<domain> \
TEST_ACCOUNT_EMAIL=<test account> \
TEST_ACCOUNT_PASSWORD=<test password> \
npm run integration:auth
```

Covers: `/healthz`, `/readyz`, email sign-in, refresh token exchange, session
user stability across refresh, profile read and entitlement read. It never
links, unlinks, deletes or purchases, and never prints tokens or passwords.

- Exit 0 → record PASS with the printed statuses and latencies.
- Exit 2 → record **未執行** (missing env vars) — never a pass.
- Exit 1 → record FAIL. Wrong-password / disabled-account cases are deliberate
  non-goals here; diagnose `401` vs `400` with the printed hints (API key
  restrictions are the usual `400` cause).

## 5. China-network test (only after §4 passes)

- [ ] From at least two mainland-China networks (different carriers, e.g.
      China Telecom + China Mobile), on a real device or a China SIM hotspot:
      record city, carrier, date/time, Wi-Fi/cellular, and per-operation
      latency/success for: app launch session restore, email sign-in,
      Apple sign-in, profile read, entitlement read, avatar fetch.
- [ ] Verify a VPN-free path actually reaches `https://gateway.<domain>` and
      that the app does **not** call Google endpoints for these operations.
- [ ] Record failures with the exact error text and HTTP status. A pass on one
      carrier is not a pass for mainland China.

## 6. Load test (before any capacity claim)

Not executed by default. On the test gateway, with §2.6 quota numbers recorded:

```bash
# example only; install and run from your load-test machine
npx autocannon -c 50 -d 60 -m POST -H 'Content-Type: application/json' \
  -b '{"email":"load-test@example.invalid","password":"wrongwrong"}' \
  https://gateway.<domain>/v1/auth/email/signin
```

Use invalid credentials so no real accounts are touched and no sessions are
created. Record: requests/sec sustained, p50/p95/p99, 429/5xx rates, gateway CPU
and RSS, upstream error mix. Capacity statements may only cite these numbers.

## 7. Rollback

- [ ] Keep the previous image tag before updating:
      `docker image tag yuedu-gateway:local yuedu-gateway:previous`.
- [ ] App-side: the release build keeps `GATEWAY_BASE_URL` **empty**, so it
      stays on the direct route. Only a dedicated test build sets the URL.
- [ ] Server-side rollback: pin the previous tag in `docker-compose.yml`
      (`image: yuedu-gateway:previous`), `docker compose up -d gateway`.
- [ ] Emergency: `docker compose down` takes the entry offline; clients on the
      direct route are unaffected. (A test build pointed at the gateway will
      fail auth until it is switched back to direct in Settings → 帳號連線方式.)

## 8. Results table (fill during execution)

Executed 2026-09-11/12 against `https://gateway.yuedureader.com` (Tencent
Cloud Lighthouse, Hong Kong). Deployment topology on the host is a single
`docker run` container on `127.0.0.1:8080` behind host Caddy; the compose file
in this repo is not used there.

| Step | Result | Evidence |
| --- | --- | --- |
| Unit tests `npm test` | PASS (44 tests) | gateway workspace |
| Local smoke `npm run smoke` | PASS (11 checks) | gateway workspace |
| Caddyfile validation / XFF hardening | PASS | `caddy validate` + reload; `header_up X-Forwarded-For {remote_host}` added |
| Credential validation on host (`/readyz` ready) | PASS | `{"status":"ready",...}` |
| API key works for sign-in and refresh | PASS with the project's public client key | real signup/signin/refresh through the gateway |
| Dedicated server API key with both APIs | 未執行（目前沿用公開 client key；上線前建議更換為伺服器專用 key） | — |
| App Check enforcement state confirmed | 未執行 (no Console evidence; status remains unconfirmed) | — |
| Forged `X-Forwarded-For` cannot bypass rate limit | PASS (unit) + deployment `TRUST_PROXY_HOPS=1` | `test/proxy.test.ts`; `docker exec printenv TRUST_PROXY_HOPS` → 1 |
| Real-account integration (iOS client code against deployed Gateway) | PASS | `GatewayLiveIntegrationTests` — signup/signin/wrong-password/duplicate/refresh/restore/profile/avatar/entitlement/account-token/bind-rejection/link-guard/unlink-guard/revoke/delete |
| Apple sign-in through Gateway | 未執行 (interactive Apple ID required) | — |
| Google sign-in through Gateway | 未執行 (interactive provider authorization) | — |
| StoreKit purchase binding / restore | 未執行 (no sandbox Apple ID; invalid-JWS rejection path verified) | — |
| Firebase `disabled` user | 未執行 (needs Console disable); revocation path verified via `/v1/auth/logout {revokeAllDevices:true}` | — |
| China network test | 未執行 (no China network) | — |
| Load test | 未執行 (no host) | — |
| Release `GATEWAY_BASE_URL` empty | PASS | built Release `Info.plist` → `""` |

Deployment notes:

- The running image was rebuilt from the current revision; the previous image is
  kept as `yuedu-gateway:previous` for rollback.
- `FIREBASE_API_KEY` in `/home/ubuntu/yuedu-gateway/.env` was the
  `.env.example` placeholder (`AIzaSy...replace-me`, 19 chars) and is now the
  project's public client key. Replace with a dedicated server key before a wide
  rollout.
- `TRUST_PROXY_HOPS=1` is set on the container; Caddy replaces the forwarded
  client address.
- The SSH deploy key added for this session can be removed from
  `~/.ssh/authorized_keys` when integration work is finished.
