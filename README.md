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

Installed to `~/.local/bin/` by `install.sh`. **Don't know which one to run? Run `recon` first** — it checks everything below plus the `dev` VM and tells you exactly what to run next. It works fully offline (no network, no agent) since it only reads local state, which is the point: it exists because of an incident where the network itself was down and there was no way to ask anything what to run. See [`notes/wifi-driver-lockup-2026-08-21.md`](notes/wifi-driver-lockup-2026-08-21.md).

Quick reference if you'd rather skip straight to a fix:

| Symptom | Run |
|---|---|
| Not sure / want a diagnosis first | `recon` |
| SSH or VS Code Remote-SSH hanging (not erroring, just hanging) | `fix-ssh` |
| VS Code Remote-SSH won't reconnect, or a new window won't connect while another still works | `fix-ssh --vscode [host]` (default `dev`) |
| Wifi connected but flaky / stuck roaming between access points | `fix-wifi` |
| Wifi disconnected and `fix-wifi` alone didn't clear it within a few seconds | `fix-wifi --radio` |
| Bluetooth phone tether (NAP) fails with an I/O error | `fix-wifi --bluetooth` |
| Local VS Code window frozen / "Close, Reopen" hang loop | `reset-vscode` |
| `dev` VM unreachable or acting up | `check-dev` |

- **`recon`** — runs every check below (wifi, SSH `ControlMaster`, VS Code lock, `dev` VM) in one pass and prints a diagnosis with the exact alias to run for whatever it finds. Advisory only, never takes action itself. Exits non-zero if it found anything.
- **`fix-ssh`** — cleans up stale local `ControlMaster` sockets left behind by a bad disconnect. Safe to run reflexively: it only ever removes a socket after confirming its master connection is actually dead (`ssh -O check`), so it won't touch a live one. Caveat: `ssh -O check` can false-positive "alive" on a `ControlMaster` frozen by laptop suspend (see `notes/ssh-controlmaster-zombie-after-resume.md`) — if SSH is hanging despite `fix-ssh` reporting sockets as live, run it anyway, it's harmless either way.
- **`fix-ssh --vscode [host]`** (default host: `dev`) — force-kills every `vscode-server` process on the given remote host and lets a fresh one spawn on reconnect. Not safe in the same way as the bare form — it drops any currently-connected window too, not just orphaned ones, since there's no remote-side way to tell the difference. Reach for this when VS Code Remote-SSH won't reconnect, a new window won't connect while an existing one still works, or memory looks pinned by piled-up `vscode-server` processes. See `ssh-vm-banner-timeout/self-healing.md` for the incidents this covers.
- **`fix-wifi`** — forces a clean wifi disconnect/reconnect at the connection-profile level (the same "fresh association" effect a reboot has, without one). Use first for ordinary flakiness or roaming issues.
- **`fix-wifi --radio`** — power-cycles the wifi radio itself (`nmcli radio wifi off`/`on`), one layer below `fix-wifi`. Use when `fix-wifi` doesn't help — the driver/firmware state can wedge and refuse every association attempt regardless of network, which a connection-profile cycle can't reach. A `wifi-watchdog` systemd `--user` service (enabled by `install.sh`) detects this pattern automatically and runs this for you after ~60s stuck disconnected, so you shouldn't usually need to run it by hand. See `notes/wifi-driver-lockup-2026-08-21.md`.
- **`fix-wifi --bluetooth`** — power-cycles the Bluetooth radio. Use when a Bluetooth phone tether (NAP) fails to come up (`bluez` "Input/output error" is the usual symptom). A wifi hotspot from the phone is more reliable than Bluetooth tethering going forward, if that's an option.
- **`reset-vscode`** — kills local VS Code processes and clears the stale singleton lock/IPC sockets they leave behind, which is what causes the "Close, Reopen" hang to recur even after reopening. Relaunches VS Code afterward unless run as `reset-vscode --no-relaunch`.
- **`check-dev`** — advisory-only health check for the `dev` VM. Distinguishes a local `ControlMaster` zombie from `dev` actually being down, and reports which of the known `dev`-side failure mechanisms (Docker crash-loop, `vscode-server` pileup) matches, if any. See `ssh-vm-banner-timeout/README.md`.

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
