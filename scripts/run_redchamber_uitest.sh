#!/bin/bash
# UI-test driver: RedChamber production rendering regression.
#
# Fresh-state sequence per the spec (no stale build / cache):
#   1. delete the app (uninstall)
#   2. wipe DerivedData
#   3. rebuild from scratch
#   4. install
#   5. copy the EPUB into the app Documents as RedChamber.epub
#   6. run the UI test (browserForced + overlay + auto-import)
#
# Usage: scripts/run_redchamber_uitest.sh [SIM_NAME]
set -euo pipefail

SIM_NAME="${1:-iPhone 17}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.zhangruilin.yuedureader"
EPUB_SOURCE="${YUEDU_HONGLOUMENG_EPUB_PATH:-/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub}"
DERIVED="/tmp/redchamber-dd"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/YueduReader.app"
echo "== [1/6] boot simulator + uninstall"
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
sleep 3
xcrun simctl uninstall "$SIM_NAME" "$BUNDLE_ID" 2>/dev/null || true

echo "== [2/6] wipe DerivedData"
rm -rf "$DERIVED"

echo "== [3/6] clean build (Debug)"
xcodebuild -project "$ROOT/Yuedu-Reader.xcodeproj" \
  -scheme "Yuedu-Reader" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tail -3

echo "== [4/6] install"
xcrun simctl install "$SIM_NAME" "$APP_PATH"

echo "== [5/6] copy EPUB into app Documents"
DATA_DIR="$(xcrun simctl get_app_container "$SIM_NAME" "$BUNDLE_ID" data)"
mkdir -p "$DATA_DIR/Documents"
cp "$EPUB_SOURCE" "$DATA_DIR/Documents/RedChamber.epub"
echo "   copied to $DATA_DIR/Documents/RedChamber.epub"

echo "== [6/6] run UI test"
xcodebuild -project "$ROOT/Yuedu-Reader.xcodeproj" \
  -scheme "Yuedu-Reader" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DERIVED" \
  -only-testing:"yuedu appUITests/RedChamberProductionUITests" \
  test 2>&1 | grep -E "UI-SHOT|UI-OVERLAY|Test Case|TEST EXECUTE|error:" | head -30
