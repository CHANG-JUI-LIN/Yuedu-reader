#!/usr/bin/env bash
# Local smoke test for the compiled gateway. Uses a dummy project and no
# credentials on purpose: it verifies process startup, the error contract,
# authentication gating, the credentials data-plane gate and rate limiting
# without touching any real project.
#
# Usage: npm run smoke
set -u

cd "$(dirname "$0")/.."

PORT="${SMOKE_PORT:-18080}"
export FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-gateway-smoke}"
export FIREBASE_API_KEY="${FIREBASE_API_KEY:-dummy-key-for-smoke-test}"
export PUBLIC_BASE_URL="http://127.0.0.1:${PORT}"
export PORT
export RATE_LIMIT_AUTH_MAX=3
export RATE_LIMIT_MAX=200
export UPSTREAM_TIMEOUT_MS=2000
unset GOOGLE_APPLICATION_CREDENTIALS

if [ ! -f lib/index.js ]; then
  echo "lib/index.js missing; run npm run build first" >&2
  exit 1
fi

node lib/index.js > /tmp/yuedu-gateway-smoke.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/healthz" || true)" = "200" ]; then
    break
  fi
  sleep 0.25
done

PASS=0
FAIL=0
BODY_FILE="/tmp/yuedu-gateway-smoke-body.json"

check_status() {
  local name="$1" expected="$2" method="$3" url="$4" data="${5:-}"
  local actual
  if [ -n "$data" ]; then
    actual=$(curl -s -o "$BODY_FILE" -w "%{http_code}" -X "$method" -H 'Content-Type: application/json' --data "$data" "$url")
  else
    actual=$(curl -s -o "$BODY_FILE" -w "%{http_code}" -X "$method" "$url")
  fi
  if [ "$actual" = "$expected" ]; then
    echo "PASS  $name ($actual)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name expected=$expected actual=$actual"
    FAIL=$((FAIL + 1))
  fi
}

check_body() {
  local name="$1" needle="$2"
  if grep -q "$needle" "$BODY_FILE"; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (body did not contain $needle)"
    FAIL=$((FAIL + 1))
  fi
}

BASE="http://127.0.0.1:${PORT}"

check_status "healthz 200" 200 GET "$BASE/healthz"
check_body "healthz body" '"status":"ok"'

# Without credentials the data plane is gated and readiness degrades; neither
# may crash the process.
check_status "readyz degraded 503" 503 GET "$BASE/readyz"
check_body "readyz reports credentials" '"credentials":"unavailable"'
check_status "data plane gated 503" 503 GET "$BASE/v1/account/me"
check_body "data plane gate code" '"code":"upstream-unavailable"'

check_status "unknown route 404" 404 GET "$BASE/nope"
check_body "unknown route code" '"code":"not-found"'
check_status "malformed json 400" 400 POST "$BASE/v1/auth/email/signin" '"{'

LAST=""
for _ in 1 2 3 4; do
  LAST=$(curl -s -o "$BODY_FILE" -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
    --data '{"email":"smoke@example.com","password":"123456"}' "$BASE/v1/auth/email/signin")
done
if [ "$LAST" = "429" ]; then
  echo "PASS  auth rate limited 429"
  PASS=$((PASS + 1))
else
  echo "FAIL  auth rate limit expected=429 actual=$LAST"
  FAIL=$((FAIL + 1))
fi

check_status "server still alive" 200 GET "$BASE/healthz"

echo "----"
echo "smoke: pass=${PASS} fail=${FAIL} (no credentials: data plane 503 is expected)"
[ "$FAIL" -eq 0 ]
