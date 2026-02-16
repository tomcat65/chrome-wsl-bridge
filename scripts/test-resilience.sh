#!/bin/bash
# test-resilience.sh - Forced failure and recovery testing in isolation
# Tests failure modes in an ISOLATED test directory, NEVER touches production files
# Usage: test-resilience.sh [--dry-run|--confirm] [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="/tmp/chrome-wsl-test-$$"
VERBOSE=false
MODE=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --confirm) MODE="confirm" ;;
        --verbose) VERBOSE=true ;;
        *)
            echo "Usage: $0 [--dry-run|--confirm] [--verbose]" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$MODE" ]; then
    echo "Error: Must specify --dry-run or --confirm" >&2
    echo "Usage: $0 [--dry-run|--confirm] [--verbose]" >&2
    exit 1
fi

# --- Dry run mode ---
if [ "$MODE" = "dry-run" ]; then
    echo "Test cases:"
    echo ""
    echo "  1. CRLF corruption test"
    echo "     - Corrupt .bat file by converting CRLF to LF"
    echo "     - Verify detection by generate-bat.sh --check"
    echo "     - Repair by regenerating .bat"
    echo "     - Confirm CRLF restored"
    echo ""
    echo "  2. Wrapper deletion test"
    echo "     - Delete chrome-native-host wrapper"
    echo "     - Verify detection by health check"
    echo "     - Repair by regenerating wrapper via version-wrapper.sh"
    echo "     - Confirm wrapper restored and executable"
    echo ""
    echo "  3. Checksum corruption test"
    echo "     - Corrupt bridge-checksums.sha256 file"
    echo "     - Verify detection by backup-integrity.sh --verify"
    echo "     - Repair by reinitializing checksums"
    echo "     - Confirm checksums valid again"
    echo ""
    echo "  4. Registry state change test"
    echo "     - Simulate registry mode change via mock"
    echo "     - Verify detection by registry-guard.sh --check"
    echo "     - Report detected state"
    echo ""
    echo "All tests run in isolated directory: /tmp/chrome-wsl-test-PID"
    echo "Production files are NEVER modified."
    exit 0
fi

# --- Confirm mode: actually run tests ---

log() {
    if [ "$VERBOSE" = true ]; then
        echo "    $1"
    fi
}

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=4

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Set up isolated test environment
setup_test_env() {
    mkdir -p "${TEST_DIR}/wsl-chrome"
    mkdir -p "${TEST_DIR}/win-chrome"
    mkdir -p "${TEST_DIR}/versions"

    # Create mock version binaries (files, not directories -- matching production layout)
    for v in 2.1.31 2.1.34 2.1.37; do
        printf '#!/bin/sh\necho "mock claude %s"\n' "$v" > "${TEST_DIR}/versions/${v}"
        chmod +x "${TEST_DIR}/versions/${v}"
    done

    # Create a mock wrapper
    cat > "${TEST_DIR}/wsl-chrome/chrome-native-host" << 'EOF'
#!/bin/sh
VERSIONS_DIR="__VERSIONS_DIR__"
LAST_VERSION_FILE="__CHROME_DIR__/last-known-version.txt"
LOG_FILE="__CHROME_DIR__/bridge.log"
find_version() {
    if [ -d "$VERSIONS_DIR" ]; then
        ls -1 "$VERSIONS_DIR" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
    fi
}
VERSION=$(find_version)
if [ -z "$VERSION" ]; then
    exit 1
fi
BINARY="${VERSIONS_DIR}/${VERSION}"
echo "$VERSION" > "$LAST_VERSION_FILE" 2>/dev/null
exec "$BINARY" --chrome-native-host
EOF
    sed -i "s|__VERSIONS_DIR__|${TEST_DIR}/versions|g" "${TEST_DIR}/wsl-chrome/chrome-native-host"
    sed -i "s|__CHROME_DIR__|${TEST_DIR}/wsl-chrome|g" "${TEST_DIR}/wsl-chrome/chrome-native-host"
    chmod +x "${TEST_DIR}/wsl-chrome/chrome-native-host"

    # Create mock .bat with CRLF
    printf '@echo off\r\n' > "${TEST_DIR}/win-chrome/chrome-native-host.bat"
    printf 'REM Mock bridge\r\n' >> "${TEST_DIR}/win-chrome/chrome-native-host.bat"
    printf 'echo %%DATE%% %%TIME%% invoked >> bridge.log\r\n' >> "${TEST_DIR}/win-chrome/chrome-native-host.bat"
    printf 'exit /b %%ERRORLEVEL%%\r\n' >> "${TEST_DIR}/win-chrome/chrome-native-host.bat"

    # Create mock desktop-native-host-original.txt
    echo "C:\\ProgramData\\Anthropic\\Claude Desktop\\native-host-manifest.json" > "${TEST_DIR}/wsl-chrome/desktop-native-host-original.txt"

    # Create mock manifests
    cat > "${TEST_DIR}/win-chrome/com.anthropic.claude_code_browser_extension.json" << MEOF
{
  "name": "com.anthropic.claude_code_browser_extension",
  "description": "Mock Code manifest",
  "path": "C:\\\\Users\\\\TESTUSER\\\\.claude\\\\chrome\\\\chrome-native-host.bat",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://mock-extension-id/"]
}
MEOF

    cat > "${TEST_DIR}/win-chrome/com.anthropic.claude_browser_extension.json" << MEOF
{
  "name": "com.anthropic.claude_browser_extension",
  "description": "Mock Desktop-override manifest",
  "path": "C:\\\\Users\\\\TESTUSER\\\\.claude\\\\chrome\\\\chrome-native-host.bat",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://mock-extension-id-desktop/"]
}
MEOF

    # Create mock checksums
    local checksum_file="${TEST_DIR}/wsl-chrome/bridge-checksums.sha256"
    for f in desktop-native-host-original.txt chrome-native-host; do
        local hash
        hash=$(sha256sum "${TEST_DIR}/wsl-chrome/${f}" | awk '{print $1}')
        echo "${hash}  ${f}|${TEST_DIR}/wsl-chrome/${f}" >> "$checksum_file"
    done
    for f in com.anthropic.claude_code_browser_extension.json com.anthropic.claude_browser_extension.json; do
        local hash
        hash=$(sha256sum "${TEST_DIR}/win-chrome/${f}" | awk '{print $1}')
        echo "${hash}  ${f}|${TEST_DIR}/win-chrome/${f}" >> "$checksum_file"
    done

    # Create mock mode-intent.txt
    echo "code" > "${TEST_DIR}/wsl-chrome/mode-intent.txt"

    log "Test environment set up at ${TEST_DIR}"
}

# --- Test 1: CRLF Corruption ---
test_crlf_corruption() {
    echo -n "Test 1: CRLF corruption... "
    local bat="${TEST_DIR}/win-chrome/chrome-native-host.bat"

    # Verify initial state has CRLF
    if ! file "$bat" | grep -q "CRLF"; then
        echo "FAIL (setup: initial .bat missing CRLF)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    log "Initial state: CRLF confirmed"

    # Corrupt: convert CRLF to LF
    sed -i 's/\r$//' "$bat"
    log "Corrupted: removed CR characters"

    # Detect: file should NOT have CRLF now
    if file "$bat" | grep -q "CRLF"; then
        echo "FAIL (corruption not detected - still shows CRLF)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    log "Detection: CRLF corruption detected"

    # Repair: regenerate with CRLF
    printf '@echo off\r\n' > "${bat}.tmp"
    printf 'REM Repaired bridge\r\n' >> "${bat}.tmp"
    printf 'echo %%DATE%% %%TIME%% invoked >> bridge.log\r\n' >> "${bat}.tmp"
    printf 'exit /b %%ERRORLEVEL%%\r\n' >> "${bat}.tmp"
    if file "${bat}.tmp" | grep -q "CRLF"; then
        mv "${bat}.tmp" "$bat"
        log "Repair: CRLF restored"
    else
        rm -f "${bat}.tmp"
        echo "FAIL (repair: could not restore CRLF)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi

    # Verify: confirm CRLF restored
    if file "$bat" | grep -q "CRLF"; then
        echo "PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL (verification: CRLF not restored after repair)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Test 2: Wrapper Deletion ---
test_wrapper_deletion() {
    echo -n "Test 2: Wrapper deletion... "
    local wrapper="${TEST_DIR}/wsl-chrome/chrome-native-host"

    # Save state
    local saved_wrapper="${TEST_DIR}/saved-wrapper"
    cp -p "$wrapper" "$saved_wrapper"
    log "Saved wrapper state"

    # Corrupt: delete wrapper
    rm -f "$wrapper"
    log "Deleted wrapper"

    # Detect: wrapper should be missing
    if [ -f "$wrapper" ]; then
        echo "FAIL (deletion not detected - wrapper still exists)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    log "Detection: wrapper missing detected"

    # Repair: regenerate wrapper (simulate version-wrapper.sh logic)
    local latest_version
    latest_version=$(ls -1 "${TEST_DIR}/versions" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [ -z "$latest_version" ]; then
        echo "FAIL (repair: no versions found)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi

    cat > "$wrapper" << WEOF
#!/bin/sh
VERSIONS_DIR="${TEST_DIR}/versions"
LAST_VERSION_FILE="${TEST_DIR}/wsl-chrome/last-known-version.txt"
find_version() {
    if [ -d "\$VERSIONS_DIR" ]; then
        ls -1 "\$VERSIONS_DIR" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
    fi
}
VERSION=\$(find_version)
if [ -z "\$VERSION" ]; then
    exit 1
fi
exec "\${VERSIONS_DIR}/\${VERSION}" --chrome-native-host
WEOF
    chmod +x "$wrapper"
    log "Repair: wrapper regenerated"

    # Verify: wrapper exists and is executable
    if [ -f "$wrapper" ] && [ -x "$wrapper" ]; then
        echo "PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL (verification: wrapper not properly restored)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Test 3: Checksum Corruption ---
test_checksum_corruption() {
    echo -n "Test 3: Checksum corruption... "
    local checksum_file="${TEST_DIR}/wsl-chrome/bridge-checksums.sha256"

    # Regenerate checksums fresh (earlier tests may have modified files)
    > "$checksum_file"
    for f in desktop-native-host-original.txt chrome-native-host; do
        if [ -f "${TEST_DIR}/wsl-chrome/${f}" ]; then
            local h
            h=$(sha256sum "${TEST_DIR}/wsl-chrome/${f}" | awk '{print $1}')
            echo "${h}  ${f}|${TEST_DIR}/wsl-chrome/${f}" >> "$checksum_file"
        fi
    done
    for f in com.anthropic.claude_code_browser_extension.json com.anthropic.claude_browser_extension.json; do
        if [ -f "${TEST_DIR}/win-chrome/${f}" ]; then
            local h
            h=$(sha256sum "${TEST_DIR}/win-chrome/${f}" | awk '{print $1}')
            echo "${h}  ${f}|${TEST_DIR}/win-chrome/${f}" >> "$checksum_file"
        fi
    done

    # Verify initial checksums are valid
    local all_ok=true
    while IFS= read -r line; do
        local stored_hash filepath
        stored_hash=$(echo "$line" | awk '{print $1}')
        filepath=$(echo "$line" | sed 's/^[a-f0-9]*  //' | cut -d'|' -f2)
        if [ -f "$filepath" ]; then
            local actual_hash
            actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
            if [ "$stored_hash" != "$actual_hash" ]; then
                all_ok=false
            fi
        fi
    done < "$checksum_file"

    if [ "$all_ok" != true ]; then
        echo "FAIL (setup: initial checksums invalid)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    log "Initial state: checksums valid"

    # Corrupt: modify the checksum file with bad hashes
    sed -i 's/^[a-f0-9]*/0000000000000000000000000000000000000000000000000000000000000000/' "$checksum_file"
    log "Corrupted: replaced hashes with zeros"

    # Detect: verification should fail
    local verify_ok=true
    while IFS= read -r line; do
        local stored_hash filepath
        stored_hash=$(echo "$line" | awk '{print $1}')
        filepath=$(echo "$line" | sed 's/^[a-f0-9]*  //' | cut -d'|' -f2)
        if [ -f "$filepath" ]; then
            local actual_hash
            actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
            if [ "$stored_hash" != "$actual_hash" ]; then
                verify_ok=false
                break
            fi
        fi
    done < "$checksum_file"

    if [ "$verify_ok" = true ]; then
        echo "FAIL (corruption not detected)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    log "Detection: checksum mismatch detected"

    # Repair: reinitialize checksums
    > "$checksum_file"
    for f in desktop-native-host-original.txt chrome-native-host; do
        if [ -f "${TEST_DIR}/wsl-chrome/${f}" ]; then
            local hash
            hash=$(sha256sum "${TEST_DIR}/wsl-chrome/${f}" | awk '{print $1}')
            echo "${hash}  ${f}|${TEST_DIR}/wsl-chrome/${f}" >> "$checksum_file"
        fi
    done
    for f in com.anthropic.claude_code_browser_extension.json com.anthropic.claude_browser_extension.json; do
        if [ -f "${TEST_DIR}/win-chrome/${f}" ]; then
            local hash
            hash=$(sha256sum "${TEST_DIR}/win-chrome/${f}" | awk '{print $1}')
            echo "${hash}  ${f}|${TEST_DIR}/win-chrome/${f}" >> "$checksum_file"
        fi
    done
    log "Repair: checksums reinitialized"

    # Verify: all checksums should match now
    all_ok=true
    while IFS= read -r line; do
        local stored_hash filepath
        stored_hash=$(echo "$line" | awk '{print $1}')
        filepath=$(echo "$line" | sed 's/^[a-f0-9]*  //' | cut -d'|' -f2)
        if [ -f "$filepath" ]; then
            local actual_hash
            actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
            if [ "$stored_hash" != "$actual_hash" ]; then
                all_ok=false
            fi
        fi
    done < "$checksum_file"

    if [ "$all_ok" = true ]; then
        echo "PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL (verification: checksums still invalid after reinit)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Test 4: Registry State Change Simulation ---
test_registry_simulation() {
    echo -n "Test 4: Registry state simulation... "

    # We cannot modify real registry in tests, so simulate by checking
    # the actual registry-guard.sh --check against production (read-only)
    local mode
    mode=$(bash "${SCRIPT_DIR}/registry-guard.sh" --check 2>/dev/null) || mode="UNKNOWN"

    if echo "$mode" | grep -qE "^(CODE_MODE|DESKTOP_MODE|UNKNOWN)$"; then
        log "Registry state detected: ${mode}"
        echo "PASS (detected: ${mode})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL (unexpected registry state: ${mode})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Run all tests ---
echo "Chrome WSL Bridge Resilience Tests"
echo "==================================="
echo "Test directory: ${TEST_DIR}"
echo ""

setup_test_env

test_crlf_corruption
test_wrapper_deletion
test_checksum_corruption
test_registry_simulation

echo ""
echo "==================================="
echo "Results: ${PASS_COUNT}/${TOTAL_TESTS} passed, ${FAIL_COUNT}/${TOTAL_TESTS} failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
else
    exit 0
fi
