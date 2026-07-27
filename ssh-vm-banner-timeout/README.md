# SSH Banner Exchange Timeout — Dev VM Incident

## Overview

This documents an incident on the `dev` VM (Hetzner, `178.104.35.30`, Debian 13): SSH connections to the VM started failing with `Connection timed out during banner exchange`, and for a long time the only recovery was a full reboot of the VM. Five rounds of fixes were attempted first, all at the SSH application layer (VS Code multiplexing tuning, systemd socket activation, client `ControlMaster`, MTU/proxy settings, a mobile-hotspot network-path test) — all failed, because the actual cause was never at that layer. **Cascade mechanism confirmed 2026-07-24:** a Docker container health check started failing, which cascaded into the rootless `docker.service` getting OOM-killed and stuck in a crash-restart loop that pegged the VM's CPU and disk enough to starve `sshd` itself. Status: **VM recovered; swap added and old dead containers pruned; health-check resilience, memory limits, and the exact initial trigger are still open** — see `analysis.md` for the full checklist of what's done vs. not.

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

## The one rule that matters

**Before assuming this is an SSH problem again, check `docker.service` and `journalctl -b -1` first.** Every prior incident before this one was destroyed by an immediate reboot before anyone looked at the system in its broken state — once that was fixed (via `hcloud server metrics` + a `journalctl -b -1` read immediately after recovery), the real cause turned up in minutes. Swap is now in place, which should turn a future memory spike into degraded performance instead of an OOM kill — but the health-check/restart-loop behavior itself is still unfixed, so if it recurs, that's the most likely reason why.
