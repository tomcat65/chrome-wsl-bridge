## Build Report -- Task 002: CRLF-Safe .bat Generator
- Commit: (see combined commit below)
- Tests: Verify command PASS, --check PASS
- Wiring Proof: 5/5 checks passed
- New Files: [scripts/generate-bat.sh]
- Modified Files: [/mnt/c/Users/TOMAS/.claude/chrome/chrome-native-host.bat]
- Dependencies Added: none
- Notes: Uses printf with \r\n for guaranteed CRLF. Atomic write pattern: writes to .bat.tmp, validates CRLF via `file | grep CRLF`, then mv to final location. Auto-detects WIN_USER via cmd.exe. Includes wsl.exe pre-flight check, timestamped logging with exit code, and exit /b %ERRORLEVEL% propagation. Original .bat backed up to .bak.
