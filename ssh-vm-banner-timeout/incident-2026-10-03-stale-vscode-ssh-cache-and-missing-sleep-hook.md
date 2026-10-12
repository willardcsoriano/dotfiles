# Incident: Stale VS Code Remote-SSH Cache, Not `dev`, Plus a Two-Month-Old Missing Sleep Hook (2026-10-03)

## Overview

VS Code Remote-SSH to `dev` hung on "Setting up SSH remote," and the Remote-SSH extension log showed it reusing a cached reference to a local tunnel helper process that was already dead, timing out repeatedly against a stale port. The instinctive first response — `fix-ssh --vscode dev`, run twice — couldn't have fixed it, because the problem was never on `dev`: `recon` had already confirmed a fresh, non-multiplexed SSH connection succeeded cleanly. The actual fault was local: a stale cached `data.json` in the Remote-SSH extension's `globalStorage`, nine days old, pointing at a local helper process (pid 7044) that no longer existed. Clearing that cache and the local VS Code singleton lock/sockets resolved it. Separately, and more significantly: the investigation found that `ssh-control-reset`, the systemd sleep hook documented since 2026-08-17 as fixing exactly this class of local SSH staleness, was never actually deployed to this machine — it existed only in the repo, not at its live system path. It's now installed and verified.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Why `fix-ssh --vscode dev` didn't help](#why-fix-ssh---vscode-dev-didnt-help)
- [Diagnosis](#diagnosis)
- [Fix](#fix)
- [The missing sleep hook](#the-missing-sleep-hook)
- [Open items](#open-items)

## What happened

A fresh VS Code Remote-SSH connection attempt to `dev` logged:

```
Found existing data file
Found local server running: {"remoteListeningOn":{"port":39663}, ... "pid":7044, ...}
Found running server - short-circuiting install
Starting forwarding server. local port 35317 -> socksPort 35477 -> remotePort 39663
...
Failed to set up socket for dynamic port forward to remote port 39663: Proxy connection timed out.
```

followed by ~50 repeated `Server delay-shutdown request failed: connect ENOENT /run/user/1000/vscode-ssh-askpass-....sock` lines — the extension trying and failing to talk to a local helper socket that no longer existed, once a minute, indefinitely.

`recon` was run first, before assuming anything about `dev`'s health:

```
[dev]
LOCAL ISSUE -- dev is fine (a non-multiplexed connection succeeded), but the
normal connection hung -- your local SSH ControlMaster to dev is likely a zombie.
```

Consistent with [[project_ssh_controlmaster_zombie_resume]] (mechanism 3) — but the user had already run `fix-ssh --vscode dev` twice by this point, each completing cleanly (`Killing vscode-server processes on dev... Done.`), with no effect on the actual symptom.

## Why `fix-ssh --vscode dev` didn't help

`fix-ssh --vscode dev` kills `vscode-server` processes on the **remote** (`dev`) — the right tool for mechanism 2 (orphaned-session pileup, see `incident-2026-09-25-vscode-orphan-pileup-dev.md` and `incident-2026-09-29-mobile-hotspot-blocks-pileup-fix.md`). It cannot touch anything local. The log's own evidence rules out a remote-side cause anyway: the extension never got far enough to reach `vscode-server` at all — it failed in its *local* tunnel setup, trying to forward through a cached local helper process (pid 7044, a SOCKS proxy manager the Remote-SSH extension runs on the client to multiplex its connection) that was already dead. Confirmed directly: `ps -ef` found no process 7044 running locally. Killing the remote `vscode-server` has no way to invalidate a stale *local* cache that never gets re-checked unless something clears it explicitly.

## Diagnosis

The cache in question: `~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-d55997bc-a44adf7f53e00964ab890f9f8758a334f1fc15bc-0.128.0-es/data.json`, last modified 2026-09-04 (nine days before this incident) — a prior session's now-dead local server reference that the extension kept trying to reuse ("Found running server - short-circuiting install") instead of re-discovering a fresh one.

`reset-vscode` (the existing tool for VS Code hang recovery) was checked and found insufficient for this: reading `scripts/reset-vscode.sh` directly, it only removes `~/.config/Code/code.lock` and `$XDG_RUNTIME_DIR/vscode-*.sock` — it has never touched the Remote-SSH extension's own `globalStorage` cache, which is a separate stale-state class entirely from the one it was built for ([[project_vscode_close_reopen_hang]], 2026-08-14).

## Fix

1. Removed the stale cache directory directly: `rm -rf ~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-d55997bc-.../`
2. Ran `reset-vscode` to clear the local singleton lock and 3 stale IPC sockets, and relaunch clean.

On the next Remote-SSH connection attempt, the extension has no cached reference to reuse and will do a fresh local-server discovery/tunnel setup instead of retrying a dead one.

## The missing sleep hook

While checking why mechanism 3 (ControlMaster zombie) was in play at all, `ls /etc/systemd/system-sleep/ssh-control-reset` returned `No such file or directory`. This hook is documented in [[project_ssh_controlmaster_zombie_resume]] as installed and confirmed live since 2026-08-17, and exists correctly in the repo at `dotfiles/etc/systemd/system-sleep/ssh-control-reset` — it was simply never copied to its live system path on this machine. `install.sh` (lines 114-121) installs it via `sudo cp`/`chmod`; that step evidently never ran, or ran against a different machine, at some point in this repo's history on `mba15`.

Installed now:

```sh
sudo mkdir -p /etc/systemd/system-sleep
sudo cp dotfiles/etc/systemd/system-sleep/ssh-control-reset /etc/systemd/system-sleep/ssh-control-reset
sudo chmod +x /etc/systemd/system-sleep/ssh-control-reset
```

Verified live: root-owned, `0755`, byte-identical to the repo source.

## Open items

- **Every "mechanism 3" incident and memory entry since 2026-08-17 assumed this hook was protecting the machine. It wasn't.** Worth treating any prior "the hook should have caught this" reasoning in this repo's history with suspicion — it's unknown how long the gap existed (at minimum since whatever reinstall/reimage last touched `/etc`, unknown without checking filesystem timestamps on nearby `/etc` state). `make verify-hardening`-style live verification (already a pattern used for the `dev`-side mitigations) doesn't exist for this client-side hook; worth adding a `recon` check for it specifically, since `recon` already checks `vscode-server-reap-orphans.timer` is live on the `dev` side.
- **`reset-vscode` doesn't clear Remote-SSH `globalStorage` cache entries.** If this recurs, extending `reset-vscode` to also clear `~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*/` would close this permanently rather than requiring a manual `rm -rf` each time. Not done here — scoped to this incident's immediate fix only.
- **Unknown whether other systemd sleep hooks or install-time steps have the same deployment gap.** `touchpad-resume` (the other hook installed by the same `install.sh` pattern) wasn't re-verified during this incident; worth a one-time audit of everything `install.sh` is supposed to have deployed against what's actually live.
