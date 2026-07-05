#!/bin/bash
# StraitJacket for macOS — installer. Must be run with sudo.
#
#   sudo ./install.sh
#
# Builds parentd + parentctl, installs them as a root launchd daemon, and seeds
# the policy files. Re-running is safe: it upgrades the binaries and reloads the
# daemon without clobbering your edited blocklists.
set -euo pipefail

LABEL="com.straitjacket.mac"
SUPPORT="/Library/Application Support/StraitJacket"
LOGDIR="/Library/Logs/StraitJacket"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SBIN="/usr/local/sbin"
BIN="/usr/local/bin"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then echo "This installer is macOS-only." >&2; exit 1; fi
if [[ "$EUID" -ne 0 ]]; then echo "Please run with sudo: sudo ./install.sh" >&2; exit 1; fi
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift toolchain not found. Install Xcode or the Command Line Tools (xcode-select --install)." >&2
    exit 1
fi

# Warn if something else already owns port 53 (the DNS layer would be skipped).
if lsof -nP -iUDP:53 >/dev/null 2>&1; then
    echo "WARNING: UDP port 53 is already in use; the DNS sinkhole layer may be unavailable." >&2
fi

echo "==> Building (release)..."
( cd "$SRC_DIR" && swift build -c release )
BUILD_BIN="$(cd "$SRC_DIR" && swift build -c release --show-bin-path)"

echo "==> Installing binaries..."
mkdir -p "$SBIN" "$BIN"
install -m 755 -o root -g wheel "$BUILD_BIN/parentd"   "$SBIN/parentd"
install -m 755 -o root -g wheel "$BUILD_BIN/parentctl" "$BIN/parentctl"

echo "==> Seeding configuration in $SUPPORT..."
mkdir -p "$SUPPORT" "$LOGDIR"
chown root:wheel "$SUPPORT" "$LOGDIR"
chmod 755 "$SUPPORT" "$LOGDIR"
# Copy defaults only if absent or empty — never overwrite the parent's edits,
# but a 0-byte seed is a broken install (e.g. seeded before the default existed),
# not a deliberate edit, so re-seed it.
for f in config.json blocklist.txt hostsonly.txt appblock.txt feeds.txt; do
    if [[ -e "$SUPPORT/$f" && ! -s "$SUPPORT/$f" ]]; then
        install -m 644 -o root -g wheel "$SRC_DIR/config/$f" "$SUPPORT/$f"
        echo "    + $f (re-seeded empty)"
    elif [[ ! -e "$SUPPORT/$f" ]]; then
        install -m 644 -o root -g wheel "$SRC_DIR/config/$f" "$SUPPORT/$f"
        echo "    + $f"
    else
        echo "    = $f (kept existing)"
    fi
done

# Prompt for the child account unless config already names a real one.
CURRENT_CHILD="$(/usr/bin/plutil -extract childUsername raw "$SUPPORT/config.json" 2>/dev/null || echo "")"
if [[ -z "$CURRENT_CHILD" || "$CURRENT_CHILD" == "child" ]] || ! id "$CURRENT_CHILD" >/dev/null 2>&1; then
    echo
    echo "Available standard (non-admin) users:"
    for u in $(dscl . list /Users UniqueID | awk '$2 >= 501 && $2 < 600 {print $1}'); do
        if ! dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1; then
            echo "    $u"
        fi
    done
    read -r -p "Enter the child's macOS username to restrict: " CHILD || true
    if [[ -n "${CHILD:-}" ]] && id "$CHILD" >/dev/null 2>&1; then
        /usr/bin/plutil -replace childUsername -string "$CHILD" "$SUPPORT/config.json"
        echo "    child account set to: $CHILD"
    else
        echo "    (skipped — set later with: sudo parentctl set-child <username>)"
    fi
fi

echo "==> Installing Firefox enterprise policy..."
# Forces address-bar search to lite.duckduckgo.com and blocks the full UI at the
# URL layer. We can't do this at DNS — lite is a CNAME to duckduckgo.com and
# mDNSResponder chases CNAMEs, so sinkholing the parent breaks the sibling.
FF_APP="/Applications/Firefox.app"
if [[ -d "$FF_APP" ]]; then
    FF_DIST="$FF_APP/Contents/Resources/distribution"
    # Non-fatal: macOS 13+ forbids writing into another app's bundle unless the
    # terminal running sudo has App Management permission. Don't let that abort
    # the rest of the install (daemon still works; only the DDG URL block is lost).
    if install -d -m 755 -o root -g wheel "$FF_DIST" 2>/dev/null \
       && install -m 644 -o root -g wheel "$SRC_DIR/config/firefox-policies.json" "$FF_DIST/policies.json" 2>/dev/null; then
        echo "    + $FF_DIST/policies.json"
    else
        echo "    !! Could not write into Firefox.app (Operation not permitted)."
        echo "       macOS 13+ (Ventura and later) blocks modifying another app's"
        echo "       bundle unless the terminal running sudo has App Management."
        echo "       Fix: System Settings > Privacy & Security > App Management,"
        echo "            enable your terminal (Terminal/iTerm), fully quit it"
        echo "            (Cmd-Q), reopen, and re-run: sudo ./install.sh"
        echo "       Everything else installs fine; only the Firefox URL-layer"
        echo "       DuckDuckGo block is skipped until this step succeeds."
    fi
else
    echo "    (Firefox.app not found at $FF_APP — skipping; install Firefox then re-run)"
fi

echo "==> Installing launchd daemon..."
install -m 644 -o root -g wheel "$SRC_DIR/com.straitjacket.mac.plist" "$PLIST"
# Reload cleanly if already loaded.
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}" 2>/dev/null || true

echo "==> Flushing DNS cache..."
dscacheutil -flushcache || true
killall -HUP mDNSResponder 2>/dev/null || true

echo
echo "Done. StraitJacket is running."
echo "  Status:  sudo parentctl status"
echo "  Logs:    $LOGDIR/parentd.log"
echo "  Manage:  sudo parentctl add-domain <d> | block-app <id> | pause [min] | ..."
