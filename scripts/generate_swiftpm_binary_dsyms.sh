#!/bin/sh
set -eu

if [ -z "${ARCHIVE_PATH:-}" ] && [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
    exit 0
fi

if [ -z "${ARCHIVE_PATH:-}" ] && [ "${ACTION:-}" != "archive" ] && [ "${ACTION:-}" != "install" ]; then
    exit 0
fi

if [ -n "${ARCHIVE_PATH:-}" ] && [ -d "${ARCHIVE_PATH}" ]; then
    dsyms_dir="${ARCHIVE_PATH}/dSYMs"
else
    dsyms_dir="${DWARF_DSYM_FOLDER_PATH}"
fi

mkdir -p "$dsyms_dir"

generated_count=0
scanned_dir_count=0
candidate_count=0
processed_frameworks="|"

generate_dsyms_from_dir() {
    frameworks_dir="$1"
    scanned_dir_count=$((scanned_dir_count + 1))

    for framework in "$frameworks_dir"/*.framework; do
        [ -d "$framework" ] || continue

        framework_name="$(basename "$framework" .framework)"
        executable="$framework/$framework_name"

        if [ ! -f "$executable" ] && [ -f "$framework/Info.plist" ]; then
            bundle_executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$framework/Info.plist" 2>/dev/null || true)"
            if [ -n "$bundle_executable" ]; then
                executable="$framework/$bundle_executable"
            fi
        fi

        [ -f "$executable" ] || continue

        binary_uuid="$(/usr/bin/dwarfdump --uuid "$executable" 2>/dev/null | awk '/UUID:/ { print $2; exit }')"
        [ -n "$binary_uuid" ] || continue

        candidate_count=$((candidate_count + 1))

        case "$processed_frameworks" in
            *"|$framework_name|"*) continue ;;
        esac
        processed_frameworks="${processed_frameworks}${framework_name}|"

        dsym_path="$dsyms_dir/${framework_name}.framework.dSYM"

        if [ -d "$dsym_path" ]; then
            dsym_uuid="$(/usr/bin/dwarfdump --uuid "$dsym_path" 2>/dev/null | awk '/UUID:/ { print $2; exit }')"
            if [ "$binary_uuid" = "$dsym_uuid" ]; then
                continue
            fi
            rm -rf "$dsym_path"
        fi

        if /usr/bin/dsymutil "$executable" -o "$dsym_path"; then
            generated_count=$((generated_count + 1))
        else
            echo "warning: Failed to generate dSYM for $framework_name" >&2
            rm -rf "$dsym_path"
        fi
    done
}

if [ -n "${ARCHIVE_PATH:-}" ] && [ -d "${ARCHIVE_PATH}/Products/Applications" ]; then
    for app_frameworks_dir in "${ARCHIVE_PATH}/Products/Applications"/*.app/Frameworks; do
        [ -d "$app_frameworks_dir" ] || continue
        generate_dsyms_from_dir "$app_frameworks_dir"
    done
else
    for candidate_dir in \
        "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}" \
        "${BUILT_PRODUCTS_DIR:-}" \
        "${CONFIGURATION_BUILD_DIR:-}"
    do
        [ -n "$candidate_dir" ] || continue
        [ -d "$candidate_dir" ] || continue
        generate_dsyms_from_dir "$candidate_dir"
    done
fi

if [ "$scanned_dir_count" -eq 0 ]; then
    echo "No framework directories found; skipping SwiftPM dSYM generation."
    exit 0
fi

echo "Generated $generated_count SwiftPM binary framework dSYM(s) from $candidate_count framework binary candidate(s)."
