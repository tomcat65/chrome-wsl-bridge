## Build Report -- Task 004: Registry Revert Detection and Auto-Recovery
- Commit: (see combined commit below)
- Tests: Verify command PASS
- Wiring Proof: 5/5 checks passed
- New Files: [scripts/registry-guard.sh]
- Modified Files: []
- Dependencies Added: none (uses reg.exe)
- Notes: --check reports CODE_MODE, DESKTOP_MODE, or UNKNOWN based on registry values. --fix restores Code mode only if mode-intent.txt contains "code" or is missing (defaults to code). Respects "desktop" intent. Validates desktop-native-host-original.txt is non-empty before operations. All repair actions logged to repair.log with timestamps. --set-intent code|desktop records user preference.
