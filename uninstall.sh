#!/bin/bash
# StraitJacket for macOS — uninstaller. Must be run with sudo.
#
#   sudo ./uninstall.sh
#
# Stops the daemon, restores DNS to defaults, removes the /etc/hosts block and
# app ACLs, and deletes installed files. By default it keeps your policy files;
# pass --purge to delete the support directory too.
set -euo pipefail

LABEL="com.straitjacket.mac"
SUPPORT="/Library/Application Support/StraitJacket"
LOGDIR="/Library/Logs/StraitJacket"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HOSTS="/etc/hosts"
BEGIN="# STRAITJACKET BEGIN — managed, do not edit"
END="# STRAITJACKET END"

if [[ "$EUID" -ne 0 ]]; then echo "Please run with sudo: sudo ./uninstall.sh" >&2; exit 1; fi

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

echo "==> Removing app ACLs (best effort)..."
CHILD="$(/usr/bin/plutil -extract childUsername raw "$SUPPORT/config.json" 2>/dev/null || echo "")"
if [[ -n "$CHILD" ]] && [[ -x /usr/local/bin/parentctl ]]; then
    # Unblock each app so its deny-execute ACL is dropped.
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        /usr/local/bin/parentctl unblock-app "$entry" >/dev/null 2>&1 || true
    done < <(grep -vE '^\s*#' "$SUPPORT/appblock.txt" 2>/dev/null || true)
fi

echo "==> Stopping daemon..."
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Removing /etc/hosts managed block..."
if [[ -f "$HOSTS" ]]; then
    /usr/bin/sed -i '' "/^${BEGIN}\$/,/^${END}\$/d" "$HOSTS" 2>/dev/null || true
fi

echo "==> Restoring DNS to defaults..."
while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == \** || "$svc" == *"denotes that"* ]] && continue
    networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null)
dscacheutil -flushcache || true
killall -HUP mDNSResponder 2>/dev/null || true

echo "==> Removing Firefox enterprise policy..."
rm -f "/Applications/Firefox.app/Contents/Resources/distribution/policies.json"

echo "==> Removing binaries..."
rm -f /usr/local/sbin/parentd /usr/local/bin/parentctl

if [[ "$PURGE" -eq 1 ]]; then
    echo "==> Purging policy + logs..."
    rm -rf "$SUPPORT" "$LOGDIR"
else
    echo "==> Keeping policy in $SUPPORT (use --purge to delete)."
    rm -rf "$LOGDIR"
fi

echo "Done. StraitJacket removed."
