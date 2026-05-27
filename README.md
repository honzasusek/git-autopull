# git-auto-pull

Keep chosen Git branches automatically fast-forwarded to their remotes, on a timer, in the background.

`git-auto-pull` installs as a custom `git` subcommand and runs a small per-user **launchd** daemon that periodically fetches and **fast-forwards** the branches you register. It only ever applies fast-forward updates, so your local work is never overwritten — unreachable repos and diverged branches are simply logged and skipped.

> **Platform:** macOS only. The daemon is managed through launchd (`launchctl` + a `LaunchAgent` plist).

---

## Features

- **Safe by design** — only fast-forward updates are applied. Dirty or diverged branches are skipped, never clobbered.
- **Per-branch, per-repo** — register exactly the branches you want kept in sync, across any number of repos.
- **Updates branches even when they aren't checked out** — moves the local ref straight to the remote tip (still fast-forward only).
- **Resilient daemon** — never exits on error; logs the problem and carries on with the rest of the list.
- **Live config** — interval and verbosity changes are picked up on the daemon's next cycle, no restart needed.
- **Quiet by default** — logs only real changes, warnings, and errors. Flip on verbose logging when you want a heartbeat.

---

## Installation

### Requirements

- **macOS** (the daemon is a launchd `LaunchAgent`).
- **`git`** — if it isn't installed, the one-line installer will launch Apple's Command Line Tools installer for you.

### Recommended — one-line installer

Paste this into **Terminal**:

```sh
curl -fsSL https://raw.githubusercontent.com/honzasusek/git-auto-pull/main/install.sh | bash
```

It downloads the script to `~/.local/bin/git-auto-pull` and adds that directory to your `PATH`. **Open a new Terminal window afterwards** (or run `source ~/.zprofile`) so the `git auto-pull` command is found. Re-running the same line later upgrades to the newest version in place and restarts the daemon if it's running.

### Manual install

Prefer not to pipe a script to `bash`? Download `git-auto-pull.sh` and install it yourself — it must land on your `PATH` named `git-auto-pull` (no extension) so Git resolves it as the `auto-pull` subcommand:

```sh
install -m 0755 git-auto-pull.sh ~/.local/bin/git-auto-pull
```

Make sure that directory is on your `PATH` (e.g. add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile).

> **Important:** put the script in its final home *before* the first run. The daemon is launched from wherever the file lives at registration time, and launchd records that exact path.

Verify it resolves (use a real subcommand — `git auto-pull --help` is intercepted by Git, which looks for a man page that doesn't exist):

```sh
git auto-pull help
```

---

## Quick start

From inside a Git repository:

```sh
# Keep this repo's "main" branch fast-forwarded to its remote
git auto-pull add main

# See what's being pulled
git auto-pull list

# Pull every 10 minutes instead of the default 30
git auto-pull interval 10
```

That's it. The daemon starts automatically on the first `add` and keeps running across reboots (it's a `RunAtLoad` + `KeepAlive` LaunchAgent).

---

## Usage

```
git auto-pull add <branch>      Register the CURRENT repo + <branch>, start the daemon
git auto-pull remove <branch>   Unregister the CURRENT repo + <branch>
git auto-pull interval [mins]   Show, or set, the global pull interval in minutes (default 30)
git auto-pull verbose [on|off]  Show, or toggle, verbose daemon logging (default off)
git auto-pull list              Show the interval and everything being pulled
git auto-pull start             Load the daemon (resume pulling on the timer)
git auto-pull stop              Unload the daemon (pause all pulling)
git auto-pull status            Report whether the daemon is running
git auto-pull log [n]           Show the last n daemon log lines (default 50)
git auto-pull uninstall [-y]    Stop the daemon, remove the plist, clear config
```

The first argument is always a subcommand verb, so branch names are unrestricted — even a branch literally named `remove` works via `git auto-pull add remove`.

### Examples

```sh
git auto-pull add develop          # also sync develop in this repo
git auto-pull remove develop       # stop syncing it
git auto-pull interval             # -> "interval: 30 min"
git auto-pull verbose on           # log every cycle and pull attempt
git auto-pull log 100              # tail the last 100 log lines
git auto-pull stop                 # pause without losing your config
git auto-pull start                # resume
```

---

## How it works

For each registered `<repo, branch>` pair, on every cycle the daemon:

1. **If the branch is checked out** — `fetch`es from its remote, then `merge --ff-only`. If the tree is dirty or the branch has diverged, it logs a warning and skips.
2. **If the branch is *not* checked out** — fetches directly into the local ref (`<branch>:<branch>`), a form Git only permits when it's a fast-forward.

The remote is taken from `branch.<branch>.remote`, falling back to `origin`.

The daemon never exits on failure: an unreachable repo, a failed fetch, or a non-fast-forward update is logged and skipped, and it moves on to the next entry. Config is re-read every cycle, so interval/verbosity edits and `add`/`remove` changes take effect without a restart.

---

## Configuration & files

Everything lives under `~/.config/git-auto-pull/`:

| File          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `repos`       | Tab-separated lines: `<repo-toplevel>\t<branch>`               |
| `interval`    | A single integer — the pull interval in minutes (default `30`) |
| `verbose`     | `1` = verbose logging, `0` = quiet (default)                   |
| `auto-pull.log` | Daemon log (changes, warnings, errors; plus cycles when verbose) |

The launchd job is installed at:

```
~/Library/LaunchAgents/com.gitautopull.daemon.plist
```

### Log lines at a glance

```
OK    /path/to/repo [main] a1b2c3d..e4f5a6b       # a real fast-forward was applied
WARN  /path/to/repo [main] checked out but not fast-forwardable (dirty/diverged), skipped
ERROR /path/to/repo [main] repository unavailable, skipping
```

With `verbose on`, you'll additionally see each cycle, every pull attempt, and "already up to date" results — handy for confirming the daemon is alive and reaching your remotes.

---

## Uninstall

```sh
git auto-pull uninstall        # prompts for confirmation
git auto-pull uninstall -y     # skip the prompt
```

This stops the daemon, removes the LaunchAgent plist, and deletes the config directory (config + log). The `git-auto-pull` executable itself is left in place — delete it from your `PATH` manually if you want it gone.

To remove **everything** in one go — including the executable and the `PATH` line the installer added — run the uninstaller:

```sh
curl -fsSL https://raw.githubusercontent.com/honzasusek/git-auto-pull/main/uninstall.sh | bash
```

---

## Notes & caveats

- **macOS only.** The scheduling layer is launchd; there's no Linux/`systemd` or Windows equivalent here.
- **Fast-forward only.** This tool will never create a merge commit, rebase, or reset — if a branch can't fast-forward, it's left untouched.
- **No `set -e`.** The daemon deliberately runs without `errexit` so a single failure can't take down the whole loop.
