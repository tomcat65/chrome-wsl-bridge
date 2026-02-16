## Build Report -- Task 001: Dynamic Version Wrapper
- Commit: (see combined commit below)
- Tests: Verify command PASS, --dry-run PASS
- Wiring Proof: 5/5 checks passed
- New Files: [scripts/version-wrapper.sh]
- Modified Files: [~/.claude/chrome/chrome-native-host]
- Dependencies Added: none
- Notes: Generated wrapper uses #!/bin/sh POSIX-compatible shebang. Scans ~/.local/share/claude/versions/ for highest semver via sort -t. -k1,1n -k2,2n -k3,3n. Records last-known-version.txt on each successful invocation for fallback. Errors go to both stderr and bridge.log. Original wrapper backed up to .bak before replacement.
