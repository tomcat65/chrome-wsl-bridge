# Discovery Report — Chrome WSL Bridge Resilience Project

**Scout Model:** Haiku 4.5
**Timestamp:** 2026-02-15T20:15:00Z
**Project Type:** Brownfield Infrastructure (Mid-Execution Repair)
**Project Status:** Currently WORKING but FRAGILE

---

## Executive Summary

The Chrome WSL Bridge is a critical infrastructure component that connects the Claude in Chrome extension (Windows) to Claude Code (WSL2) via Windows native messaging. Current verification shows **all components functioning** (CRLF correct, registry correct, manifests valid, native host responding). However, the bridge lacks defensive infrastructure to survive Windows updates, Claude Code version changes, or accidental file corruption. This investigation identified **10 fragility points organized into 4 risk clusters**, requiring architectural hardening across Registry resilience, File integrity, Version management, and Operational monitoring.

---

## Tech Stack & Infrastructure

| Component | Technology | Version | Status |
|-----------|-----------|---------|--------|
| OS (Host) | Windows 11 with WSL2 | 5.15.167 | OK |
| OS (Guest) | Linux (WSL distro) | Ubuntu-like | OK |
| CLI Runtime | Claude Code | 2.1.37 | OK |
| Bridge Protocol | Windows Native Messaging (stdio) | - | OK |
| Intermediate Transport | wsl.exe --exec | - | OK |
| Configuration | JSON manifests + Registry | - | OK |
| Integration Point | Chrome MCP native host | - | VERIFIED |

### Current Architecture

```
Chrome Extension (Windows)
  ↓ Native Messaging
  ├─ Tries: com.anthropic.claude_browser_extension (Desktop) [FIRST]
  └─ Falls back to: com.anthropic.claude_code_browser_extension (Code)
      ↓ Registry lookup finds manifest
      ↓ Manifest points to .bat bridge
  /mnt/c/Users/TOMAS/.claude/chrome/chrome-native-host.bat
      ↓ wsl.exe --exec (crosses Windows/WSL boundary)
  /home/tomcat65/.claude/chrome/chrome-native-host (wrapper shell script)
      ↓ Wrapper calls versioned binary
  /home/tomcat65/.local/share/claude/versions/2.1.37 (Claude Code binary)
      ↓ Native host mode (--chrome-native-host flag)
  Claude Code native host process (handles MCP requests)
```

### Verified Components

| Component | Path | Status | Evidence |
|-----------|------|--------|----------|
| WSL native host wrapper | `~/.claude/chrome/chrome-native-host` | ✓ EXISTS | Calls `2.1.37` correctly |
| Windows .bat bridge | `/mnt/c/Users/TOMAS/.claude/chrome/chrome-native-host.bat` | ✓ EXISTS + CRLF | Verified via `file` + hex dump |
| Code manifest | `/mnt/c/Users/TOMAS/.claude/chrome/com.anthropic.claude_code_browser_extension.json` | ✓ VALID | Path matches .bat |
| Desktop-override manifest | `/mnt/c/Users/TOMAS/.claude/chrome/com.anthropic.claude_browser_extension.json` | ✓ VALID | Points to bridge .bat |
| Desktop backup | `~/.claude/chrome/desktop-native-host-original.txt` | ✓ EXISTS | Contains original registry path |
| Registry (Code) | `HKCU\...\com.anthropic.claude_code_browser_extension` | ✓ CORRECT | Points to Code manifest |
| Registry (Desktop) | `HKCU\...\com.anthropic.claude_browser_extension` | ✓ ACTIVE | Points to bridge manifest (Code mode) |
| Bridge log | `/mnt/c/Users/TOMAS/.claude/chrome/bridge.log` | ✓ RECENT | Invoked Feb 15 19:10 |
| Native host connectivity | Via stdio test | ✓ RESPONDS | Socket created, MCP responds |

---

## Risk Manifest

| # | Risk | Category | Severity | Spike Needed? | Impact |
|---|------|----------|----------|---------------|--------|
| 1 | CRLF line endings lost when .bat edited from WSL | File Integrity | HIGH | YES | Silent batch script failure, bridge breaks silently |
| 2 | Windows Update or Desktop upgrade reverts registry to Desktop mode | Registry Stability | HIGH | YES | Chrome reconnects to Desktop, user loses Code tools |
| 3 | Wrapper script hardcodes version (2.1.37); upgrade breaks it silently | Version Management | MEDIUM | YES | Old Claude Code version used after upgrade |
| 4 | Desktop backup file has no integrity check (no checksum/signature) | Data Integrity | MEDIUM | YES | Corrupted backup prevents restore to Desktop mode |
| 5 | Bridge failures invisible to user; only discovered on use attempt | Monitoring | MEDIUM | YES | Unknown downtime, lost productivity |
| 6 | No automated self-repair; requires manual `chrome-wsl repair` invocation | Operational | MEDIUM | YES | User must diagnose and repair manually |
| 7 | WSL distro path hardcoded (/home/tomcat65); changes break bridge | Path Management | LOW | NO | Low risk (WSL config stable after setup) |
| 8 | Extension IDs hardcoded; extension replacement would break manifests | Extension Stability | LOW | NO | Very low risk (official extension IDs stable) |
| 9 | Version directory deleted without cleanup leaves broken symlink | Cleanup | MEDIUM | YES | Old version garbage causes silent failures |
| 10 | bridge.log grows indefinitely; no rotation mechanism | Log Management | LOW | NO | Cosmetic (growth rate is 6 entries/day) |

### Risk Clustering

**Cluster A: Registry & Windows Stability**
Risks #2, #8
Impact: Loss of bridge connection if Windows reverts registry
Requires: Registry backup validation, periodic health checks

**Cluster B: File Corruption & Integrity**
Risks #1, #4, #9
Impact: Silent bridge failures from corrupted files
Requires: Write-protection, integrity checks, version cleanup automation

**Cluster C: Version & Path Management**
Risks #3, #6, #7
Impact: Bridge breaks on upgrade or distro reconfiguration
Requires: Dynamic version detection, environment variable use

**Cluster D: Operational Monitoring & Recovery**
Risks #5, #6, #10
Impact: Unknown failures, manual recovery required
Requires: Health check daemon, auto-repair triggers, log rotation

---

## Existing Infrastructure

### Skill: `chrome-wsl` (SKILL.md)

**Location:** `/home/tomcat65/.claude/skills/chrome-wsl/SKILL.md`

**Capabilities:**
- `setup` — Full first-time bridge configuration (creates .bat, manifests, registry entries, backup)
- `status` — Check all components (8 tests across WSL, Windows, registry, version)
- `repair` — Re-run failed setup steps while preserving active mode (Code/Desktop)
- `switch code` — Route Chrome to Claude Code (modifies registry)
- `switch desktop` — Restore Chrome to Desktop (uses backup)

**Strengths:**
- Comprehensive setup protocol
- Clear separation of concerns (setup, status, repair, switch)
- Backup/restore mechanism for registry
- Verification steps in status subcommand

**Gaps:**
- No health check daemon (manual invocation only)
- No auto-repair trigger on failure detection
- Status only reports, doesn't fix silently
- CRLF integrity not checked during status
- No version validation (hardcoding risk #3)
- No registry revert detection (risk #2)

### Bridge Log

**Location:** `/mnt/c/Users/TOMAS/.claude/chrome/bridge.log`

**Current State:**
- 12 invocations logged
- Time range: Feb 13 17:34 to Feb 15 19:10
- Invocation rate: ~6 invocations/day
- Recent activity confirms bridge is in use

**Limitations:**
- Only logs invocation timestamp, not success/failure
- No error handling (stderr not captured)
- No log rotation

### Desktop Backup

**Location:** `~/.claude/chrome/desktop-native-host-original.txt`

**Content:** Original Desktop registry path (from Feb 13 17:33 setup)

**State:** Intact and readable

**Risk:** No integrity verification (risk #4)

---

## Implementation Preferences (Detected)

From examining SKILL.md and existing bridge files:

1. **Tool Invocation Pattern:** Skill-based (command-line subcommands), not daemon-based
2. **Cross-Platform Compatibility:** Explicit Windows/WSL handling (cmd.exe, wsl.exe, registry)
3. **Scripting Language:** Bash (POSIX-compatible)
4. **Configuration Format:** JSON manifests + Windows Registry (read/write via `reg.exe`)
5. **Backup Strategy:** Text file backup (simple, human-readable)
6. **Logging:** Append-only log with timestamp (DOS `echo %DATE% %TIME%`)
7. **Error Handling:** Exit codes + descriptive messages
8. **Naming Convention:** Snake_case for filenames, camelCase for JSON keys
9. **Path Convention:** Forward slashes in Windows paths (via WSL, cross-platform)

---

## Proposed Spike Tasks

### Spike 1: CRLF Write-Protection & Validation
**Risk:** #1 (CRLF Drift Risk)
**Unknown:** How to ensure .bat file maintains CRLF when edited/regenerated from WSL?
**Investigation:**
1. Test current .bat edit behavior when modified from WSL (vi, sed, Write tool)
2. Explore write-protection options:
   - Read-only attribute via `attrib +r` (prevents accidental modification)
   - Checksum validation in status check (detects corruption)
   - SHA256 hash stored in backup file (repair can validate/fix)
3. Implement pre-flight check in bridge invocation (early failure detection)
4. Add CRLF test to `status` subcommand
**Deliverable:** CRLF validation in status check + repair step that re-writes with CRLF guarantee
**Time Box:** 2 iterations

### Spike 2: Registry Revert Detection & Recovery
**Risk:** #2 (Registry Revert Risk)
**Unknown:** Can we detect if Windows has reverted the registry key? Can we auto-repair?
**Investigation:**
1. Design registry checksum or version marker (stored in backup alongside original Desktop path)
2. Add registry integrity check to `status` (compare current vs expected)
3. Implement auto-recovery: if Desktop's registry reverted, automatically switch back to Code mode
4. Test against simulated registry revert (manually restore Desktop value, verify auto-fix)
5. Consider periodic background check (daemon vs cron job)
**Deliverable:** Registry revert detector in status + auto-recovery in repair
**Time Box:** 3 iterations

### Spike 3: Dynamic Version Detection & Cleanup
**Risk:** #3 (Wrapper Script Hardcoding), #9 (Version Mismatch Detection)
**Unknown:** How to make wrapper script detect latest Claude Code version automatically?
**Investigation:**
1. Examine how `claude --version` discovers current version
2. Design dynamic wrapper that queries version at invocation time (instead of hardcoding)
3. Implement version cleanup: detect orphaned version directories, warn on status, clean on repair
4. Test upgrade scenario: install new Claude Code version, verify wrapper auto-updates
5. Validate old version still works (no breaking changes in --chrome-native-host API)
**Deliverable:** Dynamic version detection in wrapper + version cleanup in repair
**Time Box:** 3 iterations

### Spike 4: Data Integrity & Backup Validation
**Risk:** #4 (Desktop Backup Integrity)
**Unknown:** How to detect/fix corrupted backup files?
**Investigation:**
1. Add integrity metadata to backup file (SHA256 of original Desktop registry value)
2. Implement validation in status check (verify backup hash)
3. Recovery strategy if backup corrupted:
   - Option A: Fall back to Desktop's current registry value (may not be original)
   - Option B: Require manual restore via `switch desktop --force` with user confirmation
4. Test corruption scenarios (partial write, disk error simulation)
**Deliverable:** Backup integrity check in status + repair strategy for corrupted backups
**Time Box:** 2 iterations

### Spike 5: Health Check Daemon & Auto-Repair
**Risk:** #5 (Monitoring), #6 (Repair Automation)
**Unknown:** Should the health check be a daemon, cron job, or triggered on-demand?
**Investigation:**
1. Evaluate options:
   - Daemon: Runs continuously, detects failures in real-time (but uses resources)
   - Cron: Runs periodically (e.g., every hour), detects failures with lag
   - On-demand: Triggered by `/chrome` command or user invocation (simplest, least overhead)
2. Design health check probe (lightweight test of bridge connectivity)
3. If on-demand: add auto-repair flag to `/chrome` command
4. If daemon/cron: define recovery actions (restart, switch mode, notify user)
5. Test failure scenarios (missing .bat, broken registry, version mismatch)
**Deliverable:** Health check implementation + integration point for auto-repair
**Time Box:** 4 iterations

### Spike 6: End-to-End Resilience Testing
**Risk:** All risks collectively
**Unknown:** What does the bridge look like under failure modes?
**Investigation:**
1. Create test matrix of failure scenarios:
   - Missing .bat file
   - Corrupted CRLF in .bat
   - Registry reverted to Desktop
   - Version directory deleted
   - Backup file corrupted
   - WSL distro path changed
2. For each failure, verify:
   - How user detects (error message, silent failure, etc.)
   - How `status` reports it
   - How `repair` fixes it
3. Implement end-to-end test suite (simulates each failure, runs repair, verifies fix)
**Deliverable:** Failure mode documentation + test suite
**Time Box:** 3 iterations

---

## Recommendations for Planner

### Priority 1 (Critical Path to Resilience)
1. **Spike 1 (CRLF)** — HIGHEST PRIORITY
   - Risk #1 is HIGH severity and most likely to occur (any WSL edit)
   - Easy to implement (validation + re-write logic)
   - Unblocks Spike 2 (needs stable .bat file)

2. **Spike 2 (Registry Revert)**
   - Risk #2 is HIGH severity and likely in real-world Windows usage
   - Requires detection + auto-recovery mechanism
   - Unblocks Spike 5 (health check daemon)

3. **Spike 3 (Dynamic Version)**
   - Risk #3 is MEDIUM but will surface immediately after Claude Code upgrade
   - Unblocks version cleanup (Spike 3 includes #9)
   - Integrates with auto-repair (Spike 5)

### Priority 2 (Completeness)
4. **Spike 4 (Backup Integrity)**
   - Risk #4 is MEDIUM; adds robustness to registry restore path
   - Can run in parallel with Spike 2 (independent)

5. **Spike 5 (Health Check & Auto-Repair)**
   - Depends on Spikes 1-3 (stable components to check)
   - Enables fully autonomous resilience (no user action needed)
   - Consider on-demand health check first (lighter weight)

### Priority 3 (Validation & Documentation)
6. **Spike 6 (End-to-End Testing)**
   - Validates all spike implementations
   - Creates runbook for future maintenance
   - Runs last (depends on all other spikes)

### Architecture Decisions
- **Health Check Trigger:** Recommend on-demand (via `/chrome` command) initially; can upgrade to daemon later if needed
- **Version Detection:** Query `claude --version` at wrapper invocation time (solves hardcoding risk)
- **Registry Backup:** Add SHA256 integrity field to backup file (simple, effective)
- **Log Rotation:** Defer (low priority; growth rate is manageable)

### Workstream Organization
- **Spikes 1-3:** Sequential (1 unblocks 2, both unblock 3)
- **Spike 4:** Parallel with Spikes 2-3 (independent)
- **Spike 5:** Depends on Spikes 1-3; can start once 1 complete
- **Spike 6:** Depends on all prior spikes

**Estimated Timeline:**
- Spikes 1-3: ~8 iterations (2+3+3)
- Spike 4: ~2 iterations (parallel, same time as part of 2-3)
- Spike 5: ~4 iterations (after 1-3 complete)
- Spike 6: ~3 iterations (final validation)
- **Total: ~13 iterations** (aggressive parallel schedule)

---

## Testing Unknowns → Spike Mapping

| Unknown | Why Test It | Spike | Test Strategy |
|---------|-------------|-------|----------------|
| Does CRLF survive WSL edits? | Risk #1: CRLF loss | Spike 1 | Edit .bat via WSL (vi/sed), verify CRLF with `file` command |
| Does Windows auto-revert registry? | Risk #2: Registry revert | Spike 2 | Manually revert registry, check if status detects |
| Can wrapper detect version dynamically? | Risk #3: Hardcoding | Spike 3 | Symlink /latest to current version, test with multiple versions |
| Is backup corruption detectable? | Risk #4: Silent backup corruption | Spike 4 | Corrupt backup file, verify status catches it |
| Can bridge detect own failure? | Risk #5: Invisible failures | Spike 5 | Simulate failures (remove .bat, break registry), run health check |
| Can repair fix all failure modes? | Risk #6: Manual recovery only | Spike 5 | For each failure mode, run repair and verify fix |

---

## Sign-Off

The Chrome WSL Bridge is **currently functional** but **operationally fragile**. The core architecture is sound (Windows native messaging → WSL wrapper → Claude Code native host), and all components are verified working. However, without defensive infrastructure, the bridge is vulnerable to:

- **Silent failures** (CRLF corruption, version mismatch)
- **External interference** (Windows updates, registry revert)
- **Data loss** (corrupted backup prevents Desktop mode restore)
- **Unknown downtime** (no monitoring)

The proposed 6-spike plan addresses all identified risks through incremental hardening:
1. File integrity (CRLF, backup)
2. Registry resilience (revert detection, auto-recovery)
3. Version automation (dynamic detection, cleanup)
4. Operational automation (health checks, auto-repair)

**Recommendation:** Proceed with Spikes 1-3 immediately (critical path); parallelize Spike 4; complete Spike 5 for full automation; validate with Spike 6.

---

**Report Status:** READY FOR PLANNER
**Scout Confidence:** HIGH (all components verified, unknowns well-bounded)
**Next Step:** Planner to prioritize and schedule spikes; Builder to implement each spike

