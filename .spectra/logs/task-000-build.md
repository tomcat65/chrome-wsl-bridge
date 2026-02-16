## Build Report -- Task 000: Pre-Flight Backup Snapshot
- Commit: (see combined commit below)
- Tests: Verify command PASS
- Wiring Proof: 5/5 checks passed
- New Files: [scripts/backup-snapshot.sh]
- Modified Files: []
- Dependencies Added: none (bash builtins + reg.exe)
- Notes: Fixed reg.exe export argument order (/y must come after filename). Registry export generates both individual .reg files and a merged registry-backup.reg. Suppressed reg.exe stdout messages for clean output. Creates timestamped backup dirs under ~/.claude/chrome/backup-YYYYMMDD-HHMMSS/. Restore via --restore <dir> works including registry reimport.
