#!/bin/bash
# registry-guard.sh - Registry revert detection and auto-recovery
# Detects when Chrome native messaging registry keys have been reverted
# Usage: registry-guard.sh [--check|--fix|--set-intent code|desktop]

set -euo pipefail

WIN_USER="TOMAS"
WSL_CHROME_DIR="$HOME/.claude/chrome"
WIN_CHROME_DIR="/mnt/c/Users/${WIN_USER}/.claude/chrome"
REPAIR_LOG="${WSL_CHROME_DIR}/repair.log"
INTENT_FILE="${WSL_CHROME_DIR}/mode-intent.txt"
DESKTOP_ORIGINAL="${WSL_CHROME_DIR}/desktop-native-host-original.txt"

# Registry key paths
REG_CODE_KEY="HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.anthropic.claude_code_browser_extension"
REG_DESKTOP_KEY="HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.anthropic.claude_browser_extension"

# Expected values for Code mode
CODE_MANIFEST="C:\\Users\\${WIN_USER}\\.claude\\chrome\\com.anthropic.claude_code_browser_extension.json"
DESKTOP_BRIDGE_MANIFEST="C:\\Users\\${WIN_USER}\\.claude\\chrome\\com.anthropic.claude_browser_extension.json"

log_repair() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$REPAIR_LOG"
}

get_registry_value() {
    local key="$1"
    local val
    val=$(reg.exe query "$key" /ve 2>/dev/null | grep -i "REG_SZ" | sed 's/.*REG_SZ[[:space:]]*//' | tr -d '\r\n') || true
    echo "$val"
}

get_intent() {
    if [ -f "$INTENT_FILE" ]; then
        cat "$INTENT_FILE" | tr -d '[:space:]'
    else
        echo ""
    fi
}

check_mode() {
    local code_val desktop_val

    code_val=$(get_registry_value "$REG_CODE_KEY")
    desktop_val=$(get_registry_value "$REG_DESKTOP_KEY")

    # Determine mode based on Desktop registry key
    # If desktop key points to our bridge manifest, we're in CODE_MODE
    # If desktop key points to the original Desktop manifest, we're in DESKTOP_MODE
    local original_desktop_manifest=""
    if [ -f "$DESKTOP_ORIGINAL" ]; then
        original_desktop_manifest=$(cat "$DESKTOP_ORIGINAL" | tr -d '\r\n')
    fi

    if [ "$code_val" = "$CODE_MANIFEST" ] && [ "$desktop_val" = "$DESKTOP_BRIDGE_MANIFEST" ]; then
        echo "CODE_MODE"
    elif [ -n "$original_desktop_manifest" ] && [ "$desktop_val" = "$original_desktop_manifest" ]; then
        echo "DESKTOP_MODE"
    elif [ -n "$code_val" ] || [ -n "$desktop_val" ]; then
        # Registry has values but they don't match expected patterns
        echo "UNKNOWN"
    else
        echo "UNKNOWN"
    fi
}

fix_registry() {
    local intent
    intent=$(get_intent)

    # Default to code if no intent file
    if [ -z "$intent" ]; then
        intent="code"
        echo "code" > "$INTENT_FILE"
        log_repair "INTENT: No intent file found, defaulting to code mode"
    fi

    if [ "$intent" = "desktop" ]; then
        echo "Intent is 'desktop' - no fix applied (respecting user choice)"
        log_repair "FIX-SKIP: Intent is desktop, no repair needed"
        exit 0
    fi

    if [ "$intent" != "code" ]; then
        echo "Error: Unknown intent value: ${intent}" >&2
        exit 1
    fi

    # Validate backup file is non-empty before any operation
    if [ ! -f "$DESKTOP_ORIGINAL" ] || [ ! -s "$DESKTOP_ORIGINAL" ]; then
        echo "Error: Desktop original manifest backup is missing or empty" >&2
        log_repair "FIX-FAIL: desktop-native-host-original.txt missing or empty"
        exit 1
    fi

    local current_mode
    current_mode=$(check_mode)

    if [ "$current_mode" = "CODE_MODE" ]; then
        echo "Registry already in CODE_MODE - no fix needed"
        exit 0
    fi

    # Fix: set Code registry key
    reg.exe add "$REG_CODE_KEY" /ve /t REG_SZ /d "$CODE_MANIFEST" /f >/dev/null 2>&1
    log_repair "FIX: Set Code registry key to ${CODE_MANIFEST}"

    # Fix: set Desktop registry key to bridge manifest
    reg.exe add "$REG_DESKTOP_KEY" /ve /t REG_SZ /d "$DESKTOP_BRIDGE_MANIFEST" /f >/dev/null 2>&1
    log_repair "FIX: Set Desktop registry key to ${DESKTOP_BRIDGE_MANIFEST}"

    # Verify fix
    local new_mode
    new_mode=$(check_mode)
    if [ "$new_mode" = "CODE_MODE" ]; then
        echo "Registry restored to CODE_MODE"
        log_repair "FIX-SUCCESS: Registry restored to CODE_MODE"
        exit 0
    else
        echo "Error: Fix applied but registry still not in CODE_MODE (got: ${new_mode})" >&2
        log_repair "FIX-FAIL: Registry still ${new_mode} after fix attempt"
        exit 1
    fi
}

set_intent() {
    local mode="$1"
    if [ "$mode" != "code" ] && [ "$mode" != "desktop" ]; then
        echo "Error: Intent must be 'code' or 'desktop'" >&2
        exit 1
    fi
    echo "$mode" > "$INTENT_FILE"
    echo "Intent set to: ${mode}"
    log_repair "INTENT-SET: User set intent to ${mode}"
}

# Main
if [ $# -eq 0 ]; then
    echo "Usage: $0 [--check|--fix|--set-intent code|desktop]" >&2
    exit 1
elif [ "$1" = "--check" ]; then
    check_mode
elif [ "$1" = "--fix" ]; then
    fix_registry
elif [ "$1" = "--set-intent" ]; then
    if [ $# -lt 2 ]; then
        echo "Error: --set-intent requires 'code' or 'desktop'" >&2
        exit 1
    fi
    set_intent "$2"
else
    echo "Usage: $0 [--check|--fix|--set-intent code|desktop]" >&2
    exit 1
fi
