## Overview

My personal Linux config files for Debian/Ubuntu XFCE. One command to reproduce my setup on any machine — no git required. The configs target the driver level where possible, so settings survive login, hibernate/resume, and device name changes (e.g. bcm5974 → keyd after wake). On MacBooks, the bcm5974 USB touchpad re-enumerates on lid open, and XFCE's settings daemon can disable it mid-reconnect — a systemd sleep hook and xfconf fix are included to handle that. Currently covers touchpad behaviour; the repo is structured to grow as more configs are added.

```sh
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/dotfiles/v0.1.0/install.sh | sh
```

Settings apply immediately — no logout needed.

---

## Table of Contents

- [Overview](#overview)
- [What's included](#whats-included)
  - [Touchpad](#touchpad)
  - [VS Code Remote-SSH](#vs-code-remote-ssh)
  - [Troubleshooting aliases](#troubleshooting-aliases)
  - [Microsoft Teams (optional)](#microsoft-teams-optional)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Adding more configs](#adding-more-configs)

## What's included

### Touchpad

Default XFCE touchpad settings are painful — slow cursor and no tap-to-click, meaning you have to physically press the pad down every time. This fixes both.

- **Tap-to-click** — tap the surface instead of pressing down, which also saves the click mechanism from wearing out
- **Natural scrolling** — scroll direction matches touchpad gesture
- **Max acceleration speed** — cursor feels snappy from first login
- Configured at the libinput driver level — persists across hibernate/resume, not just login
- Includes a fix for XFCE's settings daemon disabling the trackpad after lid open on MacBooks (bcm5974 USB re-enumeration bug)

### VS Code Remote-SSH

Turns on VS Code's own reconnect handling for Remote-SSH sessions instead of leaving it on defaults.

- **Connect timeout raised to 15s** — `remote.SSH.connectTimeout` gives slow or waking remote hosts enough time to answer before VS Code gives up
- **Local server enabled** — `remote.SSH.useLocalServer` lets VS Code manage a local proxy process for cleaner reconnects
- Merged into `~/.config/Code/User/settings.json` without touching your other settings

### Troubleshooting aliases

Installed to `~/.local/bin/fix-ssh` — try these before reaching for anything heavier when a remote connection is acting up:

- **`fix-ssh`** — cleans up stale local `ControlMaster` sockets left behind by a bad disconnect. Safe to run reflexively: it only ever removes a socket after confirming its master connection is actually dead (`ssh -O check`), so it won't touch a live one.
- **`fix-ssh --vscode [host]`** (default host: `dev`) — force-kills every `vscode-server` process on the given remote host and lets a fresh one spawn on reconnect. Not safe in the same way as the bare form — it drops any currently-connected window too, not just orphaned ones, since there's no remote-side way to tell the difference. Reach for this when VS Code Remote-SSH won't reconnect, a new window won't connect while an existing one still works, or memory looks pinned by piled-up `vscode-server` processes. See `ssh-vm-banner-timeout/self-healing.md` for the incidents this covers.

### Microsoft Teams (optional)

`scripts/install-teams-for-linux.sh` installs the unofficial [`teams-for-linux`](https://github.com/IsmaelMartinez/teams-for-linux) Electron client via its own apt repo, since Microsoft ships no native Debian package.

- Idempotent — skips if already installed
- Detects architecture automatically (`dpkg --print-architecture`) instead of hardcoding `amd64`
- Adds `repo.teamsforlinux.de` as a dedicated apt source with its own signing key, so future `apt upgrade` keeps it current
- Run separately from `install.sh`, since it installs a full application rather than restoring a config file:
  ```sh
  bash scripts/install-teams-for-linux.sh
  ```
- If sign-in fails right after install with an account-locked message, see [`notes/teams-for-linux-account-lockout.md`](notes/teams-for-linux-account-lockout.md) — it's Entra ID Smart Lockout, not a problem with the client or script

---

## Requirements

- Debian/Ubuntu-based distro, X11 with libinput driver
- `curl` (pre-installed on most distros)
- `python3` (only needed for the VS Code settings merge; skipped with a warning if absent)

## How it works

`install.sh` pulls files directly from GitHub (pinned to the release tag) and puts them in the right places:

| File | What it does |
|------|-------------|
| `/etc/X11/xorg.conf.d/40-libinput-touchpad.conf` | Configures libinput at driver level — applies on every X start and device reconnect |
| `/etc/systemd/system-sleep/touchpad-resume` | Re-enables the touchpad 2s after resume, in case xfsettingsd disables it during reconnect |

`install.sh` also runs `xfconf-query` to fix XFCE storing `Device_Enabled=0` for the trackpad — the root cause of the touchpad going dead after lid open on MacBooks.

For `vscode/settings.json`, `install.sh` doesn't overwrite the destination file — it merges the two keys into your existing `~/.config/Code/User/settings.json` via `python3`, leaving any other settings you already have in place.

## Adding more configs

This repo is meant to grow. To add a new config:

1. Drop the file or script in a logical folder
2. Add an install step to `install.sh`
3. Document it here under a new section
