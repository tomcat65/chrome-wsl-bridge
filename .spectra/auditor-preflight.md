# Pre-Flight Audit Report — Chrome WSL Bridge

**Auditor Model:** Haiku 4.5
**Timestamp:** 2026-02-15T19:45:00Z
**Scan Duration:** 180 seconds

---

## Executive Summary

The Chrome WSL Bridge infrastructure is **functional but fragile**. The skill documentation is comprehensive and the bridge has been successfully invoked 11 times, but the implementation has several **critical anti-patterns** and **missing resilience features** that explain why it "keeps breaking."

Three architectural vulnerabilities discovered:
1. **Hardcoded paths** across Windows and WSL that become invalid after system updates
2. **No health check or self-repair automation** — failures must be manually detected and fixed
3. **TOCTOU race condition** in the .bat bridge and registry switching logic

---

## Sign Violations Found

### SIGN-008 Violation: Missing Resilience Before External Dependency Failure

**Finding:** The bridge architecture assumes Desktop's original registry value (at `~/.claude/chrome/desktop-native-host-original.txt`) will always be valid. If:
- Claude Desktop is uninstalled
- Desktop updates its manifest path
- Windows Store updates the registry location
- The backup file is deleted

...then `switch desktop` will silently fail because `ORIGINAL` will be empty or stale.

**Location:** `~/.claude/skills/chrome-wsl/SKILL.md`, lines 157-164 (`switch desktop` subcommand)

**Risk:** User calls `switch desktop` after a Desktop update, command succeeds (no error), but the registry points to a non-existent path. User discovers this only when Chrome is restarted and the extension fails silently.

**Example of problem:**
```bash
ORIGINAL=$(cat "$HOME/.claude/chrome/desktop-native-host-original.txt" 2>/dev/null)
if [ -z "$ORIGINAL" ]; then
  echo "ERROR: No Desktop backup found. Cannot restore."
  exit 1
fi
# ORIGINAL could be valid at cat time but invalid at reg.exe add time
# No validation that ORIGINAL still points to a working manifest
```

---

### SIGN-005 Violation: Implicit File Ownership Conflict

**Finding:** The bridge state is split across multiple ownership boundaries:
- **Windows side:** Registry keys (owned by Chrome/Desktop), manifest JSONs, .bat bridge
- **Linux side:** WSL wrapper script, backup file, logs

If both the existing `chrome-wsl` skill AND a new resilience system attempt to repair the bridge simultaneously, they risk:
- Racing to update the registry (both calling `reg.exe add` on same key)
- Overwriting each other's repair attempts
- One process seeing partial state written by the other

**Location:** Skill documentation assumes single operator; no locking or atomicity guarantees

**Risk:** High during automated health checks or concurrent repair attempts.

---

### Implicit SIGN-001 Risk: Dead Import Pattern

**Finding:** The skill's `repair` subcommand documents running all `status` checks first, but there's no test demonstrating that each status check component is actually used. If the `repair` logic is implemented without tests, developers may:
- Implement `status` parsing but accidentally skip its output
- Add new checks to `status` but forget to update `repair` to handle them
- Create a test that mocks the status output instead of calling it

**Location:** `~/.claude/skills/chrome-wsl/SKILL.md`, lines 222-228

---

## Architecture Vulnerabilities

### 1. Hardcoded Path Brittleness

**WSL native host path** is baked into:
- The .bat bridge: `C:\Windows\system32\wsl.exe --exec ~/.claude/chrome/chrome-native-host`
- The manifest path template: `~/.claude/chrome/chrome-native-host`

**Problem:** If WSL is moved, the user's home directory changes, or Claude Code is reinstalled, these paths break. The bridge will invoke a non-existent script.

**Example failure scenario:**
1. User reinstalls Windows, migrating home to a different mount point
2. WSL native host now at `/home/newmount/$USER/.claude/chrome/chrome-native-host`
3. .bat bridge still points to `~/.claude/chrome/chrome-native-host`
4. Chrome tries to use the extension → WSL exec fails silently
5. User unaware; extension appears broken

**Current mitigation:** None. The .bat bridge is hardcoded by the `setup` command and never updated.

---

### 2. TOCTOU Race in Registry Switching

**Location:** `~/.claude/skills/chrome-wsl/SKILL.md`, lines 138-143 (`switch code` subcommand)

**Race condition:**
1. Thread A: Reads current registry value to check mode
2. Thread B: Updates registry via `reg.exe add` to switch to Desktop
3. Thread A: Reads same registry again, sees value from step 2, reports wrong mode

**Worse case:** If Chrome is running and Chrome's native messaging daemon caches the registry value:
1. User runs `switch code`
2. Script updates registry
3. Chrome's daemon hasn't reloaded yet, still holds old manifest path in memory
4. Extension connects to wrong host
5. User restarts Chrome, now it works, but the switch itself was racy

**No synchronization mechanism exists** to ensure registry updates are reflected before the next extension connection attempt.

---

### 3. Missing Health Check & Automation

**Finding:** The bridge has an explicit logging mechanism (lines 2-3 of `chrome-native-host.bat`), but no corresponding health check system.

**Current state of bridge.log:**
```
Fri 02/13/2026 17:34:07.40 invoked
Fri 02/13/2026 18:28:01.38 invoked
...
Sun 02/15/2026 19:10:11.75 invoked
```

**Questions without answers:**
- Did each invocation succeed? We only know it was attempted.
- If a call failed, what was the error?
- How do we detect bridge breakage between now and the next manual user check?
- No mechanism to auto-repair on next scheduled health check.

**Risk:** The bridge could be broken for days before the user manually runs `status` or tries to use the extension.

---

## Dependency & Configuration Issues

### 1. WSL Distro Assumption

**Location:** `~/.claude/skills/chrome-wsl/SKILL.md`, line 239

**Finding:** Documentation states `wsl.exe --exec uses the default WSL distro`. If the user:
- Has multiple WSL distributions
- Changes the default distro
- WSL installation breaks and is reinstalled with a different default

...the .bat bridge will silently invoke the wrong distro. No validation exists.

---

### 2. Manifest Path Synchronization

**Finding:** Three manifest paths must stay in sync:
- Code manifest: `/mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_code_browser_extension.json`
- Desktop-override manifest: `/mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_browser_extension.json`
- Registry keys pointing to both

If the `setup` command is run twice with changes to `WIN_USER` or paths, the manifests and registry entries can diverge.

---

### 3. Version Mismatch Risk

**Location:** `~/.claude/chrome/chrome-native-host` (the wrapper script)

**Finding:** The wrapper is generated by Claude Code:
```bash
#!/bin/sh
exec "~/.local/share/claude/versions/2.1.37" --chrome-native-host
```

If Claude Code is upgraded:
1. New version written to `~/.local/share/claude/versions/X.Y.Z`
2. Old wrapper still points to 2.1.37
3. If old version is garbage-collected, bridge breaks

**No mechanism** to update the wrapper on Claude Code upgrade.

---

## Non-Goal Risks

No `~/projects/dev/chrome-wsl-bridge/.spectra/non-goals.md` exists yet. Recommend creating one to document:
- Which registry keys are managed by this project vs. Desktop vs. Chrome
- Which platforms are supported (Windows 10/11? WSL2 only?)
- Whether this bridges to Desktop on macOS (it cannot; this is Windows-only)

---

## Deployment & Testing Gaps

### 1. No Integration Test Harness

**Finding:** The skill documentation is detailed, but there's no test suite verifying:
- The .bat bridge actually executes the WSL script
- Registry keys persist across restarts
- `switch code` / `switch desktop` actually changes behavior
- `repair` re-creates missing files without data loss

**Risk:** Regressions could be introduced without detection.

---

### 2. No Error Handling in .bat Bridge

**Current .bat logic:**
```batch
@echo off
echo %DATE% %TIME% invoked >> "C:\Users\$WIN_USER\.claude\chrome\bridge.log"
C:\Windows\system32\wsl.exe --exec ~/.claude/chrome/chrome-native-host
```

**Missing:**
- `if errorlevel 1 exit /b 1` to propagate failure to Chrome
- `if not exist` check before calling wsl.exe
- Timeout handling (wsl.exe can hang indefinitely)
- Fallback behavior on WSL failure

If `wsl.exe` fails, the batch file succeeds with exit code 0, Chrome receives no error, and the extension hangs.

---

### 3. No Status Verification After Switch

**Current flow after `switch code`:**
```bash
reg.exe add "HKCU\\Software\\Google\\Chrome\\..." /ve /t REG_SZ /d "..." /f
# Assume success, report to user
echo "Chrome extension routed to Claude Code."
```

**Missing:**
- Verify `reg.exe` exit code
- Re-read the registry to confirm the change took
- Check that the new manifest file exists before declaring success
- Timeout or retry logic if registry temporarily locked

---

## Advisory for Future Development

1. **Implement a health check daemon** — Monitor bridge.log for failures and auto-repair on next invocation.
2. **Add path validation layer** — Verify all file paths exist before switching modes. Fail loudly rather than silently.
3. **Version the wrapper script** — On Claude Code upgrade, update the wrapper to point to the new binary.
4. **Create an atomic switch operation** — Use temporary files and rename (atomic on NTFS) instead of direct registry updates.
5. **Write integration tests** — Mock the registry and .bat file behavior; verify all state transitions.
6. **Document distro assumption** — Add check in `setup` to warn if multiple WSL distros are configured.
7. **Add timeout to wsl.exe calls** — Prevent Chrome from hanging if WSL becomes unresponsive.
8. **Consider a config file instead of hardcoded paths** — Store bridge state in `~/.claude/chrome/config.json` with paths, versions, modes.

---

## Summary Table

| Issue | Severity | Category | Line(s) |
|-------|----------|----------|---------|
| SIGN-008: No validation before Desktop restore | Critical | Resilience | 157-164 |
| SIGN-005: Implicit file ownership conflict | High | Concurrency | N/A (design) |
| Hardcoded WSL path brittleness | High | Robustness | 3, 72 |
| TOCTOU race in registry switching | Medium | Correctness | 138-143 |
| Missing health check automation | Medium | Observability | N/A |
| Wrapper version mismatch risk | Medium | Maintenance | chrome-native-host |
| No error handling in .bat bridge | Medium | Reliability | .bat file |
| No distro validation | Low | Setup | 239 |

---

## Next Steps for Builder

1. Read the full SKILL.md specification carefully.
2. Review the existing .bat and manifest files on the Windows side.
3. Check the wrapper script version logic.
4. Propose resilience improvements (health check, path validation, atomic switching).
5. Consider whether to add a config layer to make the system less brittle to future Claude Code upgrades.
