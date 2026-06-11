#!/bin/sh

#  ci_post_clone.sh
#  Yuedu-Reader
#
#  Created by Antigravity.
#

# Make sure we fail if any command fails
set -e

echo "=== Running ci_post_clone.sh ==="

# Determine project root path
if [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    PROJECT_ROOT_DIR="$CI_PRIMARY_REPOSITORY_PATH"
else
    # Resolve the directory of the script and go one level up
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

echo "Project root directory: $PROJECT_ROOT_DIR"
PLIST_PATH="$PROJECT_ROOT_DIR/GoogleService-Info.plist"

if [ -n "$GOOGLE_SERVICE_INFO_BASE64" ]; then
    echo "Decoding GoogleService-Info.plist..."
    echo "$GOOGLE_SERVICE_INFO_BASE64" | base64 --decode > "$PLIST_PATH"
    echo "GoogleService-Info.plist decoded successfully."
else
    echo "Error: GOOGLE_SERVICE_INFO_BASE64 environment variable is not set or empty."
    echo "Please set GOOGLE_SERVICE_INFO_BASE64 in your Xcode Cloud workflow environment variables."
    exit 1
fi

echo "=== ci_post_clone.sh completed ==="
