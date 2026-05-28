#!/usr/bin/env bash
#
# git-autopull — keep specific branches in specific repos fast-forwarded to
# their remote, on a timer, via a per-user launchd daemon.
#
# Usage:
#   git autopull add <branch>      Register the CURRENT repo + <branch>, start daemon
#   git autopull remove <branch>   Unregister the CURRENT repo + <branch>
#   git autopull interval <mins>   Set the global pull interval in minutes (default 30)
#   git autopull interval          Show the current interval
#   git autopull verbose [on|off]  Toggle (or show) verbose daemon logging; OFF
#                                   logs only changes/warnings/errors, ON also
#                                   logs each cycle + every pull attempt
#   git autopull list              Show the interval and everything being pulled
#   git autopull start             Load the daemon (resume pulling on the timer)
#   git autopull stop              Unload the daemon (pause all pulling)
#   git autopull status            Report whether the daemon is running
#   git autopull log [n]           Show the last n daemon log lines (default 50)
#   git autopull uninstall         Stop the daemon, remove the plist, clear config
#
# Install: copy this file onto your PATH named `git-autopull` (NO extension) so
# git resolves it as the `autopull` subcommand, e.g.
#
#   install -m 0755 git-autopull.sh ~/.local/bin/git-autopull
#
# (and make sure that directory is on your PATH). Put it in its final home
# BEFORE first run: the daemon is launched from wherever this file lives, so the
# launchd job records that path.
#
# Notes:
#   * Only fast-forward updates are applied — local work is never clobbered.
#   * The daemon never exits on error: unreachable repos / non-ff branches are
#     logged and skipped, then it carries on with the rest of the list.
#   * The first argument is always a subcommand verb (add/remove/interval/...),
#     so branch names are unrestricted — even a branch named "remove" is fine
#     via `git autopull add remove`.

set -uo pipefail   # deliberately NOT -e: the daemon must outlive individual failures.

# ---- paths & constants ------------------------------------------------------

CONFIG_DIR="$HOME/.config/git-autopull"
REPOS_FILE="$CONFIG_DIR/repos"          # tab-separated lines: <repo-toplevel>\t<branch>
INTERVAL_FILE="$CONFIG_DIR/interval"    # a single integer: minutes
VERBOSE_FILE="$CONFIG_DIR/verbose"      # "1" = verbose daemon logging, "0" = quiet (default)
LOG_FILE="$CONFIG_DIR/autopull.log"

PLIST_LABEL="com.gitautopull.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

DEFAULT_INTERVAL=30
LOG_MAX_LINES=1000

# Absolute path to this very script, so the daemon launches the same file.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- small helpers ----------------------------------------------------------

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
    trim_log
}

# Keep $LOG_FILE bounded so the daemon can run indefinitely. We let it overshoot
# the cap by 20% before rewriting, so a chatty cycle doesn't trigger a full
# rewrite on every line. Truncate-in-place (cat > file) rather than mv, so the
# fd launchd holds via StandardOutPath/StandardErrorPath keeps pointing at the
# live file.
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    local lines tmp
    lines="$(wc -l <"$LOG_FILE" 2>/dev/null)" || return 0
    [ "${lines:-0}" -gt "$(( LOG_MAX_LINES * 12 / 10 ))" ] || return 0
    tmp="$(mktemp "${LOG_FILE}.XXXXXX")" || return 0
    if tail -n "$LOG_MAX_LINES" "$LOG_FILE" >"$tmp" 2>/dev/null; then
        cat "$tmp" >"$LOG_FILE"
    fi
    rm -f "$tmp"
}

# Verbose logging is opt-in via `git autopull verbose on`. The setting lives in
# $VERBOSE_FILE and is re-read on every call below, so the daemon honors a change
# on its next cycle without needing a restart. When OFF, the daemon logs only
# meaningful events — real fast-forwards (OK a..b), warnings, and errors. When ON
# it ALSO records each cycle, every pull attempt, and "already up to date"
# results, so you can confirm the daemon is alive and actually reaching remotes.
verbose_on() {
    case "$(cat "$VERBOSE_FILE" 2>/dev/null)" in
        1|on|ON|true|yes) return 0 ;;
        *)                return 1 ;;
    esac
}

# Like log(), but writes only when verbose logging is enabled.
vlog() {
    verbose_on && log "$*"
}

die() {
    printf 'git autopull: %s\n' "$*" >&2
    exit 1
}

ensure_config() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$INTERVAL_FILE" ] || printf '%s\n' "$DEFAULT_INTERVAL" >"$INTERVAL_FILE"
    [ -f "$REPOS_FILE" ]    || : >"$REPOS_FILE"
    [ -f "$VERBOSE_FILE" ]  || printf '0\n' >"$VERBOSE_FILE"
    [ -f "$LOG_FILE" ]      || : >"$LOG_FILE"
}

get_interval() {
    local v
    v="$(cat "$INTERVAL_FILE" 2>/dev/null)"
    case "$v" in
        ''|*[!0-9]*) printf '%s\n' "$DEFAULT_INTERVAL" ;;
        *)           printf '%s\n' "$v" ;;
    esac
}

repo_toplevel() {
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# ---- launchd plumbing -------------------------------------------------------

write_plist() {
    local git_bin_dir
    git_bin_dir="$(dirname "$(command -v git)")"
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SELF</string>
        <string>__daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$git_bin_dir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
}

# Is the launchd job currently loaded? Capture the list first rather than piping
# into `grep -q`: under `set -o pipefail`, `grep -q` closes the pipe on its first
# match, `launchctl list` (hundreds of lines) is killed by SIGPIPE, and the
# pipeline then reports *that* failure — so a real match is silently lost.
daemon_loaded() {
    local list
    list="$(launchctl list 2>/dev/null)"
    case "$list" in
        *"$PLIST_LABEL"*) return 0 ;;
        *)                return 1 ;;
    esac
}

load_daemon() {
    write_plist
    daemon_loaded && return 0          # already running; it re-reads config every cycle
    launchctl load -w "$PLIST_PATH" 2>/dev/null \
        || die "failed to load launchd job ($PLIST_PATH)"
}

unload_daemon() {
    [ -f "$PLIST_PATH" ] || return 0
    launchctl unload -w "$PLIST_PATH" 2>/dev/null
}

# ---- the daemon -------------------------------------------------------------

# Fast-forward one repo/branch. Always returns 0 so the caller's loop continues.
pull_one() {
    local repo="$1" branch="$2" remote before head after

    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        log "ERROR $repo [$branch] repository unavailable, skipping"
        return 0
    fi

    remote="$(git -C "$repo" config "branch.$branch.remote" 2>/dev/null)"
    [ -n "$remote" ] || remote="origin"

    vlog "PULL  $repo [$branch] checking $remote"

    before="$(git -C "$repo" rev-parse --verify --quiet "$branch" 2>/dev/null)"
    head="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)"

    if [ "$head" = "$branch" ]; then
        # Branch is checked out: fetch, then fast-forward the working tree.
        if ! git -C "$repo" fetch --quiet "$remote" "$branch" 2>>"$LOG_FILE"; then
            log "ERROR $repo [$branch] fetch from $remote failed"
            return 0
        fi
        if ! git -C "$repo" merge --ff-only --quiet FETCH_HEAD 2>>"$LOG_FILE"; then
            log "WARN  $repo [$branch] checked out but not fast-forwardable (dirty/diverged), skipped"
            return 0
        fi
    else
        # Branch not checked out: move the local ref straight to the remote tip.
        # git only allows this refspec form when it is a fast-forward.
        if ! git -C "$repo" fetch --quiet "$remote" "$branch:$branch" 2>>"$LOG_FILE"; then
            log "WARN  $repo [$branch] update from $remote failed (unreachable or non-fast-forward), skipped"
            return 0
        fi
    fi

    after="$(git -C "$repo" rev-parse --verify --quiet "$branch" 2>/dev/null)"
    if [ "$before" != "$after" ]; then
        log "OK    $repo [$branch] ${before:0:7}..${after:0:7}"
    else
        vlog "OK    $repo [$branch] already up to date (${after:0:7})"
    fi
    return 0
}

daemon_loop() {
    ensure_config
    trap 'log "daemon stopping (pid $$)"; exit 0' TERM INT
    log "daemon started (pid $$)"
    while true; do
        if [ -s "$REPOS_FILE" ]; then
            count="$(grep -c . "$REPOS_FILE" 2>/dev/null)"
            vlog "cycle: pulling $count entr$([ "$count" = 1 ] && printf y || printf ies)"
            # Read on fd 3 so git inside pull_one can't consume the loop's input.
            while IFS=$'\t' read -r repo branch <&3; do
                [ -n "$repo" ] && pull_one "$repo" "$branch"
            done 3<"$REPOS_FILE"
        fi
        sleep "$(( $(get_interval) * 60 ))"
    done
}

# ---- user-facing subcommands ------------------------------------------------

cmd_add() {
    local branch="$1" repo entry
    [ -n "$branch" ] || die "usage: git autopull add <branch>"
    ensure_config
    repo="$(repo_toplevel)"

    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        printf 'note: no local branch "%s" yet; it will be created on first pull.\n' "$branch" >&2
    fi

    entry="$repo"$'\t'"$branch"
    if grep -Fxq "$entry" "$REPOS_FILE" 2>/dev/null; then
        printf 'already pulling "%s" in %s\n' "$branch" "$repo"
    else
        printf '%s\t%s\n' "$repo" "$branch" >>"$REPOS_FILE"
        printf 'pulling "%s" in %s every %s min\n' "$branch" "$repo" "$(get_interval)"
    fi
    load_daemon
}

cmd_remove() {
    local branch="$1" repo entry tmp
    [ -n "$branch" ] || die "usage: git autopull remove <branch>"
    ensure_config
    repo="$(repo_toplevel)"
    entry="$repo"$'\t'"$branch"

    if ! grep -Fxq "$entry" "$REPOS_FILE" 2>/dev/null; then
        printf 'not pulling "%s" in %s\n' "$branch" "$repo"
        return 0
    fi

    tmp="$(mktemp)"
    grep -Fxv "$entry" "$REPOS_FILE" >"$tmp"
    mv "$tmp" "$REPOS_FILE"
    printf 'removed "%s" in %s from pull list\n' "$branch" "$repo"

    if [ ! -s "$REPOS_FILE" ]; then
        unload_daemon
        printf 'pull list now empty — daemon stopped\n'
    fi
}

cmd_interval() {
    local mins="$1"
    ensure_config
    if [ -z "$mins" ]; then
        printf 'interval: %s min\n' "$(get_interval)"
        return 0
    fi
    case "$mins" in
        *[!0-9]*) die "interval must be a positive whole number of minutes" ;;
    esac
    [ "$mins" -ge 1 ] || die "interval must be at least 1 minute"
    printf '%s\n' "$mins" >"$INTERVAL_FILE"
    printf 'interval set to %s min (takes effect on the daemon next cycle)\n' "$mins"
}

cmd_verbose() {
    local arg="$1"
    ensure_config
    if [ -z "$arg" ]; then
        if verbose_on; then printf 'verbose: on\n'; else printf 'verbose: off\n'; fi
        return 0
    fi
    case "$arg" in
        on|ON|1|true|yes)   printf '1\n' >"$VERBOSE_FILE"
                            printf 'verbose logging on (takes effect on the daemon next cycle)\n' ;;
        off|OFF|0|false|no) printf '0\n' >"$VERBOSE_FILE"
                            printf 'verbose logging off (takes effect on the daemon next cycle)\n' ;;
        *)                  die "usage: git autopull verbose [on|off]" ;;
    esac
}

cmd_list() {
    ensure_config
    printf 'interval : %s min\n' "$(get_interval)"
    printf 'log      : %s\n' "$LOG_FILE"
    if daemon_loaded; then printf 'daemon   : running\n'; else printf 'daemon   : stopped\n'; fi
    if [ -s "$REPOS_FILE" ]; then
        printf 'pulling  :\n'
        while IFS=$'\t' read -r repo branch; do
            [ -n "$repo" ] && printf '  %-20s %s\n' "$branch" "$repo"
        done <"$REPOS_FILE"
    else
        printf 'pulling  : (nothing)\n'
    fi
}

cmd_start() {
    ensure_config
    if daemon_loaded; then
        printf 'daemon already running\n'
        return 0
    fi
    load_daemon
    printf 'daemon started\n'
    [ -s "$REPOS_FILE" ] || printf 'note: nothing is being pulled yet — add a branch with "git autopull add <branch>"\n' >&2
}

cmd_stop() {
    if ! daemon_loaded; then
        printf 'daemon not running\n'
        return 0
    fi
    unload_daemon
    printf 'daemon stopped\n'
}

cmd_status() {
    if daemon_loaded; then
        printf 'daemon running (label %s)\n' "$PLIST_LABEL"
    else
        printf 'daemon not running\n'
    fi
}

cmd_log() {
    ensure_config
    tail -n "${1:-50}" "$LOG_FILE"
}

cmd_uninstall() {
    local reply
    case "${1:-}" in
        -y|--yes) ;;
        *)
            printf 'Stop the daemon and delete %s (config + log)? [y/N] ' "$CONFIG_DIR"
            read -r reply
            case "$reply" in
                y|Y|yes|YES) ;;
                *) printf 'aborted\n'; return 0 ;;
            esac
            ;;
    esac
    unload_daemon
    rm -f "$PLIST_PATH"
    rm -rf "$CONFIG_DIR"
    printf 'uninstalled: daemon stopped, plist and config removed\n'
    printf 'note: the git-autopull executable was left in place; delete it from your PATH manually if you want it gone.\n'
}

usage() {
    cat <<'EOF'
git autopull — fast-forward chosen branches on a timer (launchd).

  git autopull add <branch>      pull this repo's <branch>; start the daemon
  git autopull remove <branch>   stop pulling this repo's <branch>
  git autopull interval [mins]   show or set the global interval (default 30)
  git autopull verbose [on|off]  show or toggle verbose daemon logging (default off)
  git autopull list              show interval + everything being pulled
  git autopull start             load the daemon (resume pulling)
  git autopull stop              unload the daemon (pause pulling)
  git autopull status            is the daemon running?
  git autopull log [n]           show last n daemon log lines (default 50)
  git autopull uninstall [-y]    stop daemon, remove plist, clear config
EOF
}

# ---- dispatch ---------------------------------------------------------------

case "${1:-}" in
    ''|-h|--help|help) usage ;;
    add)       cmd_add "${2:-}" ;;
    remove)    cmd_remove "${2:-}" ;;
    interval)  cmd_interval "${2:-}" ;;
    verbose)   cmd_verbose "${2:-}" ;;
    list)      cmd_list ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    log)       cmd_log "${2:-}" ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    __daemon)  daemon_loop ;;
    *)         die "unknown command '$1' (try: git autopull --help)" ;;
esac
