# Plan Review Verdict — Chrome WSL Bridge Resilience

**Reviewer Model:** Sonnet 4.5
**Planner Model:** Opus 4.6
**Timestamp:** 2026-02-15T20:30:00Z
**Review Type:** Planning Gate Review (Adversarial Cross-Model Validation)

---

## VERDICT: REJECTED

The plan has significant structural and execution flaws that will cause predictable failures during autonomous execution. The planner created technically sound individual tasks but failed to address critical integration constraints, verify command ownership conflicts, and ensure SPECTRA compliance.

---

## Critical Blocking Issues

### 1. Task 001 & 002: Verify Commands Are Broken

**Issue:** Both Task 001 and Task 002 have verify commands that call the scripts with flags (`--dry-run`, `--check`) that the scripts themselves must implement, creating a circular dependency.

**Evidence:**
- Task 001 verify: `bash ~/projects/dev/chrome-wsl-bridge/scripts/version-wrapper.sh --dry-run`
- Task 002 verify: `bash ~/projects/dev/chrome-wsl-bridge/scripts/generate-bat.sh --check`

**Problem:** The verify command runs BEFORE the builder has written the script. The script doesn't exist yet. Even if it did, these flags are acceptance criteria features, not verify prerequisites.

**Impact:** Tasks 001 and 002 will immediately fail verification, blocking the entire plan.

**Constitution Violation:** "Every file written to Windows filesystem MUST have CRLF line endings verified before write completes" — Task 002's verify can't validate CRLF if the script doesn't exist.

**Fix Required:** Verify commands must check existence and basic executability, not feature completeness. Example:
```bash
test -x ~/projects/dev/chrome-wsl-bridge/scripts/version-wrapper.sh && exit 0 || exit 1
```

---

### 2. Task 007: File Ownership Conflict — Shared File Modified Without Coordination

**Issue:** Task 007 modifies `~/.claude/skills/chrome-wsl/SKILL.md`, which is marked as "Shared" in the constitution's File Ownership Map. The existing skill is actively used by Claude Code and the user.

**Evidence from Constitution (Line 79):**
> `~/.claude/skills/chrome-wsl/SKILL.md` | Shared | We update; Claude Code invokes

**Problem:**
1. The skill is currently functional and in production use (per discovery.md, the bridge has been invoked 11 times)
2. Modifying it during autonomous execution creates a race condition: if the user runs `/chrome-wsl` while the skill is being updated, they'll get a broken skill
3. No backup or rollback mechanism documented
4. No validation that the updated skill still works with existing bridge state

**SIGN-005 Violation (from auditor-preflight.md):** "File ownership conflict" — both the existing skill AND this project attempt to manage the same file without locking.

**Impact:** User's working skill breaks mid-execution. No recovery path.

**Fix Required:** Either (a) create a new skill file and document manual migration, (b) add explicit backup/restore logic to Task 007 AC, or (c) defer skill integration until Tasks 001-006 are proven working.

---

### 3. Task 005: Missing Forced Failure Implementation

**Issue:** Task 005 is the "Comprehensive Health Check Script" but Task 006 is the "Forced Failure and Recovery Test." The plan ordering suggests Task 005 completes BEFORE Task 006 discovers whether it works under failure.

**Constitution Requirement (Non-Negotiable #2):** "Every repair action MUST be idempotent"

**Problem:** Task 005's `--repair` flag is specified as calling "individual repair scripts (Tasks 001-004) for any failed check" but there's no specification of HOW it calls them or WHAT ORDER it calls them in. If repair scripts have dependencies (e.g., registry-guard needs backup-integrity), Task 005 may call them in the wrong order and fail.

**Discovery Risk #6:** "No automated self-repair; requires manual chrome-wsl repair invocation" — Task 005 is supposed to solve this, but the AC doesn't specify error handling when repair scripts themselves fail.

**Impact:** Task 005 will pass (it generates the script), but Task 006 will discover that `--repair` doesn't work, requiring a rewrite of Task 005. This creates a loop: Task 005 -> Task 006 fail -> go back to Task 005.

**Fix Required:** Task 005 AC must specify repair script invocation order, error handling strategy (fail-fast vs continue), and exit code semantics when repairs partially succeed.

---

### 4. Task 002: CRLF Validation Relies on Undefined Behavior

**Issue:** Task 002 AC states "validates CRLF after writing by checking for `\r\n` sequences using `file` command or hex inspection."

**Problem:** The `file` command output is implementation-dependent across Linux distributions. From discovery.md line 51:
> "Verified via `file` + hex dump"

This suggests the scout used BOTH methods because `file` alone wasn't conclusive.

**Constitution Constraint (Line 33):** "All Windows-side file writes MUST produce CRLF (`\r\n`) line endings"

**Missing from AC:**
1. WHICH `file` command output pattern constitutes success? "CRLF line terminators"? "text/x-msdos"?
2. If `file` is ambiguous, does the script fall back to `od -c` or `hexdump`?
3. If CRLF validation fails, what is the exact error message?

**Impact:** Task 002 builder will make a best-guess implementation. Task 006 testing will discover it doesn't actually detect CRLF corruption reliably. Task 002 reopened.

**Fix Required:** Specify exact validation command and expected output pattern. Example:
```bash
file chrome-native-host.bat | grep -q "CRLF" || { echo "FAIL: Missing CRLF"; exit 1; }
```

---

### 5. Task 003: Checksum File Scope Ambiguity

**Issue:** Task 003 AC states checksums are stored for:
> "desktop-native-host-original.txt, chrome-native-host (wrapper), and the two manifest JSONs on the Windows side"

**Problem:** Which checksums are verified, and which are just stored?

**From auditor-preflight.md (Line 36):** The backup file `desktop-native-host-original.txt` could be "deleted" as a failure mode.

**Scenario:**
1. Task 003 runs, checksums all 4 files, stores in `bridge-checksums.sha256`
2. User deletes `desktop-native-host-original.txt` (accident or disk corruption)
3. Task 005 health check runs `backup-integrity.sh --verify`
4. EXPECTED: Detects missing file, exits 1
5. ACTUAL (per AC): "exits 1 if any mismatch, and prints which files changed"

**Gap:** "Changed" != "Deleted". The AC doesn't specify behavior for missing files.

**Impact:** Task 006 forced failure test will delete the backup file, run `--verify`, and discover it doesn't detect deletion, only modification.

**Fix Required:** AC must explicitly state: "If a checksummed file is missing, --verify exits 1 and prints 'MISSING: [filename]'."

---

### 6. Task 001: Dynamic Version Detection Has No Fallback Strategy

**Issue:** Task 001 AC specifies:
> "If no version directory exists, the wrapper exits with code 1 and writes an error to stderr"

**Problem:** This breaks the bridge HARD. Chrome invokes the .bat, the .bat calls the wrapper, the wrapper exits 1, Chrome extension fails silently.

**From discovery.md Risk #3:** "Wrapper script hardcodes version (2.1.37); upgrade breaks it silently"

**Constitution Non-Negotiable #4:** "The dynamic version wrapper MUST fall back gracefully if no Claude Code version is found"

**AC Contradiction:** The AC says "exit 1" but the constitution says "fall back gracefully."

**Fix Required:** AC must specify fallback behavior. Options:
1. Fall back to a known-good version (requires storing "last working version" somewhere)
2. Fall back to hardcoded `2.1.37` (defeats the purpose but maintains availability)
3. Emit a user-visible error to `bridge.log` and attempt connection anyway (fail loudly, not silently)

**Recommendation:** Use option 1. Add a `~/.claude/chrome/last-known-version.txt` file updated by the wrapper on successful invocation.

---

### 7. Task 004: Registry Revert Detection Has TOCTOU Race

**Issue:** Task 004's `--check` and `--fix` are separate invocations, creating a Time-Of-Check-Time-Of-Use race condition.

**From auditor-preflight.md (Lines 98-114):** TOCTOU race already identified as an architectural vulnerability in the existing skill.

**Task 004 AC:**
> Running with `--check` reports current registry state
> Running with `--fix` restores the registry to Code mode if it has been reverted

**Problem:**
1. Health check (Task 005) calls `registry-guard.sh --check`
2. Reports "DESKTOP_MODE"
3. Health check then calls `registry-guard.sh --fix`
4. Between steps 2 and 3, the user manually runs `switch desktop`
5. `--fix` overwrites the user's intentional change

**Impact:** Auto-repair fights with user intent. No locking mechanism.

**Fix Required:** Task 004 must implement a mode lock file (e.g., `~/.claude/chrome/mode.lock`) that records user's last intentional mode change. `--fix` should only repair if the current registry state doesn't match the lock file AND the lock file timestamp is recent (within 24 hours).

---

### 8. Task 006: Test Script Has No Isolation Mechanism

**Issue:** Task 006's safety check is insufficient:
> "The script refuses to run if the bridge was invoked in the last 60 seconds"

**Problem:** What if the user has Chrome open and the extension is idle? The bridge.log shows the last invocation was 2 hours ago. Test runs, corrupts the .bat file, user tries to use the extension during the test, bridge is broken.

**Constitution Requirement (Non-Negotiable #1):** "The existing bridge MUST continue working during and after all changes"

**Impact:** Task 006 testing will cause bridge downtime. If testing coincides with user activity, the user experiences a broken extension.

**Fix Required:** Task 006 must either:
1. Require an explicit `--force` flag acknowledging the risk, OR
2. Create a temporary parallel bridge infrastructure in a test directory, run all tests there, then tear down, OR
3. Document that Task 006 should only run when the user confirms Chrome is closed

**Recommendation:** Option 2. Create `/tmp/chrome-wsl-test/` with copies of all bridge files, run tests there, never touch production files.

---

## Non-Blocking Issues (Warnings)

### Warning 1: Task 008 Is Not a Real Integration Test

Task 008's verify command is:
```bash
bash ~/projects/dev/chrome-wsl-bridge/scripts/chrome-wsl-health.sh && echo "INTEGRATION PASS" && exit 0 || exit 1
```

This only proves the health check script runs. It doesn't prove the bridge ACTUALLY WORKS end-to-end. A real integration test would:
1. Invoke the .bat file
2. Capture its output
3. Verify Claude Code's native host process started
4. Send a test MCP message
5. Verify response

**Recommendation:** Add an AC to Task 008: "Running a test MCP message through the bridge succeeds and returns a valid response."

---

### Warning 2: No Task Validates SKILL.md References Are Correct

Task 007 updates SKILL.md to reference scripts at:
> `~/projects/dev/chrome-wsl-bridge/scripts/`

But what if this project is cloned to a different path? The skill will break.

**Recommendation:** Task 007 AC should specify: "The SKILL.md uses environment variable `$CHROME_WSL_BRIDGE_HOME` or detects the script path dynamically via `dirname $0` or similar."

---

### Warning 3: Task 005 Health Check Performance Requirement Unverified

Constitution requires:
> "Health check script must complete in under 10 seconds (all checks)"

But Task 005 doesn't have a performance acceptance criterion. If the builder writes an inefficient script that takes 30 seconds, it passes all ACs but violates the constitution.

**Recommendation:** Add AC to Task 005: "Running the health check completes in under 10 seconds (measured via `time` command)."

---

### Warning 4: Parallelism Claim Is Overstated

The plan states:
> **Recommendation:** TEAM_ELIGIBLE -- Tasks 001-004 can execute simultaneously with 4 builders

**Problem:** All 4 tasks touch the same bridge infrastructure. Task 001 modifies the wrapper, Task 002 modifies the .bat, Task 003 checksums all files, Task 004 modifies the registry. If executed in parallel, they'll create a race:
1. Task 003 checksums the wrapper
2. Task 001 replaces the wrapper
3. Task 003's checksum is now stale

**Impact:** Task 005 health check will fail because checksums don't match modified files.

**Fix Required:** Remove parallelism claim. Tasks 001-004 must execute sequentially, or Task 003 must run AFTER Tasks 001-002-004 complete.

---

## Missing from Plan

### Missing 1: No Rollback Strategy

Constitution Non-Negotiable #1 states the bridge must continue working. But there's no rollback plan if a task breaks the bridge.

**Recommendation:** Add a Task 000 (pre-flight) that creates a snapshot backup of ALL bridge files (wrapper, .bat, manifests, registry export, backup file) to `~/.claude/chrome/backup-[timestamp]/`. If any task fails, the user can restore from snapshot.

---

### Missing 2: No Version Cleanup (Discovery Risk #9)

Discovery.md Risk #9:
> "Version directory deleted without cleanup leaves broken symlink"

Plan Task 001 addresses dynamic version detection, but doesn't address cleanup of orphaned version directories.

**Gap:** If `~/.local/share/claude/versions/2.1.35/` exists but is no longer used, it wastes disk space. If it's deleted WHILE the wrapper is using it, the bridge breaks mid-session.

**Recommendation:** Add a subtask to Task 001 or a new Task 009: "Orphaned version cleanup script that warns about unused versions but doesn't delete them (requires user confirmation)."

---

### Missing 3: No Logging Enhancement

Discovery.md Risk #10 (log rotation) is marked "out of scope," but discovery.md Lines 138-141 note:
> "Only logs invocation timestamp, not success/failure. No error handling (stderr not captured)."

Task 002 enhances the .bat with error handling (`exit /b %ERRORLEVEL%`), but doesn't enhance logging to capture success/failure.

**Recommendation:** Task 002 AC should add: "The .bat logs exit code to bridge.log after each invocation."

---

## Risk Assessment of Proceeding As-Is

**If this plan executes without revision:**

1. **Tasks 001-002 will fail immediately** due to broken verify commands
2. **Task 005 will pass but produce a broken health check** due to unspecified repair ordering
3. **Task 006 will fail** when forced failure tests reveal Task 005's repair doesn't work
4. **Task 007 will break the user's working skill** with no rollback
5. **Task 008 will falsely report success** despite integration failures

**Estimated rework iterations:** 8-12 (nearly doubling the plan's estimated 14 iterations)

**Probability of autonomous success:** <20%

**User impact:** High risk of bridge downtime, broken skill, and wasted budget

---

## Recommendations for Planner

### Immediate Fixes Required (Blocking)

1. **Rewrite Task 001 & 002 verify commands** to check script existence/executability, not features
2. **Move Task 007 (Skill Integration) to end** — make it Task 009, execute only after Tasks 001-006 proven working
3. **Add fallback strategy to Task 001** per constitution Non-Negotiable #4
4. **Add repair ordering and error handling** to Task 005 AC
5. **Add CRLF validation specifics** to Task 002 AC
6. **Add missing file handling** to Task 003 AC
7. **Add mode lock mechanism** to Task 004 to prevent TOCTOU race
8. **Isolate Task 006 testing** to avoid production bridge disruption

### Enhancements (Non-Blocking but Recommended)

9. Add Task 000: Pre-flight backup snapshot
10. Add performance requirement to Task 005 AC
11. Remove parallelism claim; make Tasks 001-004 sequential or 003 after 001-002-004
12. Add real end-to-end test to Task 008 (MCP message round-trip)
13. Add orphaned version cleanup to scope

---

## Conclusion

The planner demonstrated strong technical understanding of the bridge architecture and correctly identified all risks from discovery.md. However, the plan fails SPECTRA compliance in several critical areas:

1. **Verify commands don't verify** (they test features that don't exist yet)
2. **File ownership conflicts ignored** (Task 007 modifies shared file without coordination)
3. **Constitution requirements contradicted** (Task 001 exit-on-failure vs "fall back gracefully")
4. **TOCTOU races not addressed** (Task 004 inherits existing race from auditor findings)
5. **Forced failure testing comes too late** (Task 006 after Task 005, creating rework loop)

**This plan will fail autonomous execution.** Recommend returning to planner for revision before executing.

---

**Reviewer Signature:** Sonnet 4.5
**Prompt Hash:** sha256:7f4e3c9a2b1d8e6f5a4c3b2d1e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f
**Review Complete:** 2026-02-15T20:45:00Z
