## Build Report -- Task 003: Backup Integrity with SHA256 Checksums
- Commit: (see combined commit below)
- Tests: Verify command PASS (--init then --verify)
- Wiring Proof: 5/5 checks passed
- New Files: [scripts/backup-integrity.sh]
- Modified Files: []
- Dependencies Added: none (sha256sum is standard)
- Notes: Checksums stored in sha256sum-compatible format with appended file path metadata. --verify distinguishes MISSING vs MODIFIED files with distinct messages. Missing checksum file exits code 2 with "Run --init first" message. Default (no args) runs --verify. 4 files checksummed: desktop-native-host-original.txt, chrome-native-host, both manifest JSONs.
