#!/usr/bin/env node
/**
 * Real-account integration test for a deployed gateway.
 *
 * Required environment (never commit these):
 *   GATEWAY_BASE_URL       e.g. https://gateway.example.com
 *   TEST_ACCOUNT_EMAIL     a dedicated test account, not a real user
 *   TEST_ACCOUNT_PASSWORD
 *
 * Exits 0 on success, 1 on failure, 2 when credentials are missing — the
 * "NOT EXECUTED" marker, so a green run cannot be claimed without one.
 *
 * Read-only against the account: signs in, refreshes, reads the session,
 * profile and entitlement. It never links, unlinks, deletes or purchases.
 * Tokens and passwords are never printed.
 */

const base = process.env.GATEWAY_BASE_URL?.replace(/\/+$/, "");
const email = process.env.TEST_ACCOUNT_EMAIL;
const password = process.env.TEST_ACCOUNT_PASSWORD;

if (!base || !email || !password) {
  console.log("NOT EXECUTED: real-account integration test needs GATEWAY_BASE_URL,");
  console.log("TEST_ACCOUNT_EMAIL and TEST_ACCOUNT_PASSWORD. No request was made.");
  process.exit(2);
}

const url = new URL(base);
const isLoopback = ["127.0.0.1", "localhost", "::1"].includes(url.hostname);
if (url.protocol !== "https:" && !isLoopback) {
  console.error(`FAIL: refusing to send credentials over ${url.protocol}// outside loopback`);
  process.exit(1);
}

const results = [];
function record(name, ok, detail) {
  results.push({name, ok, detail});
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` (${detail})` : ""}`);
}

async function call(method, path, {token, body} = {}) {
  const startedAt = Date.now();
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token ? {Authorization: `Bearer ${token}`} : {}),
      ...(body ? {"Content-Type": "application/json"} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json = null;
  try {
    json = text === "" ? null : JSON.parse(text);
  } catch {
    json = null;
  }
  return {status: response.status, json, durationMs: Date.now() - startedAt};
}

try {
  const health = await call("GET", "/healthz");
  record("healthz", health.status === 200, `status ${health.status}`);

  const ready = await call("GET", "/readyz");
  record("readyz", ready.status === 200, `status ${ready.status}`);

  const signIn = await call("POST", "/v1/auth/email/signin", {body: {email, password}});
  const signInOk = signIn.status === 200
    && typeof signIn.json?.idToken === "string"
    && typeof signIn.json?.refreshToken === "string"
    && signIn.json?.user?.email === email;
  record("email sign-in", signInOk, `status ${signIn.status}, ${signIn.durationMs} ms`);
  if (!signInOk) {
    if (signIn.status === 401) console.error("hint: check the test account password and that the account is not disabled");
    if (signIn.status === 400) console.error("hint: check the server API key restrictions (Identity Toolkit API)");
    process.exit(1);
  }
  const firstUid = signIn.json.user.uid;

  const refresh = await call("POST", "/v1/auth/refresh", {body: {refreshToken: signIn.json.refreshToken}});
  const refreshOk = refresh.status === 200
    && typeof refresh.json?.idToken === "string"
    && typeof refresh.json?.refreshToken === "string";
  record("token refresh", refreshOk, `status ${refresh.status}, ${refresh.durationMs} ms`);
  if (!refreshOk) {
    if (refresh.status === 400) console.error("hint: check the server API key restrictions (Token Service API)");
    process.exit(1);
  }

  const me = await call("GET", "/v1/account/me", {token: refresh.json.idToken});
  record(
    "session user stable across refresh",
    me.status === 200 && me.json?.user?.uid === firstUid,
    `status ${me.status}`
  );

  const profile = await call("GET", "/v1/profile", {token: refresh.json.idToken});
  record("profile read", profile.status === 200, `status ${profile.status}`);

  const entitlement = await call(
    "GET",
    "/v1/subscription/entitlement?environment=production",
    {token: refresh.json.idToken}
  );
  record("entitlement read", entitlement.status === 200, `status ${entitlement.status}`);

  const failed = results.filter((entry) => !entry.ok);
  console.log("----");
  console.log(`integration-auth: ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length === 0 ? 0 : 1);
} catch (error) {
  console.error(`FAIL: ${error instanceof Error ? error.message : "unknown error"}`);
  process.exit(1);
}
