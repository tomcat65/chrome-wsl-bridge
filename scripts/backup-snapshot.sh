#!/bin/bash
# backup-snapshot.sh - Pre-flight backup snapshot for Chrome WSL Bridge
# Creates timestamped backup of all bridge files and registry keys
# Usage: backup-snapshot.sh [--restore <dir>]

set -euo pipefail

WSL_CHROME_DIR="$HOME/.claude/chrome"
WIN_USER="TOMAS"
WIN_CHROME_DIR="/mnt/c/Users/${WIN_USER}/.claude/chrome"

# Registry key paths
REG_CODE="HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.anthropic.claude_code_browser_extension"
REG_DESKTOP="HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.anthropic.claude_browser_extension"

usage() {
    echo "Usage: $0 [--restore <backup-dir>]"
    echo ""
    echo "  No arguments: create a timestamped backup"
    echo "  --restore <dir>: restore all files from a backup directory"
    exit 1
}

create_backup() {
    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_dir="${WSL_CHROME_DIR}/backup-${timestamp}"

    mkdir -p "$backup_dir"

    local file_count=0

    # Copy WSL-side bridge files
    for f in chrome-native-host desktop-native-host-original.txt bridge-checksums.sha256; do
        if [ -f "${WSL_CHROME_DIR}/${f}" ]; then
            cp -p "${WSL_CHROME_DIR}/${f}" "$backup_dir/"
            file_count=$((file_count + 1))
        fi
    done

    # Copy Windows-side bridge files
    for f in chrome-native-host.bat com.anthropic.claude_code_browser_extension.json com.anthropic.claude_browser_extension.json; do
        if [ -f "${WIN_CHROME_DIR}/${f}" ]; then
            cp -p "${WIN_CHROME_DIR}/${f}" "$backup_dir/"
            file_count=$((file_count + 1))
        fi
    done

    # Export registry keys
    local reg_file="${backup_dir}/registry-backup.reg"
    {
        reg.exe export "$REG_CODE" "$(wslpath -w "${backup_dir}/reg-code.reg")" /y >/dev/null 2>&1 || true
        reg.exe export "$REG_DESKTOP" "$(wslpath -w "${backup_dir}/reg-desktop.reg")" /y >/dev/null 2>&1 || true
    }

    # Merge reg files if they exist
    if [ -f "${backup_dir}/reg-code.reg" ] || [ -f "${backup_dir}/reg-desktop.reg" ]; then
        cat "${backup_dir}"/reg-*.reg > "$reg_file" 2>/dev/null || true
        file_count=$((file_count + 1))
    fi

    echo "Backup created: ${backup_dir}"
    echo "Files backed up: ${file_count}"
}

restore_backup() {
    local backup_dir="$1"

    if [ ! -d "$backup_dir" ]; then
        echo "Error: Backup directory does not exist: $backup_dir" >&2
        exit 1
    fi

    # Restore WSL-side files
    for f in chrome-native-host desktop-native-host-original.txt bridge-checksums.sha256; do
        if [ -f "${backup_dir}/${f}" ]; then
            cp -p "${backup_dir}/${f}" "${WSL_CHROME_DIR}/"
            echo "Restored: ${f}"
        fi
    done

    # Restore Windows-side files
    for f in chrome-native-host.bat com.anthropic.claude_code_browser_extension.json com.anthropic.claude_browser_extension.json; do
        if [ -f "${backup_dir}/${f}" ]; then
            cp -p "${backup_dir}/${f}" "${WIN_CHROME_DIR}/"
            echo "Restored: ${f}"
        fi
    done

    # Make wrapper executable if restored
    if [ -f "${WSL_CHROME_DIR}/chrome-native-host" ]; then
        chmod +x "${WSL_CHROME_DIR}/chrome-native-host"
    fi

    # Re-import registry if backup exists
    if [ -f "${backup_dir}/registry-backup.reg" ]; then
        local win_reg_path
        win_reg_path=$(wslpath -w "${backup_dir}/registry-backup.reg")
        reg.exe import "$win_reg_path" 2>/dev/null && echo "Restored: registry keys" || echo "Warning: registry import failed" >&2
    fi

    echo "Restore complete from: ${backup_dir}"
}

# Main
if [ $# -eq 0 ]; then
    create_backup
elif [ "$1" = "--restore" ]; then
    if [ $# -lt 2 ]; then
        echo "Error: --restore requires a backup directory argument" >&2
        usage
    fi
    restore_backup "$2"
else
    usage
fi
