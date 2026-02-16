#!/bin/bash
# backup-integrity.sh - SHA256 checksum validator for Chrome WSL Bridge files
# Creates and validates checksums for all bridge configuration files
# Usage: backup-integrity.sh [--init|--verify]

set -euo pipefail

WSL_CHROME_DIR="$HOME/.claude/chrome"
WIN_USER="TOMAS"
WIN_CHROME_DIR="/mnt/c/Users/${WIN_USER}/.claude/chrome"
CHECKSUM_FILE="${WSL_CHROME_DIR}/bridge-checksums.sha256"

# Files to checksum (with their full paths and display names)
get_files() {
    echo "${WSL_CHROME_DIR}/desktop-native-host-original.txt|desktop-native-host-original.txt"
    echo "${WSL_CHROME_DIR}/chrome-native-host|chrome-native-host"
    echo "${WIN_CHROME_DIR}/com.anthropic.claude_code_browser_extension.json|com.anthropic.claude_code_browser_extension.json"
    echo "${WIN_CHROME_DIR}/com.anthropic.claude_browser_extension.json|com.anthropic.claude_browser_extension.json"
}

init_checksums() {
    local count=0
    > "$CHECKSUM_FILE"

    while IFS='|' read -r filepath display_name; do
        if [ -f "$filepath" ]; then
            local hash
            hash=$(sha256sum "$filepath" | awk '{print $1}')
            echo "${hash}  ${display_name}|${filepath}" >> "$CHECKSUM_FILE"
            count=$((count + 1))
        else
            echo "Warning: File not found, skipping: ${display_name}" >&2
        fi
    done < <(get_files)

    echo "Checksums initialized: ${count} files"
    echo "Checksum file: ${CHECKSUM_FILE}"
}

verify_checksums() {
    if [ ! -f "$CHECKSUM_FILE" ]; then
        echo "No checksums found. Run --init first." >&2
        exit 2
    fi

    local all_pass=true
    local checked=0
    local failed=0

    while IFS= read -r line; do
        local stored_hash display_and_path display_name filepath
        stored_hash=$(echo "$line" | awk '{print $1}')
        display_and_path=$(echo "$line" | sed 's/^[a-f0-9]*  //')
        display_name=$(echo "$display_and_path" | cut -d'|' -f1)
        filepath=$(echo "$display_and_path" | cut -d'|' -f2)

        if [ ! -f "$filepath" ]; then
            echo "MISSING: ${display_name}"
            all_pass=false
            failed=$((failed + 1))
        else
            local current_hash
            current_hash=$(sha256sum "$filepath" | awk '{print $1}')
            if [ "$current_hash" = "$stored_hash" ]; then
                echo "OK: ${display_name}"
            else
                echo "MODIFIED: ${display_name}"
                all_pass=false
                failed=$((failed + 1))
            fi
        fi
        checked=$((checked + 1))
    done < "$CHECKSUM_FILE"

    echo ""
    echo "Checked: ${checked} files, Failed: ${failed}"

    if [ "$all_pass" = true ]; then
        echo "Integrity check: PASS"
        exit 0
    else
        echo "Integrity check: FAIL"
        exit 1
    fi
}

# Main
if [ $# -eq 0 ]; then
    verify_checksums
elif [ "$1" = "--init" ]; then
    init_checksums
elif [ "$1" = "--verify" ]; then
    verify_checksums
else
    echo "Usage: $0 [--init|--verify]" >&2
    exit 1
fi
