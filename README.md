# Chrome WSL Bridge

Resilience hardening for the Claude in Chrome extension when running Claude Code inside WSL2.

## The Problem

The [Claude in Chrome](https://chrome.google.com/webstore/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) extension connects to Claude via **Windows Native Messaging** -- a Chrome API that launches a local process and communicates over stdin/stdout. The extension supports two backends:

1. **Claude Desktop** (`com.anthropic.claude_browser_extension`) -- a native Windows app
2. **Claude Code** (`com.anthropic.claude_code_browser_extension`) -- a CLI tool

The extension tries Desktop first, then Code. **First host to respond "pong" to a "ping" wins.** Desktop always won because it's a native Windows process and responds faster.

When Claude Code runs inside WSL2, there's a second problem: Chrome on Windows can't see Linux-side native messaging host files. Chrome reads from the **Windows registry** and **Windows filesystem paths**, not Linux paths.

**Result:** The Chrome extension never connects to Claude Code in WSL. You get MCP browser tools (`tabs_context_mcp`, `navigate`, etc.) only through Desktop, never through Code.

## The Solution

A **Windows batch file bridge** that Chrome invokes as a native messaging host. The `.bat` file crosses the Windows/WSL boundary via `wsl.exe --exec`, reaching Claude Code inside WSL.

To win the connection race against Desktop, we **swap Desktop's registry entry** to point at our bridge instead. The extension thinks it's talking to Desktop, but it's actually talking to Code.

```
Chrome Extension (Windows)
  |
  | Native Messaging: "com.anthropic.claude_browser_extension"
  v
Windows Registry --> JSON manifest --> chrome-native-host.bat (CRLF!)
  |
  | wsl.exe --exec
  v
~/.claude/chrome/chrome-native-host (dynamic version wrapper)
  |
  | exec with --chrome-native-host
  v
~/.local/share/claude/versions/X.Y.Z (Claude Code binary)
```

## Why This Breaks (And Why We Built Resilience)

The bridge works, but it's **architecturally fragile**. Any of these events can silently break it:

| Event | What breaks | Symptom |
|-------|------------|---------|
| Claude Desktop updates | Registry reverts to Desktop's native host | Extension connects to Desktop instead of Code |
| Claude Code upgrades | Wrapper still points to old version binary | Bridge invokes a deleted binary, fails silently |
| `.bat` file edited from WSL | Line endings change from CRLF to LF | Windows `cmd.exe` can't parse the batch file |
| Files deleted or corrupted | Manifests, wrapper, or backup missing | Extension fails to connect with no error message |

This project adds **7 scripts** that detect, prevent, and auto-repair all of these failures.

## Prerequisites

- Windows 10/11 with WSL2
- Claude Code installed inside WSL (`claude --version` works)
- Chrome with the Claude in Chrome extension installed
- The bridge already set up (`/chrome-wsl setup` or manual setup)

## Scripts

All scripts live in `scripts/` and are designed to be run from WSL.

### Health Check

The primary entry point. Runs 11 checks across the entire bridge chain in under 1 second.

```bash
# Quick status -- are we healthy?
bash scripts/chrome-wsl-health.sh --quiet
# Output: HEALTHY

# Full detail -- see every check
bash scripts/chrome-wsl-health.sh
# Output:
#   [PASS] WSL wrapper exists and executable
#   [PASS] Wrapper uses dynamic version detection
#   [PASS] Claude Code binary exists (2.1.37)
#   [PASS] BAT bridge exists with CRLF line endings
#   [PASS] BAT has error handling (exit /b)
#   [PASS] Code manifest valid JSON, path matches BAT
#   [PASS] Desktop-override manifest valid JSON, path matches BAT
#   [PASS] Code registry key correct
#   [PASS] Desktop registry matches mode intent (CODE_MODE)
#   [PASS] Backup integrity checksums valid
#   [PASS] Bridge log has recent activity
#   Status: HEALTHY (11/11 passed)

# JSON output -- for automation or piping to jq
bash scripts/chrome-wsl-health.sh --json

# Auto-repair -- fix everything that's broken, then re-check
bash scripts/chrome-wsl-health.sh --repair
# Output:
#   Repairing: running version-wrapper.sh...
#   Repairing: running generate-bat.sh...
#   Repairing: running registry-guard.sh --fix...
#   Repairing: running backup-integrity.sh --init...
#   Re-checking health...
#   Status: HEALTHY (11/11 passed)
```

### Version Wrapper

Generates a dynamic version wrapper that auto-detects the latest Claude Code binary at invocation time. No more hardcoded version numbers.

```bash
# Preview what version would be detected
bash scripts/version-wrapper.sh --dry-run
# Output: Detected version: 2.1.37, Binary path: ~/.local/share/claude/versions/2.1.37

# Generate the wrapper (backs up the old one to .bak)
bash scripts/version-wrapper.sh
# Output: Wrapper generated at ~/.claude/chrome/chrome-native-host
```

**How it works:** The generated wrapper scans `~/.local/share/claude/versions/` for the highest semver directory. If that directory disappears (e.g., after an upgrade + cleanup), it falls back to a cached version in `~/.claude/chrome/last-known-version.txt`.

### BAT Generator

Creates the Windows batch bridge file with guaranteed CRLF line endings and error handling.

```bash
# Check if the existing .bat has valid CRLF (non-destructive)
bash scripts/generate-bat.sh --check
# Output: PASS: chrome-native-host.bat has CRLF line endings

# Regenerate the .bat (backs up old one to .bak)
bash scripts/generate-bat.sh
# Output: Generated chrome-native-host.bat with CRLF line endings
```

**Why CRLF matters:** Windows `cmd.exe` requires `\r\n` line endings. WSL tools write `\n` by default. A `.bat` file with Unix line endings will fail silently -- Chrome gets no error, the extension just doesn't connect. This is the #1 cause of bridge breakage.

**Atomic writes:** The script writes to a `.tmp` file, validates CRLF with the `file` command, then moves it into place. If validation fails, the original `.bat` is untouched.

### Registry Guard

Detects when Windows or Desktop updates have reverted the registry, and restores it -- but only if you intended to be in Code mode.

```bash
# Check current registry state
bash scripts/registry-guard.sh --check
# Output: CODE_MODE

# Fix registry if it was reverted (respects your intent)
bash scripts/registry-guard.sh --fix
# Output: Registry matches intent (code). No action needed.

# Record that you intentionally want Desktop mode
bash scripts/registry-guard.sh --set-intent desktop

# Now --fix won't override your choice
bash scripts/registry-guard.sh --fix
# Output: Intent is desktop. Skipping Code mode restore.
```

**Mode intent tracking:** The script stores your intended mode in `~/.claude/chrome/mode-intent.txt`. This prevents auto-repair from fighting you when you intentionally switch to Desktop mode. Without this, a health check with `--repair` would undo your `switch desktop` command.

### Backup Integrity

SHA256 checksums for the 4 critical bridge files. Detects both corruption and deletion.

```bash
# Initialize checksums after a known-good state
bash scripts/backup-integrity.sh --init
# Output: Checksums initialized: 4 files

# Verify all files match their checksums
bash scripts/backup-integrity.sh --verify
# Output:
#   OK: desktop-native-host-original.txt
#   OK: chrome-native-host
#   OK: com.anthropic.claude_code_browser_extension.json
#   OK: com.anthropic.claude_browser_extension.json
#   Integrity check: PASS

# If a file was modified:
#   MODIFIED: chrome-native-host
#   Integrity check: FAIL

# If a file was deleted:
#   MISSING: chrome-native-host
#   Integrity check: FAIL
```

### Backup Snapshot

Creates a timestamped backup of all bridge files and registry keys before making changes.

```bash
# Create a snapshot
bash scripts/backup-snapshot.sh
# Output: Backup created: ~/.claude/chrome/backup-20260215-203057 (9 files)

# Restore from a snapshot (nuclear option)
bash scripts/backup-snapshot.sh --restore ~/.claude/chrome/backup-20260215-203057
# Output: Restored 9 files and re-imported registry keys
```

### Resilience Tests

Forced failure testing in isolation. Corrupts files in `/tmp`, verifies detection and repair work, then cleans up. Never touches your real bridge.

```bash
# See what tests would run (safe, no side effects)
bash scripts/test-resilience.sh --dry-run
# Output:
#   Test cases:
#   1. CRLF corruption: corrupt .bat line endings, detect, repair, verify
#   2. Wrapper deletion: delete wrapper, detect missing, regenerate, verify
#   3. Checksum corruption: modify checksummed file, detect mismatch, reinit, verify
#   4. Registry state: detect current registry mode (read-only)

# Actually run the tests (requires explicit confirmation)
bash scripts/test-resilience.sh --confirm
# Output:
#   Setting up isolated test environment at /tmp/chrome-wsl-test-12345...
#   Test 1: CRLF corruption     [PASS]
#   Test 2: Wrapper deletion     [PASS]
#   Test 3: Checksum corruption  [PASS]
#   Test 4: Registry detection   [PASS]
#   Results: 4/4 passed
#   Cleaning up test environment...

# Verbose mode for debugging
bash scripts/test-resilience.sh --confirm --verbose
```

## Common Scenarios

### "The extension stopped working after a Chrome restart"

```bash
# Diagnose
bash scripts/chrome-wsl-health.sh

# If it shows BROKEN or DEGRADED, auto-repair
bash scripts/chrome-wsl-health.sh --repair

# Restart Chrome (close ALL Chrome windows, all profiles)
# Reconnect the extension via chrome://extensions or the /chrome command
```

### "I upgraded Claude Code and the bridge broke"

The dynamic version wrapper handles this automatically. But if something went wrong:

```bash
# Check what version the wrapper detects
bash scripts/version-wrapper.sh --dry-run

# Regenerate the wrapper to pick up the new version
bash scripts/version-wrapper.sh

# Verify the full chain
bash scripts/chrome-wsl-health.sh
```

### "I want to switch back to Desktop temporarily"

```bash
# Record your intent and switch
bash scripts/registry-guard.sh --set-intent desktop
# Then manually restore Desktop's registry entry:
#   reg.exe add "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension" \
#     /ve /t REG_SZ /d "$(cat ~/.claude/chrome/desktop-native-host-original.txt)" /f
# Restart Chrome

# When you want Code back:
bash scripts/registry-guard.sh --set-intent code
bash scripts/registry-guard.sh --fix
# Restart Chrome
```

### "I want to verify everything before making changes"

```bash
# Take a snapshot first
bash scripts/backup-snapshot.sh

# Run the health check
bash scripts/chrome-wsl-health.sh

# Run resilience tests in isolation
bash scripts/test-resilience.sh --confirm

# If everything passes, you're good. If not, restore:
bash scripts/backup-snapshot.sh --restore ~/.claude/chrome/backup-YYYYMMDD-HHMMSS
```

## File Layout

### Windows side (`/mnt/c/Users/$WIN_USER/.claude/chrome/`)

| File | Purpose |
|------|---------|
| `chrome-native-host.bat` | Bridge entry point (CRLF line endings) |
| `com.anthropic.claude_code_browser_extension.json` | Code's native messaging manifest |
| `com.anthropic.claude_browser_extension.json` | Desktop-override manifest (points to our bridge) |
| `bridge.log` | Invocation timestamps and exit codes |

### WSL side (`~/.claude/chrome/`)

| File | Purpose |
|------|---------|
| `chrome-native-host` | Dynamic version wrapper (executable shell script) |
| `desktop-native-host-original.txt` | Backup of Desktop's original registry value |
| `last-known-version.txt` | Fallback version cache |
| `bridge-checksums.sha256` | SHA256 checksums for integrity validation |
| `mode-intent.txt` | User's intended mode (`code` or `desktop`) |
| `repair.log` | Auto-repair action log |
| `backup-YYYYMMDD-HHMMSS/` | Timestamped backup snapshots |

### Windows Registry

| Key | Code Mode | Desktop Mode |
|-----|-----------|--------------|
| `HKCU\...\com.anthropic.claude_code_browser_extension` | Our Code manifest | Our Code manifest |
| `HKCU\...\com.anthropic.claude_browser_extension` | Our bridge manifest (wins the race) | Desktop's original manifest |

## Skill Integration

If you use Claude Code's skill system, the `/chrome-wsl` skill wraps these scripts:

```
/chrome-wsl health          # JSON health report (chrome-wsl-health.sh --json)
/chrome-wsl status          # Full health check (chrome-wsl-health.sh)
/chrome-wsl repair          # Auto-repair (chrome-wsl-health.sh --repair)
/chrome-wsl setup           # First-time bridge setup
/chrome-wsl switch code     # Route extension to Claude Code
/chrome-wsl switch desktop  # Route extension to Claude Desktop
```

The skill looks for scripts via `$CHROME_WSL_BRIDGE_HOME` (defaults to `~/projects/dev/chrome-wsl-bridge`).

## How It Was Built

This project was built using the [SPECTRA methodology](https://github.com/tomcat65/spectra) -- Systematic Planning, Execution via Clean-context loops, Tracking & verification with Real-time Agent orchestration. A unified AI-driven software engineering methodology with cross-model validation:

1. **Discovery** (Haiku) -- Diagnosed the bridge, identified 10 fragility points across 4 risk clusters
2. **Planning** (Opus) -- Designed a 9-task execution plan
3. **Review** (Sonnet) -- Adversarial cross-model review caught 8 critical issues in the initial plan
4. **Building** (Opus) -- Implemented all 9 tasks with revised plan
5. **Verification** (Opus) -- Independent 4-step verification: all 9 tasks PASS

The SPECTRA artifacts are preserved in `.spectra/` for reference.

## License

MIT
