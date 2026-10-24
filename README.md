## Overview

My personal Linux config files for Debian/Ubuntu XFCE. One command to reproduce my setup on any machine — no git required. The configs target the driver level where possible, so settings survive login, hibernate/resume, and device name changes (e.g. bcm5974 → keyd after wake). On MacBooks, the bcm5974 USB touchpad re-enumerates on lid open, and XFCE's settings daemon can disable it mid-reconnect — a systemd sleep hook and xfconf fix are included to handle that. Currently covers touchpad behaviour; the repo is structured to grow as more configs are added.

```sh
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/dotfiles/v0.3.0/install.sh | sh
```

Settings apply immediately — no logout needed.

---

## Table of Contents

- [Overview](#overview)
- [What's included](#whats-included)
  - [Touchpad](#touchpad)
  - [VS Code Remote-SSH](#vs-code-remote-ssh)
  - [SSH client defaults](#ssh-client-defaults)
  - [Troubleshooting aliases](#troubleshooting-aliases)
  - [Microsoft Teams (optional)](#microsoft-teams-optional)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Adding more configs](#adding-more-configs)
- [Contributing](#contributing)

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

- **Connect timeout raised to 60s**: `remote.SSH.connectTimeout` is how long VS Code waits for the whole connect, the ssh login plus starting its server on the remote, + 2s. 60 covers logins over a lossy long-haul link, where the old 15 (a 17s window) failed while plain `ssh` still worked (`ssh-vm-banner-timeout/incident-2026-10-24-login-grace-and-vscode-budget-remote-ssh.md`). This setting is what counts for VS Code. A `ConnectTimeout` would override it only if written directly in `~/.ssh/config`, because the extension doesn't follow `Include`, so the one in `ssh/defaults.conf` doesn't reach it. Run `vscode-ssh-budget` to see the value VS Code will use. Cost: a dead host takes up to a minute to report failure in VS Code.
- **Local server enabled** — `remote.SSH.useLocalServer` lets VS Code manage a local proxy process for cleaner reconnects
- Merged into `~/.config/Code/User/settings.json` without touching your other settings

### SSH client defaults

Shared `Host *` defaults live in [`ssh/defaults.conf`](ssh/defaults.conf): keep-alives, `ConnectionAttempts 5`, `ControlMaster`, and `ConnectTimeout 30`. That last one was raised from 15 after fresh logins over lossy mobile data took up to 18.3s. It applies to plain `ssh` only: VS Code Remote-SSH doesn't follow `Include`, so it never sees this file, and it passes its own `-o ConnectTimeout` from `remote.SSH.connectTimeout` (see the VS Code section above). The cost: `ssh` to a host that silently drops connections takes longer to give up.

- Installed to `~/.ssh/config.d/dotfiles-defaults.conf` and included at the **end** of `~/.ssh/config`, behind a `Match all`. ssh keeps the first value it finds, so any host-specific setting above it (or in an included file such as `config.local`) still wins.
- Idempotent: the `Include` is appended once. An existing `~/.ssh/config` is never rewritten, only appended to.
- On a machine that already has these options in a hand-written `Host *` block at the top, delete that block after installing, or it keeps overriding the tracked file.

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
| Is this network good enough for Remote-SSH? (slow wifi, hotspot, travelling) | `check-net` |
| `dev` VM unreachable or acting up | `check-dev` |

- **`recon`** — runs every check below (wifi, SSH `ControlMaster`, VS Code lock, link to `dev`, `dev` VM) in one pass and prints a diagnosis with the exact alias to run for whatever it finds. Advisory only, never takes action itself. Exits non-zero if it found anything.
- **`fix-ssh`** — cleans up stale local `ControlMaster` sockets left behind by a bad disconnect, and closes masters that still look alive but can't carry a session. `ssh -O check` passes a master frozen by laptop suspend, and would pass one whose remote end has stalled, so `fix-ssh` also opens one real session through each live master and closes any that can't start one within 10s. Safe to run reflexively: only a timeout counts against a master, so a working one is left alone.
- **`fix-ssh --vscode [host]`** (default host: `dev`) — force-kills every `vscode-server` process on the given remote host and lets a fresh one spawn on reconnect. Not safe in the same way as the bare form — it drops any currently-connected window too, not just orphaned ones, since there's no remote-side way to tell the difference. Reach for this when VS Code Remote-SSH won't reconnect, a new window won't connect while an existing one still works, or memory looks pinned by piled-up `vscode-server` processes. Don't use it for a slow link: if its own login takes half of Remote-SSH's budget or more, it warns that the link is the problem and points at `check-net`. See `ssh-vm-banner-timeout/self-healing.md` for the incidents this covers.
- **`fix-wifi`** — forces a clean wifi disconnect/reconnect at the connection-profile level (the same "fresh association" effect a reboot has, without one). Use first for ordinary flakiness or roaming issues.
- **`fix-wifi --radio`** — power-cycles the wifi radio itself (`nmcli radio wifi off`/`on`), one layer below `fix-wifi`. Use when `fix-wifi` doesn't help — the driver/firmware state can wedge and refuse every association attempt regardless of network, which a connection-profile cycle can't reach. A `wifi-watchdog` systemd `--user` service (enabled by `install.sh`) detects this pattern automatically and runs this for you after ~60s stuck disconnected, so you shouldn't usually need to run it by hand. While the screen is locked it defers the reset (NetworkManager only lets the active session toggle the radio) and runs it on unlock if wifi is still down. See `notes/wifi-driver-lockup-2026-08-21.md` and `notes/wifi-watchdog-resume-polkit-race-disables-radio.md`.
- **`fix-wifi --bluetooth`** — power-cycles the Bluetooth radio. Use when a Bluetooth phone tether (NAP) fails to come up (`bluez` "Input/output error" is the usual symptom). A wifi hotspot from the phone is more reliable than Bluetooth tethering going forward, if that's an option.
- **`reset-vscode`** — kills local VS Code processes and clears the stale singleton lock/IPC sockets they leave behind, which is what causes the "Close, Reopen" hang to recur even after reopening. Relaunches VS Code afterward unless run as `reset-vscode --no-relaunch`.
- **`check-net [host]`** (default host: `dev`) — grades whether the current network can carry VS Code Remote-SSH. Pings your router, the internet and the host at the same moment, sends one session through any open shared connection (`ControlMaster`) to catch one that has stalled (only a timeout counts as a stall), and times up to three fresh SSH logins. It stops at the first failure, because each failed login is a `PerSourcePenalties` charge on the server and a second one could earn the refusal being diagnosed. It grades the slowest login plus VS Code's server setup time, as measured on its last successful connect (`vscode-ssh-budget --last-connect`), against Remote-SSH's connect window. It then prints GOOD, MARGINAL, POOR or UNREACHABLE and, when the link isn't good, names the hop at fault. It usually takes 20–40s, and a few minutes on a very slow link. It never prints the host's address and never takes action. It exits non-zero unless the verdict is GOOD and the shared connection is working or absent. Tests: `bash scripts/check-net.test.sh`.
- **`vscode-ssh-budget [host]`** (default host: `dev`) — prints how many seconds VS Code Remote-SSH will wait for a connect to the host before `Connecting with SSH timed out`. That window covers the ssh login and starting VS Code's server on the remote. It mirrors the extension's own rule: `remote.SSH.connectTimeout` (15 when unset), replaced by a `ConnectTimeout` that `~/.ssh/config` itself gives the host, then + 2s. The extension doesn't follow `Include`, so a `ConnectTimeout` in an included file (like this repo's defaults) doesn't count, even though `ssh -G` shows it. It follows the extension's quirks, not ssh's. Directive names are case-sensitive, so a lowercase `connecttimeout` reaches ssh but not VS Code. `?` in a pattern matches zero or one character. `Match` blocks are evaluated for `all`, `host`, `originalhost`, `user` and `localuser`. It refuses to guess on a malformed value or a `ConnectTimeout` under `Match exec`/`final`. It also checks itself against VS Code's own log: when the latest `Using connect timeout of N seconds` for the host is newer than the config and disagrees, it prints the logged value and warns that the extension's rule has changed. `--last-connect` prints the server-setup time of the newest successful connect. `check-net`, `check-dev` and `fix-ssh --vscode` all grade logins against this number. Tests: `bash scripts/vscode-ssh-budget.test.sh`.
- **`check-dev`** — advisory-only health check for the `dev` VM. Distinguishes a local `ControlMaster` zombie from `dev` actually being down, and reports which of the known `dev`-side failure mechanisms (Docker crash-loop, `vscode-server` pileup) matches, if any. See `ssh-vm-banner-timeout/README.md`. A slice near its memory ceiling or full swap is reported as pressure only when RAM is also short or tasks are stalling on memory (PSI); otherwise it prints a NOTE and recommends nothing. Tests: `bash scripts/check-dev.test.sh`.

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

## Contributing

Every change follows issue → commits → PR → review:

1. **Issue.** Title it in Conventional Commits form, e.g. `fix(ssh): banner timeout on resume`. The bug, feature and incident forms prefill that shape. `issue-labeler.yml` then labels the issue from its title:

   | Title | Labels |
   |---|---|
   | `fix` / `feat` / `docs` / `perf` | `bug` / `enhancement` / `documentation` / `performance` |
   | `refactor`, `style`, `test`, `build`, `ci`, `chore`, `revert` | `maintenance` |
   | `(scope)`, comma-separated allowed | `area:<scope>` |
   | `!` before the colon | `breaking` |
   | the word "incident" | `incident` |
   | anything else | `needs-triage`, plus one comment explaining the format |

   Retitling an issue updates its labels. Labels added by hand are never removed.
2. **Commits.** One per concern on a feature branch, with Conventional Commits subjects.
3. **PR.** The template opens with `Closes #`, so merging closes the issue.
4. **Review.** `shellcheck-pr-review.yml` posts shellcheck's findings on every PR as a review. It's a record, not a merge gate.

Issues track work; knowledge that should outlive it goes in this repo's docs, which the issue links to. Labeler tests: `bash .github/scripts/label-issue.test.sh`.
