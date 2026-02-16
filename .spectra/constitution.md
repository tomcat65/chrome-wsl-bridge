# Constitution -- Chrome WSL Bridge Resilience

**Project:** Chrome WSL Bridge Health Check and Auto-Repair System
**Level:** 2 (Medium Feature, 1-3 days)
**Date:** 2026-02-15

---

## What This Project IS

- A health check and auto-repair system for the Chrome WSL Bridge
- A set of Bash scripts that validate, diagnose, and fix bridge components
- An enhancement to the existing `/chrome-wsl` skill with deeper status checks and automated repair
- A dynamic version wrapper that survives Claude Code upgrades without manual intervention
- A registry revert detector that catches and recovers from Windows/Desktop overwrites
- A CRLF integrity validator that prevents silent .bat corruption

## What This Project Is NOT

- NOT a rewrite of the bridge architecture (the .bat -> wsl.exe -> wrapper -> binary chain stays)
- NOT a daemon or background service (all checks are on-demand or skill-invoked)
- NOT a replacement for the existing `/chrome-wsl` skill (it enhances the skill)
- NOT a cross-platform solution (Windows 11 + WSL2 only)
- NOT responsible for Chrome extension behavior or Chrome's native messaging internals
- NOT a monitoring dashboard or notification system

## Technology Constraints

| Constraint | Requirement |
|-----------|-------------|
| Language | Pure Bash/POSIX shell scripts only. No Python, Node, compiled binaries. |
| Cross-boundary | All Windows operations via `cmd.exe`, `reg.exe`, `wsl.exe` interop from WSL2 |
| Line endings | All Windows-side file writes MUST produce CRLF (`\r\n`) line endings |
| File paths | Windows paths use backslashes in registry/JSON, forward slashes via /mnt/c/ in scripts |
| Registry | Read/write via `reg.exe` from WSL. No PowerShell dependency. |
| Checksums | SHA256 via `sha256sum` (available in all WSL distros) |

## Performance Requirements

- Health check script must complete in under 10 seconds (all checks)
- Individual repair operations must complete in under 5 seconds each
- No persistent processes or daemons -- all invocations are one-shot
- Bridge invocation path (the .bat itself) must add zero overhead to Chrome extension startup

## Security Requirements

- No secrets stored in any file (registry paths and file paths are not secrets)
- No network calls -- everything is local filesystem and registry
- Backup integrity validated via SHA256 checksums stored alongside backup data
- No elevation required -- all operations run as the current user (HKCU, not HKLM)

## Integration Boundaries

| Boundary | This Project Controls | External System Controls |
|----------|----------------------|-------------------------|
| Registry keys | Read, validate, repair HKCU NativeMessagingHosts entries | Chrome reads these keys; Desktop may overwrite them during updates |
| .bat bridge | Validate CRLF, enhance error handling | Chrome invokes this file via native messaging |
| WSL wrapper | Replace with dynamic version detection | Claude Code generates the original; upgrades may regenerate |
| Manifests | Validate JSON content and path correctness | Chrome reads manifests; Desktop may install competing ones |
| Skill SKILL.md | Update with enhanced status/repair logic | Claude Code invokes skill based on user commands |
| bridge.log | Read for health diagnostics | .bat bridge appends entries on each invocation |

## Non-Negotiables

1. The existing bridge MUST continue working during and after all changes -- never break what works
2. Every repair action MUST be idempotent -- running repair twice produces the same result
3. Every file written to Windows filesystem MUST have CRLF line endings verified before write completes
4. The dynamic version wrapper MUST fall back gracefully if no Claude Code version is found
5. Health check output MUST be human-readable and machine-parseable (exit codes)
6. All scripts MUST be executable standalone (no sourcing required, proper shebangs)

## File Ownership Map (Project Scope)

| File | Owner | Notes |
|------|-------|-------|
| `scripts/chrome-wsl-health.sh` | This project | New: standalone health check |
| `scripts/generate-bat.sh` | This project | New: CRLF-safe .bat generator |
| `scripts/version-wrapper.sh` | This project | New: dynamic version wrapper generator |
| `~/.claude/chrome/chrome-native-host` | Shared | Claude Code generates; we replace with dynamic version |
| `/mnt/c/.../chrome-native-host.bat` | Shared | We enhance; Chrome invokes |
| `~/.claude/chrome/desktop-native-host-original.txt` | Shared | We add checksum; skill reads |
| `~/.claude/chrome/bridge-checksums.sha256` | This project | New: integrity checksums |
| `~/.claude/skills/chrome-wsl/SKILL.md` | Shared | We update; Claude Code invokes |
