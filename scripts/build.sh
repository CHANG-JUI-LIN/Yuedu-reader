#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/yuedu app.xcodeproj"
SCHEME="yuedu app"

echo "Building $SCHEME for iOS Simulator..."

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build

echo "Build succeeded."
