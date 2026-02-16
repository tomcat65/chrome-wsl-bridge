# SPECTRA Execution Plan -- Chrome WSL Bridge Resilience (Revised)

**Level:** 2 (Medium Feature)
**Tasks:** 9
**Estimated Iterations:** 16
**Revision:** Incorporates Reviewer (Sonnet) feedback — 8 critical fixes applied
**Risk-First Order:** Tasks 001-002 are HIGH risk, execute first
**Execution:** SEQUENTIAL (reviewer correctly identified parallelism conflict with checksums)

---

## Task 000: Pre-Flight Backup Snapshot

- [ ] 000: Pre-Flight Backup Snapshot
- AC:
  - Script `scripts/backup-snapshot.sh` creates a timestamped backup directory at `~/.claude/chrome/backup-YYYYMMDD-HHMMSS/`
  - Copies all bridge files: chrome-native-host (wrapper), desktop-native-host-original.txt, and bridge-checksums.sha256 if it exists
  - Copies all Windows-side bridge files: chrome-native-host.bat, both manifest JSONs
  - Exports the two registry keys to a .reg file in the backup directory via `reg.exe export`
  - Prints the backup directory path and file count on success
  - Running with `--restore [dir]` restores all files from a backup directory and re-imports the registry
  - Exit code 0 on success, 1 on failure
- Files: scripts/backup-snapshot.sh
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/backup-snapshot.sh && bash ~/projects/dev/chrome-wsl-bridge/scripts/backup-snapshot.sh 2>&1 | grep -q "Backup created" && exit 0 || exit 1`
- Risk: low
- Max-iterations: 3
- Scope: code
- File-ownership:
  - owns: [scripts/backup-snapshot.sh]
  - touches: []
  - reads: [~/.claude/chrome/chrome-native-host, ~/.claude/chrome/desktop-native-host-original.txt, /mnt/c/Users/$WIN_USER/.claude/chrome/chrome-native-host.bat, /mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_code_browser_extension.json, /mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_browser_extension.json]
- Wiring-proof:
  - CLI: `bash scripts/backup-snapshot.sh` creates snapshot; `bash scripts/backup-snapshot.sh --restore <dir>` restores
  - Integration: Provides rollback safety net before Tasks 001-004 modify bridge files

---

## Task 001: Dynamic Version Wrapper

- [ ] 001: Dynamic Version Wrapper
- AC:
  - Script `scripts/version-wrapper.sh` generates a new `~/.claude/chrome/chrome-native-host` that dynamically detects the latest Claude Code version at invocation time
  - The generated wrapper scans `~/.local/share/claude/versions/` for the highest semver directory and execs it with `--chrome-native-host`
  - On successful invocation, the wrapper writes the used version to `~/.claude/chrome/last-known-version.txt` (graceful fallback source)
  - If no version directory exists, the wrapper falls back to the version in `last-known-version.txt`; if that also fails, exits code 1 with error to stderr AND appends error to bridge.log
  - If the currently-referenced version does not exist but others do, the wrapper auto-selects the highest available
  - The wrapper preserves `#!/bin/sh` shebang and remains POSIX-compatible
  - The wrapper is marked executable (`chmod +x`)
  - A backup of the original wrapper is saved to `~/.claude/chrome/chrome-native-host.bak` before replacement
  - Running with `--dry-run` prints detected version without modifying anything
- Files: scripts/version-wrapper.sh, ~/.claude/chrome/chrome-native-host, ~/.claude/chrome/last-known-version.txt
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/version-wrapper.sh && test -f ~/.claude/chrome/chrome-native-host && exit 0 || exit 1`
- Risk: high
- Max-iterations: 5
- Scope: code
- File-ownership:
  - owns: [scripts/version-wrapper.sh, ~/.claude/chrome/last-known-version.txt]
  - touches: [~/.claude/chrome/chrome-native-host]
  - reads: [~/.local/share/claude/versions/]
- Wiring-proof:
  - CLI: `bash scripts/version-wrapper.sh --dry-run` prints detected version; `bash scripts/version-wrapper.sh` generates the wrapper
  - Integration: After generation, `~/.claude/chrome/chrome-native-host` invokes the same Claude Code binary that `claude --version` reports

---

## Task 002: CRLF-Safe .bat Generator with Error Handling

- [ ] 002: CRLF-Safe .bat Generator with Error Handling
- AC:
  - Script `scripts/generate-bat.sh` creates an enhanced `chrome-native-host.bat` with CRLF line endings
  - The generated .bat includes: `@echo off`, timestamped logging with exit code to bridge.log (`echo %DATE% %TIME% invoked exitcode=%ERRORLEVEL%`), exit code propagation (`exit /b %ERRORLEVEL%`), and pre-flight check that wsl.exe exists
  - The script validates CRLF after writing using: `file <path> | grep -q "CRLF"` — this is the canonical check
  - If CRLF validation fails, the script exits with code 1 and does not leave a corrupted .bat in place (atomic write: write to .bat.tmp, validate, then mv)
  - The generator auto-detects WIN_USER via `cmd.exe /c "echo %USERNAME%"` and WSL_HOME from `$HOME`
  - Running with `--check` validates an existing .bat file's CRLF without overwriting
  - A backup of the original .bat is saved to `chrome-native-host.bat.bak` before replacement
- Files: scripts/generate-bat.sh, /mnt/c/Users/$WIN_USER/.claude/chrome/chrome-native-host.bat
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/generate-bat.sh && file /mnt/c/Users/$WIN_USER/.claude/chrome/chrome-native-host.bat | grep -q "CRLF" && exit 0 || exit 1`
- Risk: high
- Max-iterations: 5
- Scope: code
- File-ownership:
  - owns: [scripts/generate-bat.sh]
  - touches: [/mnt/c/Users/$WIN_USER/.claude/chrome/chrome-native-host.bat]
  - reads: []
- Wiring-proof:
  - CLI: `bash scripts/generate-bat.sh --check` validates CRLF; `bash scripts/generate-bat.sh` regenerates with CRLF guarantee
  - Integration: The .bat file produced is invoked by Chrome native messaging and must cross the WSL boundary via `wsl.exe --exec`

---

## Task 003: Backup Integrity with SHA256 Checksums

- [ ] 003: Backup Integrity with SHA256 Checksums
- AC:
  - Script `scripts/backup-integrity.sh` creates and validates SHA256 checksums for all bridge configuration files
  - Checksums stored in `~/.claude/chrome/bridge-checksums.sha256` in standard `sha256sum` format
  - Files checksummed: desktop-native-host-original.txt, chrome-native-host (wrapper), both manifest JSONs on Windows side
  - Running with `--init` generates checksums (or regenerates after known-good repair)
  - Running with `--verify` checks all files against stored checksums: exits 0 if all match, exits 1 if any mismatch or MISSING, prints per-file status
  - If a checksummed file is MISSING, --verify prints "MISSING: [filename]" and exits 1 (not just "changed")
  - If a checksummed file is MODIFIED, --verify prints "MODIFIED: [filename]" and exits 1
  - If the checksum file itself is missing, `--verify` exits code 2 and prints "No checksums found. Run --init first."
  - Running with no arguments defaults to `--verify`
- Files: scripts/backup-integrity.sh, ~/.claude/chrome/bridge-checksums.sha256
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/backup-integrity.sh && bash ~/projects/dev/chrome-wsl-bridge/scripts/backup-integrity.sh --init && bash ~/projects/dev/chrome-wsl-bridge/scripts/backup-integrity.sh --verify && exit 0 || exit 1`
- Risk: medium
- Max-iterations: 5
- Scope: code
- File-ownership:
  - owns: [scripts/backup-integrity.sh, ~/.claude/chrome/bridge-checksums.sha256]
  - touches: []
  - reads: [~/.claude/chrome/desktop-native-host-original.txt, ~/.claude/chrome/chrome-native-host, /mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_code_browser_extension.json, /mnt/c/Users/$WIN_USER/.claude/chrome/com.anthropic.claude_browser_extension.json]
- Wiring-proof:
  - CLI: `bash scripts/backup-integrity.sh --init` creates checksums; `bash scripts/backup-integrity.sh --verify` validates
  - Integration: Health check (Task 005) calls `--verify` as one of its diagnostic steps

---

## Task 004: Registry Revert Detection and Auto-Recovery

- [ ] 004: Registry Revert Detection and Auto-Recovery
- AC:
  - Script `scripts/registry-guard.sh` detects when the Desktop registry key has been reverted from our bridge manifest
  - Detection compares current registry value against expected bridge manifest path
  - Running with `--check` reports: `CODE_MODE`, `DESKTOP_MODE`, or `UNKNOWN`
  - Running with `--fix` restores registry to Code mode ONLY if `~/.claude/chrome/mode-intent.txt` contains "code" (user intent tracking)
  - If `mode-intent.txt` contains "desktop", `--fix` does nothing (respects user's intentional switch)
  - If `mode-intent.txt` is missing, `--fix` defaults to Code mode and creates the intent file
  - Running `--set-intent code|desktop` explicitly records user's intended mode
  - Logs all repair actions with timestamp to `~/.claude/chrome/repair.log`
  - Validates backup file is non-empty before any operation
  - Exit code 0 means registry matches intent; exit code 1 means mismatch detected (or repair failed)
- Files: scripts/registry-guard.sh, ~/.claude/chrome/repair.log, ~/.claude/chrome/mode-intent.txt
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/registry-guard.sh && bash ~/projects/dev/chrome-wsl-bridge/scripts/registry-guard.sh --check 2>&1 | grep -qE "(CODE_MODE|DESKTOP_MODE|UNKNOWN)" && exit 0 || exit 1`
- Risk: medium
- Max-iterations: 5
- Scope: code
- File-ownership:
  - owns: [scripts/registry-guard.sh, ~/.claude/chrome/repair.log, ~/.claude/chrome/mode-intent.txt]
  - touches: []
  - reads: [~/.claude/chrome/desktop-native-host-original.txt]
- Wiring-proof:
  - CLI: `bash scripts/registry-guard.sh --check` reports mode; `bash scripts/registry-guard.sh --fix` repairs respecting intent; `bash scripts/registry-guard.sh --set-intent code` records user intent
  - Integration: Health check (Task 005) calls `--check` and conditionally `--fix`

---

## Task 005: Comprehensive Health Check Script

- [ ] 005: Comprehensive Health Check Script
- AC:
  - Script `scripts/chrome-wsl-health.sh` runs all bridge health checks and reports unified status
  - 11 checks performed in order: (1) WSL wrapper exists+executable, (2) wrapper uses dynamic version detection, (3) referenced Claude Code version binary exists, (4) .bat bridge exists with valid CRLF (validated via `file <path> | grep -q "CRLF"`), (5) .bat has error handling (exit /b), (6) Code manifest valid+path matches .bat, (7) Desktop-override manifest valid+path matches .bat, (8) Code registry key correct, (9) Desktop registry state vs mode-intent, (10) backup integrity via checksums, (11) bridge.log recent activity (within 7 days)
  - Output: PASS/FAIL/WARN per check, summary line: HEALTHY (all pass), DEGRADED (warnings only), BROKEN (any fail)
  - Exit code 0=healthy, 1=broken, 2=degraded
  - `--json` outputs JSON; `--quiet` prints only summary; `--repair` invokes repair in this order: (1) version-wrapper.sh, (2) generate-bat.sh, (3) registry-guard.sh --fix, (4) backup-integrity.sh --init, then re-runs health check
  - Repair order rationale: version wrapper first (generates the wrapper that .bat invokes), then .bat (needs valid wrapper path), then registry (needs valid manifests), then checksums (captures known-good state after all repairs)
  - If any repair script fails, health check logs the failure, continues with remaining repairs (best-effort), then reports final status
  - Completes in under 10 seconds (measured via `time`)
- Files: scripts/chrome-wsl-health.sh
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/chrome-wsl-health.sh && bash ~/projects/dev/chrome-wsl-bridge/scripts/chrome-wsl-health.sh --quiet 2>&1 | grep -qE "^(HEALTHY|DEGRADED|BROKEN)" && exit 0 || exit 1`
- Risk: medium
- Max-iterations: 8
- Scope: code
- File-ownership:
  - owns: [scripts/chrome-wsl-health.sh]
  - touches: []
  - reads: [scripts/version-wrapper.sh, scripts/generate-bat.sh, scripts/backup-integrity.sh, scripts/registry-guard.sh, all bridge files]
- Wiring-proof:
  - CLI: `bash scripts/chrome-wsl-health.sh` runs all checks; `--repair` fixes and re-checks; `--json` for automation
  - Integration: Primary entry point for standalone use and skill integration (Task 008)

---

## Task 006: Forced Failure and Recovery Test (Isolated)

- [ ] 006: Forced Failure and Recovery Test (Isolated)
- AC:
  - Script `scripts/test-resilience.sh` tests failure modes in an ISOLATED test directory (`/tmp/chrome-wsl-test-$$`)
  - Test setup: copies all bridge files to temp dir, creates mock registry export, sets env vars to redirect scripts to test dir
  - Test cases: (1) corrupt .bat CRLF → detect → repair → verify, (2) delete wrapper → detect → regenerate → verify, (3) corrupt checksum file → detect → reinit → verify, (4) simulate registry state change → detect → report
  - Each test saves state, corrupts, detects, repairs, restores — all within the isolated directory
  - NEVER modifies production bridge files at /mnt/c/ or ~/.claude/chrome/
  - `--dry-run` describes tests without running; `--verbose` shows per-step output
  - Exit code 0 if ALL pass, 1 if any fail; per-test PASS/FAIL output
  - Requires `--confirm` flag to actually run (no accidental execution)
- Files: scripts/test-resilience.sh
- Verify: `test -x ~/projects/dev/chrome-wsl-bridge/scripts/test-resilience.sh && bash ~/projects/dev/chrome-wsl-bridge/scripts/test-resilience.sh --dry-run 2>&1 | grep -q "Test cases:" && exit 0 || exit 1`
- Risk: medium (isolated, not high)
- Max-iterations: 8
- Scope: code
- File-ownership:
  - owns: [scripts/test-resilience.sh]
  - touches: []
  - reads: [scripts/chrome-wsl-health.sh, scripts/version-wrapper.sh, scripts/generate-bat.sh, scripts/backup-integrity.sh, scripts/registry-guard.sh]
- Wiring-proof:
  - CLI: `bash scripts/test-resilience.sh --dry-run` describes; `bash scripts/test-resilience.sh --confirm` executes in isolation
  - Integration: Validates Tasks 001-005 scripts work under failure conditions without touching production

---

## Task 007: End-to-End Integration Validation

- [ ] 007: End-to-End Integration Validation
- AC:
  - All scripts are executable: backup-snapshot.sh, version-wrapper.sh, generate-bat.sh, backup-integrity.sh, registry-guard.sh, chrome-wsl-health.sh, test-resilience.sh
  - `scripts/chrome-wsl-health.sh` completes in under 10 seconds and exits 0
  - `scripts/chrome-wsl-health.sh --json` produces valid JSON (parseable by `python3 -m json.tool`)
  - `scripts/chrome-wsl-health.sh --quiet` produces exactly one summary line
  - Bridge remains functional: wrapper points to valid Claude Code version, .bat has CRLF, registry keys correct
  - bridge.log historical data preserved (pre-existing entries intact)
  - `bridge-checksums.sha256` exists and `--verify` passes
  - `test-resilience.sh --dry-run` succeeds
- Files: (integration -- no new files)
- Verify: `bash ~/projects/dev/chrome-wsl-bridge/scripts/chrome-wsl-health.sh && echo "INTEGRATION PASS" && exit 0 || exit 1`
- Risk: low
- Max-iterations: 3
- Scope: code
- File-ownership:
  - owns: []
  - touches: []
  - reads: [all scripts, all bridge files]
- Wiring-proof:
  - CLI: `bash scripts/chrome-wsl-health.sh` is the definitive integration gate
  - Integration: End-to-end proof that Chrome extension -> .bat -> wsl.exe -> wrapper -> Claude Code chain is intact and all resilience layers active

---

## Task 008: Skill Integration -- Enhanced Status and Repair

- [ ] 008: Skill Integration -- Enhanced Status and Repair
- AC:
  - SKILL.md at `~/.claude/skills/chrome-wsl/SKILL.md` updated with enhanced `status` and `repair` subcommands
  - Backup of original SKILL.md created at `~/.claude/skills/chrome-wsl/SKILL.md.bak` before modification
  - `status` subcommand documents calling `scripts/chrome-wsl-health.sh` from project directory
  - `repair` subcommand documents calling `scripts/chrome-wsl-health.sh --repair`
  - New `health` subcommand added as alias for `status --json`
  - `setup` updated to reference `scripts/version-wrapper.sh` and `scripts/generate-bat.sh`
  - `setup` updated to call `scripts/backup-integrity.sh --init` after setup
  - `argument-hint` updated to include `health`
  - Scripts referenced via `CHROME_WSL_BRIDGE_HOME` env var with fallback to hardcoded project path
  - Skill remains functional for existing subcommands (setup, switch code, switch desktop)
- Files: ~/.claude/skills/chrome-wsl/SKILL.md
- Verify: `grep -q "chrome-wsl-health.sh" ~/.claude/skills/chrome-wsl/SKILL.md && grep -q "health" ~/.claude/skills/chrome-wsl/SKILL.md && exit 0 || exit 1`
- Risk: medium
- Max-iterations: 5
- Scope: code
- File-ownership:
  - owns: []
  - touches: [~/.claude/skills/chrome-wsl/SKILL.md]
  - reads: [all scripts]
- Wiring-proof:
  - CLI: After update, `/chrome-wsl status` invokes health check; `/chrome-wsl repair` invokes with --repair; `/chrome-wsl health` outputs JSON
  - Integration: Skill references scripts via env var; health check orchestrates all sub-scripts

---

## Dependency Graph

```
Task 000 (Backup) --> Task 001 (Version Wrapper) --> Task 002 (CRLF .bat) --> Task 003 (Checksums) --> Task 004 (Registry Guard) --> Task 005 (Health Check) --> Task 006 (Forced Failure) --> Task 007 (E2E Validation) --> Task 008 (Skill Integration)
```

All tasks are SEQUENTIAL per reviewer feedback (checksum conflicts prevent parallelism).

## Reviewer Fixes Applied

| Reviewer Issue | Fix Applied |
|---------------|-------------|
| Broken verify commands (Tasks 001-002) | Changed to test script existence, not features |
| Missing pre-flight backup | Added Task 000 |
| No fallback strategy (Task 001) | Added last-known-version.txt fallback |
| CRLF validation unspecified (Task 002) | Specified `file <path> \| grep -q "CRLF"` |
| Missing file handling (Task 003) | Added explicit MISSING vs MODIFIED distinction |
| TOCTOU race (Task 004) | Added mode-intent.txt for user intent tracking |
| Repair ordering (Task 005) | Specified exact order with rationale |
| Test isolation (Task 006) | Isolated to /tmp, requires --confirm flag |
| Parallelism conflict | Changed to fully sequential |
| Skill modification risk (Task 007) | Moved to end; added backup before modification |
| Performance requirement | Added 10-second time constraint to Task 005 AC |

## Discovery Risk Coverage

| Risk | Severity | Task |
|------|----------|------|
| #1 CRLF drift | HIGH | 002 |
| #2 Registry revert | HIGH | 004 |
| #3 Hardcoded version | MEDIUM | 001 |
| #4 Backup integrity | MEDIUM | 003 |
| #5 Invisible failures | MEDIUM | 005 |
| #6 No auto-repair | MEDIUM | 005 --repair |
| #7 WSL path | LOW | Out of scope |
| #8 Extension IDs | LOW | Out of scope |
| #9 Orphaned versions | MEDIUM | 001 (selects highest) |
| #10 Log rotation | LOW | Out of scope |
