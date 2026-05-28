#!/usr/bin/env bash
#
# uninstall.sh — remove git-autopull (macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/honzasusek/git-autopull/main/uninstall.sh | bash
#
# Best-effort and safe to run even on a partial install (no `set -e`).
set -uo pipefail

TOOL="git-autopull"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
PLIST="$HOME/Library/LaunchAgents/com.gitautopull.daemon.plist"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Find the installed binary (prefer whatever is on PATH).
BIN="$(command -v "$TOOL" 2>/dev/null || true)"
[ -n "$BIN" ] || BIN="$INSTALL_DIR/$TOOL"

if [ -x "$BIN" ]; then
    # The tool's own `uninstall` stops the daemon + removes the plist and config.
    info "Stopping daemon and clearing config via '$TOOL uninstall'"
    "$BIN" uninstall -y || true
    info "Removing $BIN"
    rm -f "$BIN"
else
    info "$TOOL not found — cleaning up any leftover daemon/config directly"
    launchctl unload -w "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$HOME/.config/git-autopull"
fi

# Remove the PATH block the installer added, from any common profile.
for profile in "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$profile" ] || continue
    if grep -q '# >>> git-autopull >>>' "$profile" 2>/dev/null; then
        tmp="$(mktemp)"
        sed '/# >>> git-autopull >>>/,/# <<< git-autopull <<</d' "$profile" >"$tmp" \
            && mv "$tmp" "$profile" \
            && info "Removed PATH entry from $profile"
    fi
done

info "Done — git-autopull removed. Open a new Terminal to refresh your PATH."
