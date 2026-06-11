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
    
    # Try different base64 decoding commands to ensure compatibility with all macOS VM versions
    if echo "dGVzdA==" | base64 -D >/dev/null 2>&1; then
        echo "$GOOGLE_SERVICE_INFO_BASE64" | base64 -D > "$PLIST_PATH"
    elif echo "dGVzdA==" | base64 -d >/dev/null 2>&1; then
        echo "$GOOGLE_SERVICE_INFO_BASE64" | base64 -d > "$PLIST_PATH"
    elif echo "dGVzdA==" | base64 --decode >/dev/null 2>&1; then
        echo "$GOOGLE_SERVICE_INFO_BASE64" | base64 --decode > "$PLIST_PATH"
    else
        echo "Fallback to python3 for decoding..."
        echo "$GOOGLE_SERVICE_INFO_BASE64" | python3 -m base64 -d > "$PLIST_PATH"
    fi
    
    if [ -f "$PLIST_PATH" ] && [ -s "$PLIST_PATH" ]; then
        echo "GoogleService-Info.plist decoded successfully."
    else
        echo "Error: Failed to decode or write GoogleService-Info.plist."
        exit 1
    fi
else
    echo "=================================================================="
    echo "ERROR: GOOGLE_SERVICE_INFO_BASE64 environment variable is missing."
    echo "=================================================================="
    echo "Because GoogleService-Info.plist is ignored by Git, you must:"
    echo "1. Go to App Store Connect -> Xcode Cloud -> Workflows."
    echo "2. Edit your workflow -> Environment."
    echo "3. Add a new variable:"
    echo "   - Name: GOOGLE_SERVICE_INFO_BASE64"
    echo "   - Value: (The base64 encoded string of your GoogleService-Info.plist)"
    echo "   - Secure: Check the checkbox"
    echo "=================================================================="
    exit 1
fi

echo "=== ci_post_clone.sh completed ==="

