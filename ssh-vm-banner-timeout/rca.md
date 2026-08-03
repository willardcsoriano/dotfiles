# Root Cause Analysis — SSH Banner Exchange Timeout on `dev` VM

## Overview

This is the formal root-cause analysis for the recurring `dev` VM incident: SSH connections failed with `Connection timed out during banner exchange`, and for five prior occurrences the only recovery was a full VM reboot — which destroyed the evidence needed to diagnose it each time. On the sixth occurrence (2026-07-24), the VM was recovered without the previously-relied-on console access, using the `hcloud` CLI plus a `journalctl` read taken immediately after recovery, which finally captured direct evidence. Proximate cause: a Docker container health-check failure cascaded into the rootless `docker.service` being OOM-killed and stuck in a crash-restart loop, which starved the entire VM's CPU and disk I/O — including `sshd`, which is why SSH itself looked like the problem. The initial trigger for that occurrence's underlying memory pressure remains unconfirmed. **A seventh occurrence on 2026-07-28 confirmed the same systemic gap with a fully-identified trigger this time:** a Laravel dev container (`wfmctrading-app-1`) whose PHP-FPM worker had run unrecycled for ~53 hours was OOM-killed, which cascaded into `docker.service` itself being OOM-killed and the VM being starved again, in the same pattern. Both occurrences share one root enabling condition — **no memory ceiling anywhere on this VM** — even though the specific offending container differed. Per-container memory limits are now in place for the `wfmctrading` stack (2026-07-28) but not yet for the others running on the box. This report exists to consolidate the finding into a standard incident-review structure — for narrative detail, `timeline.md` and `analysis.md` remain the source of record.

## Table of Contents

- [Overview](#overview)
- [Incident summary](#incident-summary)
- [Timeline (final, diagnosed occurrence — 2026-07-24, all times UTC)](#timeline-final-diagnosed-occurrence-2026-07-24-all-times-utc)
- [Timeline (7th occurrence — 2026-07-28, all times UTC)](#timeline-7th-occurrence-2026-07-28-all-times-utc)
- [Root cause](#root-cause)
  - [Proximate cause](#proximate-cause)
  - [Five whys](#five-whys)
  - [Contributing factors](#contributing-factors)
- [Detection and response assessment](#detection-and-response-assessment)
- [Impact](#impact)
- [Corrective actions](#corrective-actions)
  - [Completed (2026-07-24)](#completed-2026-07-24)
  - [Completed (2026-07-28)](#completed-2026-07-28)
  - [Recommended, not yet done](#recommended-not-yet-done)
- [Open questions](#open-questions)
- [References](#references)

## Incident summary

| Field | Value |
|---|---|
| Affected system | `dev` (Hetzner Cloud VM, `178.104.35.30`, Debian 13, rootless Docker) |
| Symptom | `Connection timed out during banner exchange` on every SSH client (OpenSSH, VS Code Remote-SSH, plain `nc`) |
| Occurrences | 7 confirmed (5 prior, undiagnosed; 2 diagnosed — 2026-07-24 and 2026-07-28) |
| Detection method | Manual — user noticed SSH failures; no automated alerting existed |
| Resolution (2026-07-24) | `hcloud server reset` (hard power-cycle) after a soft reboot had no effect; ~20s to recovery once issued |
| Resolution (2026-07-28) | `make recover` (the automated version of the same ladder) ran to completion; VM was unreachable for ~20 minutes, consistent with escalating to a hard reset again |
| Status | **Proximate cause confirmed both times; 2026-07-28's specific trigger fully confirmed (unlike 2026-07-24's); per-container memory limits now shipped for one of several stacks; full remediation still not complete** |

## Timeline (final, diagnosed occurrence — 2026-07-24, all times UTC)

| Time | Event |
|---|---|
| 05:54:21 | New SSH session opens from the client's usual IP |
| 05:56:21–24 | Two Postgres containers' health checks (`pg_isready`) begin timing out; an SSH connection drops (`Broken pipe`) in the same second — coincident, not causal (health checks are self-contained, no dependency on the SSH session) |
| 05:56:24 | Onset of sustained resource anomaly (confirmed retroactively via `hcloud server metrics`): CPU climbs from ~30% baseline to 600-800%; disk reads climb from bursty tens/hundreds of KB/s to a continuous ~1.0-1.3 GB/s; network traffic stays flat throughout (rules out an external/network-driven cause) |
| 05:56:24 onward | Affected containers stuck mid-teardown — repeated `containerd`/`runc` errors (`unable to destroy container: container still running`, `reading from a closed fifo`, `ttrpc: received message on inactive stream`) |
| 06:04:04 | Rootless `docker.service` killed by the kernel OOM killer (`restart counter is at 4` — already restarted 3 times before this instance) |
| 06:04:04–06:25:45 | Crash-restart loop continues; each restart re-attempts cleanup of the same broken containers and fails the same way; `journalctl` for this boot ends at 06:25:45 |
| ~06:25 – ~07:07 | VM effectively unreachable: SSH accepts TCP but never sends its banner; `qemu-guest-agent` unresponsive (confirmed via a failed live `hcloud server reset-password` attempt) |
| ~07:07 | `hcloud server reboot` (soft ACPI) issued — metrics confirm it had **no effect**; the guest was too wedged to honor it |
| ~07:08 | `hcloud server reset` (hard power-cycle) issued; SSH reachable again within ~20 seconds |
| 07:08–07:46 | Live diagnosis: `journalctl -b -1` read (before the crashed boot's logs aged out), `docker ps -a`, `docker inspect` on the affected containers, `free -h`, `systemctl --user status docker.service`, cgroup memory-limit checks, `netdata` per-process query (inconclusive) |
| Same session | Mitigations applied: 4GB swap added and persisted; 24 months-old dead containers pruned; an unrelated client-side `IPQoS 0x00` syntax bug (broke local SSH entirely) fixed |

## Timeline (7th occurrence — 2026-07-28, all times UTC)

| Time | Event |
|---|---|
| ~11:28 (approx.) | User notices `ssh dev` failing repeatedly with `Connection timed out during banner exchange`; reproduced live via a direct `ssh -o BatchMode=yes` test |
| 11:28:07–11:59:25 | `make check` (read-only) run twice: CPU sustained at 690-720%, disk reads at a continuous 1.0-1.3 GB/s, near-zero writes, network flat — matches the 2026-07-24 signature closely |
| 11:33:36 | Container `0ae9c5fbb44c` (`wfmctrading-app-1`, the Laravel app) killed by the kernel OOM killer |
| 11:40:06 | Rootless `docker.service` itself killed by the kernel OOM killer |
| 11:40:07 | `docker.service`: `Failed with result 'exit-code'`; `app.slice` also hit by the OOM killer |
| 11:40:09–11:40:13 | `docker.service` restarts (`restart counter is at 1`); two containers (`bodego-postgres`, `turtley-db-1`) briefly fail to start on shim ID conflicts, then `dockerd` finishes loading successfully — unlike 2026-07-24, no *repeating* crash-restart loop is visible in the retained logs at this unit level |
| 11:41:33–11:43:42 | Two short SSH sessions connect and cleanly disconnect; a third session starts at `11:43:42` — the last entry in this boot's journal. The VM went unresponsive shortly after, despite `docker.service` itself having already restarted 3+ minutes earlier — **what consumed CPU/disk that heavily during this window is not confirmed** (see `timeline.md`'s "open nuance" note) |
| 11:43:42–12:03:38 | VM fully unreachable (not merely busy) — the journal for the crashed boot ends at `11:43:42`, and the next boot doesn't start until `12:03:38`, a ~20-minute gap |
| ~11:59 (user confirmation given) | User approves running `make recover`, since it can reboot/reset the VM |
| 12:03:38 | New boot starts — `make recover`'s escalation ladder (password-reset → soft reboot → hard reset) completed successfully; the ladder's exact successful rung isn't re-confirmable from this session's retained output, but the ~20-minute downtime is consistent with escalating to a hard reset, as in 2026-07-24 |
| 12:03:46–12:03:49 | Postmortem auto-captured by `make recover`, saved to `~/vm-incident-logs/20260728T120346Z.log` |
| 12:03:49 onward | Live diagnosis: full `journalctl -b -1` grep for OOM/kill events (the postmortem's `tail -300` alone didn't reach far enough back to show the trigger); cross-referenced the OOM'd container ID against `docker ps -a` to identify `wfmctrading-app-1`; read the container's PHP-FPM error log directly, finding the 53-hour worker lifetime; read `~/repos/wfmctrading/docker-compose.yml` and `Dockerfile`, confirming no `mem_limit` anywhere and no `pm.max_requests` set |
| Same session | Fix applied: `mem_limit` added to all three `wfmctrading` compose services, directly on the VM (uncommitted — separate repo, user's call to commit); validated with `docker compose config` |

## Root cause

### Proximate cause

**2026-07-24:** the rootless `docker.service` entered a **crash-restart loop** after two containers' health checks failed and could not be cleanly torn down, was killed once by the kernel's OOM killer, and then kept re-failing on restart in a way that consumed CPU and disk I/O heavily enough to starve every other process on the VM — including `sshd`.

**2026-07-28:** a single container (`wfmctrading-app-1`) was OOM-killed first, and ~6.5 minutes later the memory pressure escalated to killing `docker.service` itself. Unlike the first occurrence, `docker.service` restarted cleanly on the first attempt (no repeating crash-loop visible at the unit level) — but the VM as a whole remained starved and unreachable for another ~20 minutes regardless, for reasons not fully confirmed (see `timeline.md`).

**Both times:** `sshd` could still complete a TCP handshake (handled by the kernel, independent of process scheduling) but was never scheduled to send its application-layer banner, producing the exact symptom reported. Both times trace back to the same systemic gap: nothing on this VM enforces a memory ceiling on any container, so one process's uncontrolled growth can take down the entire host.

### Five whys

**2026-07-24 occurrence:**

1. **Why did SSH banner exchange time out?** Because `sshd` never got scheduled to send the banner after the TCP handshake completed.
2. **Why didn't `sshd` get scheduled?** Because the VM's CPU and disk I/O were pegged (600-800% CPU, ~1GB/s disk reads) continuously for over an hour.
3. **Why were CPU/disk pegged?** Because `docker.service` was stuck in a crash-restart loop, and each restart re-attempted (and failed) the same expensive container cleanup.
4. **Why was `docker.service` restart-looping?** Because it had been killed once by the kernel OOM killer, and each subsequent restart hit containers already stuck in a bad teardown state from before the kill, so cleanup failed identically every time.
5. **Why did the OOM killer fire in the first place?** Unconfirmed. Leading theory: ~10-15 concurrent SSH-backed connections (4 VS Code Remote-SSH windows × 2-3 terminals, each window running its own independent `vscode-server` + extension-host process tree) added memory demand on top of the already-running containers, on a VM with **zero swap** at the time — plausible and consistent with all other evidence, but not provable after the fact, since no per-process memory snapshot from that exact moment was captured.

The chain is fully evidenced from step 1 through step 4. Step 5 is the one link in the chain that is inference, not fact — see `analysis.md`'s "Best-fit explanation" for the full caveat.

**2026-07-28 occurrence — all five links confirmed directly, no inference required:**

1. **Why did SSH banner exchange time out?** Same mechanism — `sshd` never got scheduled to send the banner.
2. **Why didn't `sshd` get scheduled?** CPU pegged at 690-720%, disk reads at 1.0-1.3 GB/s, for at least ~30 minutes (confirmed via `hcloud server metrics`).
3. **Why were CPU/disk pegged?** `docker.service` itself had been killed by the OOM killer and needed to restart, and the VM remained heavily loaded for roughly 20 minutes afterward.
4. **Why was `docker.service` OOM-killed?** Memory pressure escalated from a single container (`wfmctrading-app-1`, killed at `11:33:36`) to the daemon itself (`11:40:06`), confirmed directly via `journalctl -b -1`.
5. **Why did `wfmctrading-app-1` consume enough memory to trigger this?** Confirmed directly from the container's own PHP-FPM error log: a worker process had been continuously alive for ~53 hours with no recycling (`pm.max_requests` unset), accumulating memory from Laravel/Filament's per-request static caches and component-state registries across that entire span, with no `mem_limit` on the container to cap it before it could affect the rest of the VM.

### Contributing factors

| Factor | Role | Status |
|---|---|---|
| Zero swap on the VM | Removed any cushion between a memory spike and an immediate OOM kill | **Fixed** 2026-07-24 — 4GB swap added, `vm.swappiness=10`. **Confirmed insufficient alone** by the 2026-07-28 recurrence, a genuine OOM the swap cushion didn't prevent |
| Tight, self-contained health checks with no backoff (`pg_isready`, `unless-stopped` restart policy) | Turned a transient resource blip into a crash-restart loop rather than a graceful degradation | **Not fixed** |
| No cgroup memory ceilings (`docker.service`, `app.slice`, `user-1000.slice` all `MemoryMax=infinity`) | Let one bad actor's memory demand affect the entire VM rather than being contained | **Not fixed** |
| No per-container memory limits in any compose stack | Let a single container's unbounded growth escalate into a daemon-level, then VM-wide, OOM | **Fixed for `wfmctrading` 2026-07-28** (`mem_limit` on all 3 services). **Not fixed** for `turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold` |
| PHP-FPM workers never recycled (`pm.max_requests` unset) in `wfmctrading` | Allowed one worker's per-request memory growth to accumulate unbounded across a 53-hour process lifetime | **Not fixed** — identified 2026-07-28, recommended (`pm.max_requests: 300-500`), not yet applied |
| No out-of-band console access (lost as a side effect of separate VM-hardening work) | Removed the originally-planned recovery path, forcing reliance on the `hcloud` API instead | Worked around both times; underlying access gap not addressed |
| No automated monitoring/alerting on the VM | Every occurrence so far was discovered only when the user happened to try to connect | **Not addressed** — see recommendations below |

## Detection and response assessment

**What did not work (prior 5 occurrences, undiagnosed):** each was treated as an SSH-layer problem (VS Code multiplexing, systemd socket activation, client `ControlMaster`, MTU/proxy settings) because that was the only layer visible from a locked-out client. Every occurrence ended in a full VM reboot before any system state could be captured, which destroyed the evidence and reset the diagnostic process to zero each time. One of the attempted fixes (`IPQoS 0x00`) was itself a syntax error that silently broke the local SSH client, adding a second, unrelated failure mode on top of the real one.

**What worked (6th occurrence, 2026-07-24):** treating "port open, TCP completes, nothing after that" as evidence the failure was below the SSH application layer, rather than continuing to tune SSH config. Confirmed the failure was VM-side (not network-path) via a mobile-hotspot test *before* console access was even attempted. When console access turned out to be unavailable, `hcloud server metrics` (read-only, no VM access) supplied the CPU/disk evidence, and `journalctl -b -1` read immediately after a hard reset (before the crashed boot's logs rotated out) supplied the mechanism.

**What worked even better (7th occurrence, 2026-07-28):** the `Makefile` built after the 6th occurrence turned the entire response into one command (`make recover`) instead of a manual `hcloud` sequence, and the "check `docker.service`/`journalctl` before assuming SSH" rule meant the investigation went straight to the right layer with no wasted attempts at SSH-layer fixes at all. The one gap this occurrence exposed: the postmortem's `tail -300` of the crashed boot's journal wasn't enough to reach back to the actual trigger — a full, ungrepped `journalctl -b -1` (or a larger tail) was needed to find the OOM-kill lines.

## Impact

- VM completely unreachable via SSH and VS Code Remote-SSH during each of the 7 occurrences, blocking the user's primary development workflow ("i cant work" — direct quote from the 2026-07-24 session).
- Multiple hours of troubleshooting effort across at least two AI-assisted sessions before the July 24 root cause was found; the July 28 recurrence, by contrast, went from symptom to fix in under an hour thanks to the tooling built after the first occurrence.
- No data loss or corruption identified from either hard power-cycle (write I/O stayed at baseline throughout both incidents; only reads were elevated). A Hetzner hard reset does not destroy the VM itself — disk, image, and IP all persist independent of guest OS state.
- **Standing, not-yet-realized risk:** `bodego-postgres` and `turtley-db-1` run continuously on this VM regardless of which container triggers the next cascade. A hard power-cycle is not a clean shutdown; an unlucky-timed reset landing mid-write to either database is the actual worst-case exposure here (relying on Postgres WAL recovery + ext4 journaling, both normally reliable but not guaranteed) — not VM destruction, but potential data corruption in an always-on database. See `analysis.md`'s "Worst-case blast radius" section for the full discussion. This risk persists until `mem_limit` is rolled out to every stack on the VM, not just `wfmctrading`.

## Corrective actions

### Completed (2026-07-24)

- [x] Added 4GB swap, persisted (`/etc/fstab`), `vm.swappiness=10`.
- [x] Pruned 24 months-old dead containers (`erpnext-distribution-*`, `frappe_docker-*`).
- [x] Fixed the unrelated `IPQoS 0x00` client-side syntax bug.
- [x] Removed a redundant duplicate `Host dev` config block (`~/.ssh/config` vs. `~/.ssh/config.local`).
- [x] Built `ssh-vm-banner-timeout/Makefile` (`make recover`/`check`/`postmortem`) so the next occurrence gets a fast, evidence-preserving response instead of an immediate reboot.

### Completed (2026-07-28)

- [x] Diagnosed the recurrence end-to-end using the July 24 tooling: `make check` → `make recover` → postmortem → full-boot `journalctl -b -1` grep, no SSH-layer dead ends re-attempted.
- [x] Confirmed the trigger directly (unlike July 24's inference): `wfmctrading-app-1`, a PHP-FPM worker alive ~53 hours with no recycling.
- [x] Added `mem_limit` to all three `wfmctrading` compose services (`app: 2g`, `nginx: 256m`, `postgres: 1g`), validated against live Docker Compose documentation to confirm it's enforced outside Swarm mode. Applied directly on the VM; left uncommitted in the separate `wfmctrading` repo for the user to commit.
- [x] Documented the recurrence fully in `timeline.md`, `analysis.md`, and this RCA, including the parts that remain unconfirmed (the 20-minute unresponsive window after `docker.service`'s own restart).

### Recommended, not yet done

| Action | Priority | Why |
|---|---|---|
| Set `pm.max_requests` (300-500) on the `wfmctrading` php-fpm pool | High | Addresses the behavioral root cause (workers never recycled) that let a single worker's memory grow unbounded over 53 hours; `mem_limit` alone only bounds the blast radius |
| Add `mem_limit` to the other unbounded stacks on this VM — `turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold` | High | Any of them could reproduce the same failure; only `wfmctrading` has been fixed so far |
| Add health-check timeout/retry tuning and a backoff-aware restart policy (replace bare `unless-stopped`) on the Postgres containers | High | Directly addresses the mechanism that turned a blip into a crash-restart loop in the July 24 occurrence |
| Confirm what kept CPU/disk pegged for ~20 minutes after `docker.service`'s own restart on 2026-07-28 — capture `ps aux --sort=-%mem` or a live `netdata` per-process view *during* the next incident, before any restart | Medium | The one unconfirmed link in the July 28 chain; only provable while it's happening |
| Add basic alerting for `docker.service` restarts / OOM-kill events (e.g. via the already-installed `netdata`) | Medium | Both diagnosed occurrences were discovered by the user manually failing to connect — no early warning existed either time |
| Decide whether the above should be implemented directly (as done twice now) or through the separate `debian-server-scripts` repo that otherwise manages this VM's hardening | Low (process, not technical) | Keeps VM provisioning consistent with how the rest of its hardening is managed |
| Determine whether this same mechanism explains the 5 earlier, undiagnosed occurrences | Low (retrospective only) | Only the two most recent prior boots' journals have been checked; earlier boots' logs have long since rotated out and can't be recovered |

## Open questions

- What specifically triggered the 2026-07-24 05:56:24 memory pressure (see Five Whys, 2026-07-24, step 5) — still unconfirmed.
- What kept the VM pegged and unreachable for ~20 minutes on 2026-07-28 *after* `docker.service` itself had already restarted cleanly at `11:40:13` — still unconfirmed.
- Whether the 5 earlier, undiagnosed occurrences share this root cause (no memory ceiling anywhere) or had a different one that was never identified.

## References

- `README.md` — index and the one-page summary.
- `timeline.md` — full chronological log of every attempt, including the five ruled-out ones this RCA doesn't re-litigate.
- `analysis.md` — the detailed technical writeup this RCA is condensed from, including the note on which explanations from an earlier troubleshooting session (with a different AI assistant) didn't hold up technically.
- `configs.md` — current state of every config file touched, both machines.
- `runbook.md` — the diagnostic procedure that produced this RCA's evidence; kept for reuse.
- `Makefile` — `make recover` / `make check` / `make postmortem`, the automated version of `runbook.md`.
