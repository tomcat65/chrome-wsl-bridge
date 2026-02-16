#!/bin/bash
# chrome-wsl-health.sh - Comprehensive health check for Chrome WSL Bridge
# Runs all bridge health checks and reports unified status
# Usage: chrome-wsl-health.sh [--json|--quiet|--repair]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WSL_CHROME_DIR="$HOME/.claude/chrome"
WIN_USER="TOMAS"
WIN_CHROME_DIR="/mnt/c/Users/${WIN_USER}/.claude/chrome"
VERSIONS_DIR="$HOME/.local/share/claude/versions"

# Output format
FORMAT="normal"  # normal, json, quiet
DO_REPAIR=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --json) FORMAT="json" ;;
        --quiet) FORMAT="quiet" ;;
        --repair) DO_REPAIR=true ;;
        *)
            echo "Usage: $0 [--json|--quiet|--repair]" >&2
            exit 1
            ;;
    esac
    shift
done

# Check results storage
declare -a CHECK_NAMES=()
declare -a CHECK_RESULTS=()
declare -a CHECK_DETAILS=()

add_result() {
    local name="$1"
    local result="$2"  # PASS, FAIL, WARN
    local detail="$3"
    CHECK_NAMES+=("$name")
    CHECK_RESULTS+=("$result")
    CHECK_DETAILS+=("$detail")
}

# --- Check 1: WSL wrapper exists and is executable ---
check_wrapper_exists() {
    local wrapper="${WSL_CHROME_DIR}/chrome-native-host"
    if [ -f "$wrapper" ] && [ -x "$wrapper" ]; then
        add_result "WSL wrapper exists+executable" "PASS" "Found at ${wrapper}"
    elif [ -f "$wrapper" ]; then
        add_result "WSL wrapper exists+executable" "FAIL" "Exists but not executable"
    else
        add_result "WSL wrapper exists+executable" "FAIL" "Not found at ${wrapper}"
    fi
}

# --- Check 2: Wrapper uses dynamic version detection ---
check_wrapper_dynamic() {
    local wrapper="${WSL_CHROME_DIR}/chrome-native-host"
    if [ ! -f "$wrapper" ]; then
        add_result "Wrapper dynamic version" "FAIL" "Wrapper not found"
        return
    fi
    if grep -q "find_version\|VERSIONS_DIR" "$wrapper" 2>/dev/null; then
        add_result "Wrapper dynamic version" "PASS" "Uses dynamic version detection"
    else
        add_result "Wrapper dynamic version" "FAIL" "Wrapper does not use dynamic version detection"
    fi
}

# --- Check 3: Referenced Claude Code version binary exists ---
check_version_binary() {
    if [ ! -d "$VERSIONS_DIR" ]; then
        add_result "Claude Code binary exists" "FAIL" "Versions directory not found: ${VERSIONS_DIR}"
        return
    fi
    local latest
    latest=$(ls -1 "$VERSIONS_DIR" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [ -z "$latest" ]; then
        add_result "Claude Code binary exists" "FAIL" "No version directories found"
        return
    fi
    if [ -f "${VERSIONS_DIR}/${latest}" ]; then
        add_result "Claude Code binary exists" "PASS" "Version ${latest} binary exists"
    else
        add_result "Claude Code binary exists" "FAIL" "Version ${latest} binary missing"
    fi
}

# --- Check 4: .bat bridge exists with valid CRLF ---
check_bat_crlf() {
    local bat_path="${WIN_CHROME_DIR}/chrome-native-host.bat"
    if [ ! -f "$bat_path" ]; then
        add_result "BAT bridge exists with CRLF" "FAIL" "Not found at ${bat_path}"
        return
    fi
    if file "$bat_path" | grep -q "CRLF"; then
        add_result "BAT bridge exists with CRLF" "PASS" "CRLF line endings confirmed"
    else
        add_result "BAT bridge exists with CRLF" "FAIL" "Missing CRLF line endings"
    fi
}

# --- Check 5: .bat has error handling (exit /b) ---
check_bat_error_handling() {
    local bat_path="${WIN_CHROME_DIR}/chrome-native-host.bat"
    if [ ! -f "$bat_path" ]; then
        add_result "BAT error handling" "FAIL" "BAT file not found"
        return
    fi
    if grep -q "exit /b" "$bat_path" 2>/dev/null; then
        add_result "BAT error handling" "PASS" "Contains exit /b for error propagation"
    else
        add_result "BAT error handling" "FAIL" "Missing exit /b error propagation"
    fi
}

# --- Check 6: Code manifest valid and path matches .bat ---
check_code_manifest() {
    local manifest="${WIN_CHROME_DIR}/com.anthropic.claude_code_browser_extension.json"
    local bat_path="${WIN_CHROME_DIR}/chrome-native-host.bat"
    if [ ! -f "$manifest" ]; then
        add_result "Code manifest valid" "FAIL" "Not found at ${manifest}"
        return
    fi
    # Check JSON validity
    if ! python3 -m json.tool "$manifest" >/dev/null 2>&1; then
        add_result "Code manifest valid" "FAIL" "Invalid JSON"
        return
    fi
    # Check path matches .bat
    local manifest_path
    manifest_path=$(python3 -c "import json; print(json.load(open('${manifest}'))['path'])" 2>/dev/null || echo "")
    local expected_bat_win="C:\\Users\\${WIN_USER}\\.claude\\chrome\\chrome-native-host.bat"
    if [ "$manifest_path" = "$expected_bat_win" ]; then
        add_result "Code manifest valid" "PASS" "Valid JSON, path matches BAT"
    else
        add_result "Code manifest valid" "FAIL" "Path mismatch: got '${manifest_path}'"
    fi
}

# --- Check 7: Desktop-override manifest valid and path matches .bat ---
check_desktop_manifest() {
    local manifest="${WIN_CHROME_DIR}/com.anthropic.claude_browser_extension.json"
    local bat_path="${WIN_CHROME_DIR}/chrome-native-host.bat"
    if [ ! -f "$manifest" ]; then
        add_result "Desktop-override manifest valid" "FAIL" "Not found at ${manifest}"
        return
    fi
    # Check JSON validity
    if ! python3 -m json.tool "$manifest" >/dev/null 2>&1; then
        add_result "Desktop-override manifest valid" "FAIL" "Invalid JSON"
        return
    fi
    # Check path matches .bat
    local manifest_path
    manifest_path=$(python3 -c "import json; print(json.load(open('${manifest}'))['path'])" 2>/dev/null || echo "")
    local expected_bat_win="C:\\Users\\${WIN_USER}\\.claude\\chrome\\chrome-native-host.bat"
    if [ "$manifest_path" = "$expected_bat_win" ]; then
        add_result "Desktop-override manifest valid" "PASS" "Valid JSON, path matches BAT"
    else
        add_result "Desktop-override manifest valid" "FAIL" "Path mismatch: got '${manifest_path}'"
    fi
}

# --- Check 8: Code registry key correct ---
check_code_registry() {
    local reg_key="HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.anthropic.claude_code_browser_extension"
    local expected="C:\\Users\\${WIN_USER}\\.claude\\chrome\\com.anthropic.claude_code_browser_extension.json"
    local val
    val=$(reg.exe query "$reg_key" /ve 2>/dev/null | grep -i "REG_SZ" | sed 's/.*REG_SZ[[:space:]]*//' | tr -d '\r\n') || true
    if [ "$val" = "$expected" ]; then
        add_result "Code registry key" "PASS" "Points to correct manifest"
    elif [ -n "$val" ]; then
        add_result "Code registry key" "FAIL" "Unexpected value: ${val}"
    else
        add_result "Code registry key" "FAIL" "Registry key not found or empty"
    fi
}

# --- Check 9: Desktop registry state vs mode-intent ---
check_desktop_registry() {
    local mode
    mode=$(bash "${SCRIPT_DIR}/registry-guard.sh" --check 2>/dev/null) || mode="UNKNOWN"
    local intent=""
    if [ -f "${WSL_CHROME_DIR}/mode-intent.txt" ]; then
        intent=$(cat "${WSL_CHROME_DIR}/mode-intent.txt" | tr -d '[:space:]')
    fi

    case "$mode" in
        CODE_MODE)
            if [ "$intent" = "desktop" ]; then
                add_result "Desktop registry vs intent" "WARN" "Registry is CODE_MODE but intent is desktop"
            else
                add_result "Desktop registry vs intent" "PASS" "CODE_MODE matches intent"
            fi
            ;;
        DESKTOP_MODE)
            if [ "$intent" = "code" ]; then
                add_result "Desktop registry vs intent" "WARN" "Registry is DESKTOP_MODE but intent is code"
            else
                add_result "Desktop registry vs intent" "PASS" "DESKTOP_MODE matches intent"
            fi
            ;;
        *)
            add_result "Desktop registry vs intent" "FAIL" "Registry state is UNKNOWN"
            ;;
    esac
}

# --- Check 10: Backup integrity via checksums ---
check_backup_integrity() {
    local result
    result=$(bash "${SCRIPT_DIR}/backup-integrity.sh" --verify 2>&1) || true
    local exit_code=$?

    if echo "$result" | grep -q "Integrity check: PASS"; then
        add_result "Backup integrity checksums" "PASS" "All checksums match"
    elif echo "$result" | grep -q "No checksums found"; then
        add_result "Backup integrity checksums" "WARN" "No checksums initialized (run --init)"
    else
        local details
        details=$(echo "$result" | grep -E "^(MISSING|MODIFIED):" | head -3 | tr '\n' '; ')
        add_result "Backup integrity checksums" "FAIL" "Checksum mismatch: ${details}"
    fi
}

# --- Check 11: bridge.log recent activity ---
check_bridge_log() {
    local log_file="${WIN_CHROME_DIR}/bridge.log"
    if [ ! -f "$log_file" ]; then
        add_result "Bridge.log recent activity" "WARN" "No bridge.log found"
        return
    fi
    # Check if the file has been modified within the last 7 days
    local age_days
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$log_file") ) / 86400 ))
    if [ "$age_days" -le 7 ]; then
        local last_line
        last_line=$(tail -1 "$log_file" | tr -d '\r\n')
        add_result "Bridge.log recent activity" "PASS" "Last activity ${age_days} day(s) ago: ${last_line}"
    else
        add_result "Bridge.log recent activity" "WARN" "No activity in ${age_days} days"
    fi
}

# --- Run repair ---
run_repair() {
    echo "=== Running Repair ==="
    echo ""

    # Repair order: (1) version-wrapper.sh, (2) generate-bat.sh, (3) registry-guard.sh --fix, (4) backup-integrity.sh --init
    local repair_scripts=(
        "${SCRIPT_DIR}/version-wrapper.sh"
        "${SCRIPT_DIR}/generate-bat.sh"
        "${SCRIPT_DIR}/registry-guard.sh --fix"
        "${SCRIPT_DIR}/backup-integrity.sh --init"
    )
    local repair_names=(
        "Version wrapper"
        "BAT generator"
        "Registry guard fix"
        "Backup integrity init"
    )

    for i in "${!repair_scripts[@]}"; do
        local name="${repair_names[$i]}"
        local cmd="${repair_scripts[$i]}"
        echo -n "  Repairing: ${name}... "
        if bash -c "$cmd" >/dev/null 2>&1; then
            echo "OK"
        else
            echo "FAILED (continuing)"
        fi
    done
    echo ""
    echo "=== Repair Complete, Re-checking ==="
    echo ""
}

# --- Output functions ---
output_normal() {
    local total=${#CHECK_NAMES[@]}
    local pass=0 fail=0 warn=0

    echo "Chrome WSL Bridge Health Check"
    echo "=============================="
    echo ""

    for i in "${!CHECK_NAMES[@]}"; do
        local result="${CHECK_RESULTS[$i]}"
        local detail="${CHECK_DETAILS[$i]}"
        printf "  %-35s [%s] %s\n" "${CHECK_NAMES[$i]}" "$result" "$detail"
        case "$result" in
            PASS) pass=$((pass + 1)) ;;
            FAIL) fail=$((fail + 1)) ;;
            WARN) warn=$((warn + 1)) ;;
        esac
    done

    echo ""
    echo "Checks: ${total} total, ${pass} passed, ${fail} failed, ${warn} warnings"
    echo ""

    if [ "$fail" -gt 0 ]; then
        echo "BROKEN"
        return 1
    elif [ "$warn" -gt 0 ]; then
        echo "DEGRADED"
        return 2
    else
        echo "HEALTHY"
        return 0
    fi
}

output_quiet() {
    local fail=0 warn=0
    for i in "${!CHECK_RESULTS[@]}"; do
        case "${CHECK_RESULTS[$i]}" in
            FAIL) fail=$((fail + 1)) ;;
            WARN) warn=$((warn + 1)) ;;
        esac
    done

    if [ "$fail" -gt 0 ]; then
        echo "BROKEN"
        return 1
    elif [ "$warn" -gt 0 ]; then
        echo "DEGRADED"
        return 2
    else
        echo "HEALTHY"
        return 0
    fi
}

output_json() {
    local fail=0 warn=0
    for i in "${!CHECK_RESULTS[@]}"; do
        case "${CHECK_RESULTS[$i]}" in
            FAIL) fail=$((fail + 1)) ;;
            WARN) warn=$((warn + 1)) ;;
        esac
    done

    local status="HEALTHY"
    local exit_code=0
    if [ "$fail" -gt 0 ]; then
        status="BROKEN"
        exit_code=1
    elif [ "$warn" -gt 0 ]; then
        status="DEGRADED"
        exit_code=2
    fi

    echo "{"
    echo "  \"status\": \"${status}\","
    echo "  \"checks\": ["
    for i in "${!CHECK_NAMES[@]}"; do
        local comma=","
        if [ "$i" -eq $(( ${#CHECK_NAMES[@]} - 1 )) ]; then
            comma=""
        fi
        # Escape double quotes in detail string
        local detail="${CHECK_DETAILS[$i]}"
        detail="${detail//\\/\\\\}"
        detail="${detail//\"/\\\"}"
        echo "    {\"name\": \"${CHECK_NAMES[$i]}\", \"result\": \"${CHECK_RESULTS[$i]}\", \"detail\": \"${detail}\"}${comma}"
    done
    echo "  ],"
    echo "  \"summary\": {\"total\": ${#CHECK_NAMES[@]}, \"pass\": $(( ${#CHECK_NAMES[@]} - fail - warn )), \"fail\": ${fail}, \"warn\": ${warn}}"
    echo "}"

    return $exit_code
}

# --- Main ---
if [ "$DO_REPAIR" = true ]; then
    run_repair
fi

# Run all 11 checks
check_wrapper_exists
check_wrapper_dynamic
check_version_binary
check_bat_crlf
check_bat_error_handling
check_code_manifest
check_desktop_manifest
check_code_registry
check_desktop_registry
check_backup_integrity
check_bridge_log

# Output results based on format
exit_code=0
case "$FORMAT" in
    normal) output_normal || exit_code=$? ;;
    quiet) output_quiet || exit_code=$? ;;
    json) output_json || exit_code=$? ;;
esac

exit $exit_code
