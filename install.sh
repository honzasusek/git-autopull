#!/usr/bin/env bash
#
# install.sh — one-line installer for git-auto-pull (macOS only).
#
# End users run:
#   curl -fsSL https://raw.githubusercontent.com/honzasusek/git-auto-pull/main/install.sh | bash
#
# Re-running is safe: it upgrades the script in place and restarts the daemon if
# one was already running. Override the install location (default ~/.local/bin):
#   curl -fsSL .../install.sh | INSTALL_DIR=/usr/local/bin bash      # may need sudo
#
set -euo pipefail

# ---- EDIT THESE for your public repo ----------------------------------------
GITHUB_OWNER="honzasusek"          # your GitHub username or org
GITHUB_REPO="git-auto-pull"        # the public repo name
GITHUB_REF="main"                  # branch or tag to install from
SCRIPT_FILE="git-auto-pull.sh"     # the tool's filename as committed in the repo

# ---- derived / overridable --------------------------------------------------
TOOL="git-auto-pull"                                   # installed command name (no extension)
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_REF}"
SCRIPT_URL="${SCRIPT_URL:-${RAW_BASE}/${SCRIPT_FILE}}" # env-overridable (handy for testing)
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
DEST="$INSTALL_DIR/$TOOL"
PLIST_LABEL="com.gitautopull.daemon"

# ---- pretty output ----------------------------------------------------------
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. platform ------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "git-auto-pull only runs on macOS (it uses launchd)."

# ---- 2. git prerequisite ----------------------------------------------------
# git-auto-pull is a git subcommand and shells out to git. On a fresh Mac git
# arrives with Apple's Command Line Tools, so trigger that installer if missing.
if ! command -v git >/dev/null 2>&1; then
    warn "git isn't installed. Launching Apple's Command Line Tools installer..."
    xcode-select --install 2>/dev/null || true
    die "Finish the 'Command Line Tools' install, then re-run this installer."
fi

# ---- 3. download ------------------------------------------------------------
info "Downloading $TOOL from $SCRIPT_URL"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$SCRIPT_URL" -o "$tmp" \
    || die "download failed. Is the repo public and the URL correct? ($SCRIPT_URL)"

# Make sure we got a script, not a GitHub 404 / HTML error page.
first_line="$(head -n 1 "$tmp" 2>/dev/null || true)"
case "$first_line" in
    '#!'*) : ;;
    *) die "that didn't look like a script (an HTML error page?). Check GITHUB_OWNER/REPO/REF and that the repo is public." ;;
esac

# ---- 4. install -------------------------------------------------------------
info "Installing to $DEST"
mkdir -p "$INSTALL_DIR" 2>/dev/null \
    || die "couldn't create $INSTALL_DIR — pick a writable INSTALL_DIR."
if ! cp "$tmp" "$DEST" 2>/dev/null; then
    die "couldn't write $DEST (permissions?). For /usr/local/bin re-run with sudo, or keep the default INSTALL_DIR=\$HOME/.local/bin."
fi
chmod 0755 "$DEST"

# ---- 5. PATH ----------------------------------------------------------------
# ~/.local/bin isn't on macOS's default PATH, so 'git auto-pull' wouldn't resolve
# until we add it. We append a clearly-marked block (uninstall.sh removes it).
PATH_NEEDS_RELOAD=0
PATH_PROFILE=""
ensure_on_path() {
    case ":$PATH:" in *":$INSTALL_DIR:"*) return 0 ;; esac
    local profile
    case "$(basename "${SHELL:-/bin/zsh}")" in
        zsh)  profile="$HOME/.zprofile" ;;
        bash) profile="$HOME/.bash_profile" ;;
        *)    profile="$HOME/.profile" ;;
    esac
    if ! grep -q '# >>> git-auto-pull >>>' "$profile" 2>/dev/null; then
        {
            printf '\n# >>> git-auto-pull >>>\n'
            printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR"
            printf '# <<< git-auto-pull <<<\n'
        } >>"$profile"
        info "Added $INSTALL_DIR to PATH in $profile"
    fi
    PATH_NEEDS_RELOAD=1
    PATH_PROFILE="$profile"
}
ensure_on_path

# ---- 6. restart the daemon if one was already running (upgrade case) --------
daemon_loaded() {
    local list; list="$(launchctl list 2>/dev/null || true)"
    case "$list" in *"$PLIST_LABEL"*) return 0 ;; *) return 1 ;; esac
}
if daemon_loaded; then
    info "Existing daemon found — restarting it to load the new version"
    "$DEST" stop  >/dev/null 2>&1 || true
    "$DEST" start >/dev/null 2>&1 || true
fi

# ---- 7. done ----------------------------------------------------------------
printf '\n'
info "Installed git-auto-pull → $DEST"
"$DEST" --help | sed 's/^/    /' || true
printf '\n'

if [ "$PATH_NEEDS_RELOAD" = "1" ]; then
    printf 'Almost done — open a NEW Terminal window (or run:  source "%s")\n' "$PATH_PROFILE"
    printf 'so the "git auto-pull" command is picked up.\n\n'
fi

cat <<'EOF'
Next steps:
  1. In Terminal, go into a repo you have already cloned:
       cd /path/to/your/repo
  2. Start auto-pulling a branch:
       git auto-pull add main
  3. Confirm it's working:
       git auto-pull list
       git auto-pull log

To remove it later:  git auto-pull uninstall    (or run uninstall.sh)
EOF
