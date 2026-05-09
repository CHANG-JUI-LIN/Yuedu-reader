#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/Yuedu-Reader.xcodeproj"
SCHEME="Yuedu-Reader"

echo "Building $SCHEME for iOS Simulator..."

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build

echo "Build succeeded."
