# SSH ControlMaster Zombie After Suspend/Resume

## Overview

On mba15, closing the lid mid-SSH-session and reopening it elsewhere left `ssh dev` and VS Code's Remote-SSH tunnel both hanging indefinitely instead of connecting or failing fast. The cause wasn't the network — wifi and DNS were both healthy on the new network (a phone hotspot) — it was a stale SSH ControlMaster left over from before the lid closed. `ssh -O check` reported the master as "running," which is technically true and completely misleading: that check only confirms the local multiplexing control process is alive, not that its underlying connection to the remote host still works. The connection had silently died while the laptop was suspended, because `ServerAliveInterval`/`ServerAliveCountMax` — the mechanism meant to catch exactly this — can't fire while the process itself is frozen by suspend. The fix is a systemd sleep hook, `ssh-control-reset`, that proactively exits every local ControlMaster socket the moment the system resumes, so the next real connection attempt starts clean instead of waiting on a zombie.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Why ServerAliveInterval didn't catch it](#why-serveraliveinterval-didnt-catch-it)
- [Fix](#fix)
- [Bonus finding: touchpad-resume hook never fired](#bonus-finding-touchpad-resume-hook-never-fired)

## What happened

1. An SSH ControlMaster to `dev` was established while on the home wifi network.
2. Laptop lid closed → system suspended (s2idle).
3. Laptop moved to a different location, reopened, and joined a different network (phone wifi hotspot instead of home wifi).
4. The old ControlMaster's TCP connection to `dev` was now unreachable, but the kernel's connection table still showed it `ESTAB` (no RST was ever received — the far end simply isn't reachable via the new network path, so nothing generates one).
5. `ssh -O check -S ~/.ssh/cm-<host> x` reported "Master running (pid=...)" — this only pings the local mux control process over its unix socket, which was alive and responsive.
6. Any real session request through that master (a plain `ssh dev`, or VS Code's `-D` SOCKS tunnel) hung waiting for a response that would never come, instead of failing immediately.

## Why ServerAliveInterval didn't catch it

`~/.ssh/config` already sets `ServerAliveInterval 10` / `ServerAliveCountMax 3`, which should detect a dead connection within ~30 seconds under normal conditions. It didn't, because suspend stops the process from running at all — no CPU cycles, no timers firing, no keepalives sent — for the entire duration the lid is closed. The master comes out of suspend still believing the last-known state ("connection is fine") is current, because it was never scheduled to notice otherwise. `ServerAliveInterval` protects against a connection dying while the client is running; it has no way to protect against a connection dying while the client is asleep.

## Fix

`etc/systemd/system-sleep/ssh-control-reset`, installed via `install.sh` to `/etc/systemd/system-sleep/ssh-control-reset`:

- Runs on every `post` (resume from any sleep state — suspend, hibernate, hybrid-sleep, suspend-then-hibernate).
- Resolves the logged-in user and, as that user, calls `ssh -O exit -S "$sock" x` on every socket matching `~/.ssh/cm-*`.
- This is local-only and non-destructive to the remote host: it does not touch remote processes (vscode-server, tmux/screen sessions, anything detached) — those already lost their transport the moment the underlying connection died, regardless of whether the local master formally exits. It only clears the local zombie so the *next* connection attempt gets a fast, real handshake instead of hanging.

Companion tool for the same failure mode without a suspend involved: `fix-ssh` (`scripts/fix-ssh.sh`) cleans up sockets where `-O check` already reports dead. It intentionally does not attempt to detect the "reports alive but the data path is dead" zombie case covered here — that requires an active probe (attempting a real session and timing it out), which `ssh-control-reset` sidesteps entirely by unconditionally clearing sockets on every resume instead of trying to diagnose liveness after the fact.

## Bonus finding: touchpad-resume hook never fired

While building this hook, `man systemd-suspend.service` confirmed the second argument passed to `/etc/systemd/system-sleep/*` scripts is always the sleep *action* (`suspend`, `hibernate`, `hybrid-sleep`, `suspend-then-hibernate`) — never the literal string `"resume"`, on `pre` or `post`. The existing `touchpad-resume` hook guarded on `[ "$1" = "post" ] && [ "$2" = "resume" ]`, which could never be true. It has been silently dead code since it was written; the touchpad re-enable behavior documented as "fixed" was actually coming entirely from the xorg.conf.d config and the xfconf `Device_Enabled` correction in `install.sh`, not from this hook. Corrected to guard on `[ "$1" = "post" ]` alone, matching `ssh-control-reset`.
