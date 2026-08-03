#!/usr/bin/env bash
# One-time setup for the automatic TestFlight invitation flow.
# Stores the App Store Connect API credentials as Firebase Functions secrets.
#
# Before running:
#   1. Open https://appstoreconnect.apple.com/access/integrations/api
#   2. Generate an API key with the App Manager role
#   3. Note the Issuer ID and Key ID, download the .p8 key file
#   4. Run:  base64 -i AuthKey_XXXX.p8 | pbcopy
#   5. Run this script; paste each value when prompted.
#      For the group name, paste the TestFlight group name you want to use
#      (it is created automatically if it does not exist).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v firebase >/dev/null 2>&1; then
  echo "firebase CLI not found. Install it with:  npm install -g firebase-tools"
  exit 1
fi

firebase functions:secrets:set APP_STORE_CONNECT_ISSUER_ID
firebase functions:secrets:set APP_STORE_CONNECT_KEY_ID
firebase functions:secrets:set APP_STORE_CONNECT_PRIVATE_KEY
firebase functions:secrets:set APP_STORE_CONNECT_GROUP_NAME

echo "Secrets set. Deploy with:  firebase deploy --only functions"
