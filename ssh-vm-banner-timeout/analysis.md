# Technical Analysis

## Overview

**Root cause confirmed on 2026-07-24, and confirmed again with a second, distinct trigger on 2026-07-28** — see the section immediately below. The short version: this was never an `sshd`/SSH-layer problem at all. Both times, memory pressure from an unbounded container triggered the kernel OOM killer, which took out the rootless `docker.service` and starved the whole VM's CPU/disk I/O — including `sshd` — for long enough to produce the banner-exchange timeout. The specific trigger differed each time (July 24: two Postgres containers' health checks failing mid-cascade, initial cause unconfirmed; July 28: a Laravel dev container, `wfmctrading-app-1`, whose PHP-FPM worker had run unrecycled for ~53 hours, confirmed directly from the container's own error log) — but the systemic gap enabling both is the same: **no memory ceiling anywhere on this VM**, at the container, cgroup, or systemd level. The rest of this file is kept as the historical record of the three hypotheses considered before the July 24 evidence came in (all pointed at "some kind of resource exhaustion," which turned out to be correct in spirit, just not in the specific mechanism). See `timeline.md`'s "Recurrence (2026-07-28)" section for the full second-incident writeup.

## Table of Contents

- [Overview](#overview)
- [Root cause (confirmed 2026-07-24)](#root-cause-confirmed-2026-07-24)
  - [What's confirmed vs. still open](#whats-confirmed-vs-still-open)
- [What "TCP completes, no banner, forever" actually means](#what-tcp-completes-no-banner-forever-actually-means)
- [Superseded hypotheses (pre-confirmation)](#superseded-hypotheses-pre-confirmation)
  - [1. `sshd` resource exhaustion from repeated connection churn (most likely)](#1-sshd-resource-exhaustion-from-repeated-connection-churn-most-likely)
  - [2. Kernel-level connection tracking (`nf_conntrack`) exhaustion](#2-kernel-level-connection-tracking-nf_conntrack-exhaustion)
  - [3. Memory or disk exhaustion](#3-memory-or-disk-exhaustion)
- [Why "just reboot" always "fixed" it — and why that's misleading](#why-just-reboot-always-fixed-it-and-why-thats-misleading)
- [Confirmed evidence: the failure is not client- or network-path-dependent](#confirmed-evidence-the-failure-is-not-client--or-network-path-dependent)
- [Worst-case blast radius: could this destroy the VM?](#worst-case-blast-radius-could-this-destroy-the-vm)
- [A note on secondary troubleshooting sources](#a-note-on-secondary-troubleshooting-sources)

## Root cause (confirmed 2026-07-24)

Confirmed via `hcloud server metrics` (no VM access needed) plus `journalctl -b -1` read immediately after a hard reset (while the previous boot's logs were still on disk):

1. **05:56:24 UTC** — an SSH connection dropped (`sshd-session: ... Broken pipe`), matching the usual Wi-Fi-drop trigger. Within the same second, two long-running Docker containers' health checks began timing out (`"timed out starting health check for container ..."`).
2. The affected containers got stuck in a bad teardown state — `containerd`/`runc` errors like `"unable to destroy container: container still running"`, `"reading from a closed fifo"`, `"ttrpc: received message on inactive stream"` — repeating continuously rather than resolving.
3. **06:04:04 UTC** — the rootless `docker.service` itself was killed by the **OOM killer**. `systemd` restarted it (`restart counter is at 4` — this had already happened three times before this instance), but each restart re-attempted cleanup of the same broken containers and failed the same way, producing a **crash-restart loop**.
4. That loop is what pegged CPU at 600-800% and disk reads at ~1.0-1.3 GB/s continuously from 05:56 until the hard reset — corroborated independently by `hcloud server metrics --type cpu|disk`, which showed no corresponding network spike (ruling out an external cause) and a sustained, gap-free plateau rather than a bursty pattern (ruling out normal workload variance).
5. This starved the entire VM of CPU and I/O — including `sshd`, which is why the TCP handshake could still complete (kernel-level) but the banner exchange never did (userspace-level), and why even `qemu-guest-agent` (used for a live, no-reboot `hcloud server reset-password` attempt) stopped responding.

**Contributing factor: zero swap.** `free -h` post-recovery showed 15GiB RAM, `Swap: 0B`. With no swap, any memory spike goes straight to the OOM killer with no cushion, making it far more likely that a transient container issue escalates into a full service kill and restart-loop instead of degrading gracefully.

### What's confirmed vs. still open

It's tempting to read step 1 as "the SSH drop caused the health checks to fail." **That's not established, and is probably wrong.** Both containers' health checks are `pg_isready -U <user> -d <db>` — a trivial, fully self-contained Postgres readiness probe with a 5-second timeout, run via `docker exec` inside the container. It has no dependency on the client's SSH session, VS Code, or any tunnel. So the SSH broken pipe and the health-check timeouts happening in the same second are two **symptoms**, not cause-and-effect — something else hit the VM at that exact moment and affected both.

**The initial trigger has not been proven, but has a strong best-fit explanation.** Checked and ruled out:
- No cron job or `systemd` timer was due at 05:56 (`systemctl list-timers --all` shows nothing scheduled anywhere near that time; the daily/weekly ones are hours or days off).
- No `MemoryMax`/`MemoryHigh` cgroup limit is set on `docker.service`, its parent `app.slice`, or `user-1000.slice` (all `infinity`) — so this wasn't a targeted cgroup cap being hit. That means the OOM kill came from the kernel's **system-wide** OOM killer reacting to overall memory pressure, which then happened to pick a process under `docker.service`'s cgroup as its victim — the pressure did not necessarily originate inside Docker at all.
- A `netdata` per-process/cgroup historical query was attempted (netdata runs on this VM with a persistent database) but didn't return matching data for the window on the first attempt; not yet retried with corrected query parameters.

**Best-fit explanation (plausible, not provable):** at the time of the incident, the user had ~4 separate VS Code Remote-SSH windows open against this VM, each with 2-3 terminals, plus a separate test-connection terminal — roughly 10-15 concurrent SSH-backed connections. Each Remote-SSH *window* (not each terminal) spawns its own `vscode-server` + extension-host process tree on the remote host, independently — so 4 windows means 4 separate sets of language servers, file watchers, and extension processes running concurrently, each potentially using several hundred MB to a couple GB depending on the workspace. That, stacked on top of the already-running Postgres containers, on a box with **zero swap** and no cgroup memory ceilings to fail gracefully against, is a very plausible way to tip system-wide memory over the edge — which is consistent with the system-wide (not cgroup-scoped) nature of the OOM kill. This can't be proven after the fact: no per-process memory snapshot from that exact second was captured by any tool, and that data is gone permanently. It's recorded here as the leading theory, not a confirmed fact — if this recurs, capturing `ps aux --sort=-%mem` or a `netdata` per-process memory query *during* the incident (not after) would confirm or refute it directly.

Also unverified: **whether this exact Docker/OOM/crash-loop mechanism explains the other four-to-five incidents in `timeline.md`.** Only the most recent prior boot's journal was checked. The containers involved have been running for ~8 weeks, so it's plausible the same mechanism was the cause every time — but that's an inference, not a checked fact.

**Bottom line: the cascade (health-check failure → crash-restart loop → OOM → total resource starvation → `sshd` starved) is confirmed. The trigger is most likely too many concurrent VS Code Remote-SSH sessions exhausting memory with no swap cushion, but that specific piece is a best-fit inference, not a proven fact.** Until it's proven (or the fixes below are in place), recurrence is still possible — and worth testing directly: if this happens again with fewer concurrent Remote-SSH windows open, that would be strong supporting evidence; recurring with the same heavy multi-window usage would confirm it further.

**What to actually fix, going forward:**

- [x] **Add swap.** Done 2026-07-24: 4GB swapfile (`/swapfile`), persisted in `/etc/fstab`, `vm.swappiness=10`. Confirmed live: `free -h` shows `Swap: 4.0Gi` total, `0B` used. **Note (2026-07-28): swap alone did not prevent a recurrence** — the July 28 incident was a genuine OOM under real memory pressure, not the health-check-restart-loop mechanism swap was meant to cushion. Swap helps but isn't sufficient on its own; the per-container limits below are the actual fix.
- [x] **Prune the long tail of months-old exited containers.** Done 2026-07-24: removed all 24 `erpnext-distribution-*` and `frappe_docker-*` containers (2-8 weeks old, none referenced by anything active). Left `wfmctrading-*` and `ollama` alone — those had only exited 3-5 days prior, too recent to assume they're dead weight rather than intentionally stopped.
- [ ] Avoid piling up many concurrent VS Code Remote-SSH windows against this VM at once (each window runs its own `vscode-server` + extension-host tree) — or, if that workflow is needed, size the VM's RAM/swap with that concurrency in mind rather than for a single-window baseline.
- [ ] Confirm the trigger directly next time: capture `ps aux --sort=-%mem` or a live `netdata` per-process memory view *during* an incident (not after, since that data can't be reconstructed once the VM is rebooted) to see whether `vscode-server` processes are in fact the top memory consumers when it happens.
- [ ] Make the health-check/restart behavior more resilient — e.g. increase `pg_isready`'s timeout/retries so a brief resource blip doesn't immediately cascade into container restarts, and/or use `on-failure` with a backoff instead of `unless-stopped` so a bad container can't restart-loop indefinitely.
- [x] **Per-container memory limits — done for `wfmctrading` (2026-07-28):** `mem_limit: 2g` (app, `mem_reservation: 512m`), `256m` (nginx), `1g` (postgres) added to `~/repos/wfmctrading/docker-compose.yml` directly on the VM (uncommitted — that's a separate repo, not managed here). Verified against live Docker Compose source (via Context7) that `mem_limit` is enforced by plain `docker compose up` on the installed v5.3.1, not Swarm-only. **Still open for every other stack on the box** — `turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold` all remain unbounded; any of them could reproduce the same failure.
- [ ] **New (2026-07-28): recycle long-lived PHP-FPM workers.** `wfmctrading`'s php-fpm pool never sets `pm.max_requests` (disabled by default in the stock `php:8.4-fpm` image), so worker processes are never recycled — one was confirmed alive for ~53 hours before its OOM kill. `mem_limit` bounds the damage if this happens again; `pm.max_requests` (recommend 300-500) addresses why a worker's RSS can grow unbounded in the first place. Recommended, not yet applied.
- [ ] Optional further cleanup: `docker system df` shows ~7.4GB of unused images and ~8.8GB of reclaimable build cache — safe to clear (`docker image prune -a`, `docker builder prune`) but not done, since it wasn't part of the original fix list and would mean slower rebuilds next time those layers are needed.

## What "TCP completes, no banner, forever" actually means

The TCP three-way handshake is completed entirely by the kernel. It can accept a connection into its listen queue and complete the handshake whether or not `sshd` is alive, healthy, or currently able to service it. The `SSH-2.0-OpenSSH_...` banner is only sent once `sshd` calls `accept()` on that queued connection and spins up a handler for it — which happens essentially immediately, before authentication, before PAM, before anything else in the SSH protocol.

So "port open, handshake completes, then infinite silence" means one of two things:

1. `sshd` (or the fork it needs to make) is not running, wedged, or unable to allocate a resource it needs — the kernel queued the connection, but nothing ever picked it up.
2. Something below `sshd` — the kernel's connection tracking, a resource limit, or an edge firewall — is accepting the handshake and then black-holing everything after it, for every process on the box, not just `sshd`.

Because a plain `nc` client (not SSH, not VS Code, no client config at all) reproduces the exact same hang, every client-side and SSH-application-layer theory is ruled out. This is why attempts 1, 3, and 4 — all of which changed SSH or client behavior — could not have fixed it.

## Superseded hypotheses (pre-confirmation)

### 1. `sshd` resource exhaustion from repeated connection churn (most likely)

Each abrupt Wi-Fi drop leaves behind connections that were never cleanly authenticated or closed. If these aren't reaped promptly — because of a bug, a wedged parent process, or genuinely resource-starved forking — they can accumulate across repeated drop/reconnect cycles (which VS Code's multiplexed connections make worse, since each reconnect opens many sockets at once). Eventually `sshd` can hit a real ceiling: no free file descriptors, no free PIDs, or `MaxStartups`' `full` threshold.

This directly matches the confirmed `sshd_config` behavior: past the `full` value in `MaxStartups start:rate:full` (default `10:30:100`), **all further connections are dropped with no response at all** — no banner, no rejection message, nothing. That is exactly the observed symptom. Attempt 1 raised the numbers (`50:30:100` → `100:30:150`) but didn't address whatever is causing the pile-up in the first place, so a bigger ceiling just delays the same failure rather than preventing it.

**What would confirm this:** zombie/defunct `sshd` child processes visible in `ps auxf` at the time of failure, and/or `sudo systemctl restart ssh` alone (without a full VM reboot) fixing the hang.

### 2. Kernel-level connection tracking (`nf_conntrack`) exhaustion

If the `nf_conntrack` table fills up — plausible on a small VM under repeated connection churn — new connections can complete a handshake at the kernel level but never get their packets forwarded to any listening process, system-wide. This would explain why even `nc`, a totally unrelated process, fails identically: the block isn't specific to `sshd` at all.

**What would confirm this:** `dmesg` showing `nf_conntrack: table full, dropping packet` around the time of failure, or `nf_conntrack_count` sitting at or near `nf_conntrack_max` when the VM is unreachable.

### 3. Memory or disk exhaustion

If the VM runs low on memory (e.g. a slow leak, or log growth filling disk), `sshd`'s fork-per-connection model can fail the same way as hypothesis 1 — but for a different underlying reason, and with a different fix (add swap/memory, rotate logs, alert on disk usage) rather than an SSH-specific one.

**What would confirm this:** `free -h` showing near-zero available memory, `df -h` showing a full filesystem, or `dmesg` showing OOM-killer activity at the time of failure.

## Why "just reboot" always "fixed" it — and why that's misleading

A full reboot resets PIDs, clears memory pressure, and flushes the `nf_conntrack` table. That's true regardless of which of the three hypotheses above is correct — so the fact that rebooting has worked every time gives **no information** about which one it actually is. It has looked like each SSH-layer config change "should" have helped, and then a reboot happened anyway before anyone could tell whether the config change mattered or the reboot did all the work. That ambiguity is exactly what [`runbook.md`](runbook.md) is designed to remove.

## Confirmed evidence: the failure is not client- or network-path-dependent

Attempt 5 in [`timeline.md`](timeline.md) — retrying from a mobile carrier hotspot instead of home Wi-Fi — failed identically. That's a meaningful data point: it rules out CGNAT/IP-roaming and any home-IP-specific ban or rate-limit, since the hotspot uses a completely different public IP and network path. Combined with the `nc` evidence (a non-SSH client fails the same way), this leaves no remaining plausible client-side or network-path explanation — the three hypotheses above (all server/VM-side) are the only ones left standing.

## Worst-case blast radius: could this destroy the VM?

Raised directly by the user after the 2026-07-28 recurrence, worth answering plainly since it shapes how urgently the remaining fixes (memory limits on the other stacks, health-check resilience) should be prioritized.

**What actually happens, confirmed both times:** the VM becomes fully unresponsive and needs a hard power-cycle (`hcloud server reset`) to recover. That's disruptive, but not destructive on its own — in both incidents, disk **write** I/O stayed at baseline throughout (it was reads that spiked, from the crash-restart cascade re-reading container/image layers), and no data loss or corruption has been observed after either recovery. A hard reset does not "destroy" a Hetzner Cloud VM — the disk, image, and IP all persist independent of the guest OS's state.

**The real risk this setup carries, not yet hit but genuinely open:** `bodego-postgres` and `turtley-db-1` run continuously in the background on this same VM, independent of whatever triggers the next OOM cascade. A hard power-cycle is not a clean shutdown — if a future reset happens to land mid-write to one of those databases, recovery depends on Postgres's WAL crash-recovery and the VM's filesystem journaling (ext4) both doing their job. Both are normally reliable, but "normally reliable" is not "guaranteed" — an unlucky-timed hard reset is the actual worst-case exposure here, not the VM itself being destroyed, but one of those databases coming back up corrupted.

**What would make it meaningfully worse than anything observed so far:** if a runaway container ever filled the disk (rather than just spiking CPU/read I/O, which is all that's happened in both diagnosed incidents), that could corrupt whatever else is mid-write at the same time — logs, configs, or database files — independent of any hard reset. Neither incident's trigger was disk-fill-based, but it's the next rung up in severity if a future cause ever is.

**Bottom line:** this failure mode can take the VM offline and force a disruptive recovery, and repeatedly forcing hard resets carries real (if so-far-unrealized) risk to the always-on Postgres containers' data — but it has not shown any sign of being able to destroy the VM outright or cause irreversible data loss in either occurrence so far. This is the strongest concrete argument for finishing the `mem_limit` rollout on `turtley`, `bodego`, and the other stacks (see the fix checklist above) rather than treating the `wfmctrading`-only fix as sufficient.

## A note on secondary troubleshooting sources

Some of the fixes recorded in `timeline.md` were guided by a general-purpose AI assistant (not this documentation), and a few of its explanations don't hold up technically — worth flagging so they aren't mistaken for confirmed root causes later:

- **"`systemd` socket activation deadlocks under connection churn"** (attempt 2's stated mechanism) is not a documented or verified failure mode — switching to the classic `ssh.service` was a reasonable thing to try regardless, but the specific deadlock mechanism described was speculative, not confirmed.
- **"`IPQoS` prevents MTU/packet-size blackholing"** (attempt 4's stated reasoning) is not technically correct — `IPQoS` only sets the DSCP/ToS marking bits in the IP header; it has no relationship to packet size, fragmentation, or MTU. The change was harmless (aside from the syntax bug described below) but did not address any real mechanism.
- **Premature "100% solved" / "fixed for good" declarations** were made twice (after enabling `ssh.service`, and implicitly after several config edits) based only on the service showing as active or the command completing — not on reproducing the actual failure condition (a live Wi-Fi drop) and confirming recovery. This is why the same "solved" issue kept resurfacing: the fix was never tested against the failure it was meant to fix.
- **The `IPQoS 0x00` syntax error** (see `timeline.md`) was an actual regression that assistant introduced and never caught, because its own verification step (`nc`, not `ssh -v`) couldn't have detected an SSH-config parse error in the first place.

None of this means the underlying config changes (VS Code settings, `ssh.service`, `MaxStartups`) were wrong to try — just that their stated justifications shouldn't be treated as established fact, and that "the service is active" or "the command ran" is not the same as "the fix was verified against the failure."
