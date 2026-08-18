# SSH Banner Exchange Timeout — Dev VM Incident

## Overview

This documents a recurring incident on the `dev` VM (Hetzner, `178.104.35.30`, Debian 13): SSH connections to the VM started failing with `Connection timed out during banner exchange`, and for a long time the only recovery was a full reboot of the VM. Five rounds of fixes were attempted first, all at the SSH application layer (VS Code multiplexing tuning, systemd socket activation, client `ControlMaster`, MTU/proxy settings, a mobile-hotspot network-path test) — all failed, because the actual cause was never at that layer. **Cascade mechanism confirmed 2026-07-24:** a Docker container health check started failing, which cascaded into the rootless `docker.service` getting OOM-killed and stuck in a crash-restart loop that pegged the VM's CPU and disk enough to starve `sshd` itself. **The same cascade recurred 2026-07-28 with a fully-identified, different trigger:** a Laravel dev container (`wfmctrading-app-1`) whose PHP-FPM worker had run unrecycled for ~53 hours was OOM-killed, which escalated to `docker.service` itself. Status: **VM recovered both times; swap added, old dead containers pruned, and per-container memory limits now shipped for the `wfmctrading` stack; health-check resilience, memory limits on the *other* stacks, PHP-FPM worker recycling, and the exact 2026-07-24 initial trigger are still open** — see `analysis.md` for the full checklist of what's done vs. not.

## Table of Contents

- [Overview](#overview)
- [Contents](#contents)
- [The one rule that matters](#the-one-rule-that-matters)

## Contents

- [`rca.md`](rca.md) — **the fastest way to see what happened.** Formal root-cause-analysis writeup: incident summary, timeline, five-whys, contributing factors, and a corrective-actions checklist (done vs. recommended) in one page.
- [`timeline.md`](timeline.md) — chronological log of every fix attempted, the theory behind each, and why it failed, ending with the live diagnosis that found the real cause. Read this before trying anything new, so it isn't repeated.
- [`configs.md`](configs.md) — before/present snapshots of every config file touched (`sshd_config`, systemd unit state, client `~/.ssh/config`, `~/.bashrc`).
- [`analysis.md`](analysis.md) — the confirmed cascade mechanism in full technical detail, what's *not* yet confirmed (the initial trigger, and whether this explains the earlier incidents too), and what's still left to actually fix (swap, container health-check resilience, memory limits).
- [`runbook.md`](runbook.md) — the out-of-band diagnostic steps that worked (via `hcloud` CLI, no console needed) — reusable if this or a similar issue recurs.
- [`self-healing.md`](self-healing.md) — follow-up safeguards (crash-restart loop guard, memory ceiling, `netdata` alerting, client-side hardening, a scheduled `vscode-server` reaper) and the incident log for the separate VS Code Remote-SSH reconnect-storm failure mode these were built for.
- [`setup-alerting-and-memory-ceiling.md`](setup-alerting-and-memory-ceiling.md) — copy-paste checklist for the pieces of `self-healing.md` that need `sudo` on `dev`.
- [`tmux.conf`](tmux.conf) — deployed to `~/.tmux.conf` on both `dev` (manually, via `scp` + `tmux source-file`, since `install.sh` only reaches mba15) and mba15 (via `dotfiles/install.sh`, which also installs `tmux` itself if missing). Makes `fix-ssh --vscode dev` safe to run freely by moving long-running agent CLI sessions out of the `vscode-server` process tree entirely; also fixes mouse-wheel scroll landing in the foreground app's own UI instead of tmux's scrollback.

## The one rule that matters

**Before assuming this is an SSH problem again, check `docker.service` and `journalctl -b -1` first — and if the crashed boot's `tail -300` doesn't show a clear trigger, grep the full boot, not just the tail.** Every prior incident before 2026-07-24 was destroyed by an immediate reboot before anyone looked at the system in its broken state — once that was fixed (via `hcloud server metrics` + a `journalctl -b -1` read immediately after recovery), the real cause turned up in minutes both times this has now happened. Swap did **not** prevent the 2026-07-28 recurrence — it was a genuine OOM under real memory pressure, not the same mechanism swap was meant to cushion. `mem_limit` is now in place for the `wfmctrading` stack, but every other stack on this VM (`turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold`) is still unbounded — if it recurs again, check `docker ps -a` for which container got OOM-killed before assuming it's the same cause as either prior time.
