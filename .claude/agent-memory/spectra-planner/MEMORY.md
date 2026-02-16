# Planner Memory -- Chrome WSL Bridge

## Project Architecture
- Bridge chain: Chrome Extension -> Native Messaging -> .bat (Windows, CRLF!) -> wsl.exe --exec -> ~/.claude/chrome/chrome-native-host -> Claude Code binary
- Two registry keys: `com.anthropic.claude_browser_extension` (Desktop, tried FIRST) and `com.anthropic.claude_code_browser_extension` (Code)
- Bridge works by hijacking Desktop's registry key to point to our .bat instead

## Key File Paths
- WSL wrapper: `~/.claude/chrome/chrome-native-host` (hardcodes version 2.1.37)
- Windows .bat: `/mnt/c/Users/TOMAS/.claude/chrome/chrome-native-host.bat`
- Desktop backup: `~/.claude/chrome/desktop-native-host-original.txt`
- Skill: `~/.claude/skills/chrome-wsl/SKILL.md`
- Claude Code versions: `~/.local/share/claude/versions/` (2.1.31, 2.1.34, 2.1.37)

## Critical Constraints
- All Windows-side writes MUST use CRLF line endings
- Pure Bash only, no Python/compiled
- Cross-boundary via cmd.exe, reg.exe, wsl.exe interop
- Bridge must never break during changes

## Planning Decisions (2026-02-15)
- Level 2 plan: constitution.md + plan.md (8 tasks)
- Tasks 001-004 are parallelizable (independent scripts)
- Task 005 orchestrates 001-004 (health check)
- Task 006 is forced failure test (SPECTRA requirement)
- Task 007 integrates into existing skill
- Task 008 is E2E validation (capstone)
- Discovery report identified 10 risks in 4 clusters; plan covers all HIGH/MEDIUM risks
- Auditor found SIGN-008 (backup validation) and SIGN-005 (file ownership) violations; addressed in plan

## Patterns
- Registry is more stable than feared (survived Desktop update to app-1.1.3189)
- Desktop rewrites its own manifest during Squirrel updates but does NOT touch our registry entry
- bridge.log only logs invocation, not success/failure -- health check must probe deeper
