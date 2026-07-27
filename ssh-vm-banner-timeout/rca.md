# Root Cause Analysis — SSH Banner Exchange Timeout on `dev` VM

## Overview

This is the formal root-cause analysis for the recurring `dev` VM incident: SSH connections failed with `Connection timed out during banner exchange`, and for five prior occurrences the only recovery was a full VM reboot — which destroyed the evidence needed to diagnose it each time. On the sixth occurrence (2026-07-24), the VM was recovered without the previously-relied-on console access, using the `hcloud` CLI plus a `journalctl` read taken immediately after recovery, which finally captured direct evidence. Proximate cause: a Docker container health-check failure cascaded into the rootless `docker.service` being OOM-killed and stuck in a crash-restart loop, which starved the entire VM's CPU and disk I/O — including `sshd`, which is why SSH itself looked like the problem. The initial trigger for the underlying memory pressure remains unconfirmed. This report exists to consolidate the finding into a standard incident-review structure — for narrative detail, `timeline.md` and `analysis.md` remain the source of record.

## Table of Contents

- [Overview](#overview)
- [Incident summary](#incident-summary)
- [Timeline (final, diagnosed occurrence — 2026-07-24, all times UTC)](#timeline-final-diagnosed-occurrence-2026-07-24-all-times-utc)
- [Root cause](#root-cause)
  - [Proximate cause](#proximate-cause)
  - [Five whys](#five-whys)
  - [Contributing factors](#contributing-factors)
- [Detection and response assessment](#detection-and-response-assessment)
- [Impact](#impact)
- [Corrective actions](#corrective-actions)
  - [Completed (2026-07-24)](#completed-2026-07-24)
  - [Recommended, not yet done](#recommended-not-yet-done)
- [Open questions](#open-questions)
- [References](#references)

## Incident summary

| Field | Value |
|---|---|
| Affected system | `dev` (Hetzner Cloud VM, `178.104.35.30`, Debian 13, rootless Docker) |
| Symptom | `Connection timed out during banner exchange` on every SSH client (OpenSSH, VS Code Remote-SSH, plain `nc`) |
| Occurrences | 6 confirmed (5 prior, undiagnosed; 1 on 2026-07-24, diagnosed) |
| Detection method | Manual — user noticed SSH failures; no automated alerting existed |
| Resolution (final occurrence) | `hcloud server reset` (hard power-cycle) after a soft reboot had no effect; ~20s to recovery once issued |
| Status | **Proximate cause confirmed; initial trigger unconfirmed; partial mitigation shipped, full remediation not yet complete** |

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

## Root cause

### Proximate cause

The rootless `docker.service` entered a **crash-restart loop** after two containers' health checks failed and could not be cleanly torn down, was killed once by the kernel's OOM killer, and then kept re-failing on restart in a way that consumed CPU and disk I/O heavily enough to starve every other process on the VM — including `sshd`. `sshd` could still complete a TCP handshake (handled by the kernel, independent of process scheduling) but was never scheduled to send its application-layer banner, producing the exact symptom reported.

### Five whys

1. **Why did SSH banner exchange time out?** Because `sshd` never got scheduled to send the banner after the TCP handshake completed.
2. **Why didn't `sshd` get scheduled?** Because the VM's CPU and disk I/O were pegged (600-800% CPU, ~1GB/s disk reads) continuously for over an hour.
3. **Why were CPU/disk pegged?** Because `docker.service` was stuck in a crash-restart loop, and each restart re-attempted (and failed) the same expensive container cleanup.
4. **Why was `docker.service` restart-looping?** Because it had been killed once by the kernel OOM killer, and each subsequent restart hit containers already stuck in a bad teardown state from before the kill, so cleanup failed identically every time.
5. **Why did the OOM killer fire in the first place?** Unconfirmed. Leading theory: ~10-15 concurrent SSH-backed connections (4 VS Code Remote-SSH windows × 2-3 terminals, each window running its own independent `vscode-server` + extension-host process tree) added memory demand on top of the already-running containers, on a VM with **zero swap** at the time — plausible and consistent with all other evidence, but not provable after the fact, since no per-process memory snapshot from that exact moment was captured.

The chain is fully evidenced from step 1 through step 4. Step 5 is the one link in the chain that is inference, not fact — see `analysis.md`'s "Best-fit explanation" for the full caveat.

### Contributing factors

| Factor | Role | Status |
|---|---|---|
| Zero swap on the VM | Removed any cushion between a memory spike and an immediate OOM kill | **Fixed** — 4GB swap added, `vm.swappiness=10` |
| Tight, self-contained health checks with no backoff (`pg_isready`, `unless-stopped` restart policy) | Turned a transient resource blip into a crash-restart loop rather than a graceful degradation | **Not fixed** |
| No cgroup memory ceilings (`docker.service`, `app.slice`, `user-1000.slice` all `MemoryMax=infinity`) | Let one bad actor's memory demand affect the entire VM rather than being contained | **Not fixed** |
| No out-of-band console access (lost as a side effect of separate VM-hardening work) | Removed the originally-planned recovery path, forcing reliance on the `hcloud` API instead | Worked around this time; underlying access gap not addressed |
| No automated monitoring/alerting on the VM | Every prior occurrence was discovered only when the user happened to try to connect | **Not addressed** — see recommendations below |

## Detection and response assessment

**What did not work (prior 5 occurrences, undiagnosed):** each was treated as an SSH-layer problem (VS Code multiplexing, systemd socket activation, client `ControlMaster`, MTU/proxy settings) because that was the only layer visible from a locked-out client. Every occurrence ended in a full VM reboot before any system state could be captured, which destroyed the evidence and reset the diagnostic process to zero each time. One of the attempted fixes (`IPQoS 0x00`) was itself a syntax error that silently broke the local SSH client, adding a second, unrelated failure mode on top of the real one.

**What worked (6th occurrence):** treating "port open, TCP completes, nothing after that" as evidence the failure was below the SSH application layer, rather than continuing to tune SSH config. Confirmed the failure was VM-side (not network-path) via a mobile-hotspot test *before* console access was even attempted. When console access turned out to be unavailable, `hcloud server metrics` (read-only, no VM access) supplied the CPU/disk evidence, and `journalctl -b -1` read immediately after a hard reset (before the crashed boot's logs rotated out) supplied the mechanism.

## Impact

- VM completely unreachable via SSH and VS Code Remote-SSH during each of the 6 occurrences, blocking the user's primary development workflow ("i cant work" — direct quote from this session).
- Multiple hours of troubleshooting effort across at least two AI-assisted sessions (a prior session with a different assistant, plus this one) before the actual cause was found.
- No data loss or corruption identified from the hard power-cycle (write I/O stayed at baseline throughout; only reads were elevated).

## Corrective actions

### Completed (2026-07-24)

- [x] Added 4GB swap, persisted (`/etc/fstab`), `vm.swappiness=10`.
- [x] Pruned 24 months-old dead containers (`erpnext-distribution-*`, `frappe_docker-*`).
- [x] Fixed the unrelated `IPQoS 0x00` client-side syntax bug.
- [x] Removed a redundant duplicate `Host dev` config block (`~/.ssh/config` vs. `~/.ssh/config.local`).
- [x] Built `ssh-vm-banner-timeout/Makefile` (`make recover`/`check`/`postmortem`) so the next occurrence gets a fast, evidence-preserving response instead of an immediate reboot.

### Recommended, not yet done

| Action | Priority | Why |
|---|---|---|
| Confirm the actual trigger — capture `ps aux --sort=-%mem` or a live `netdata` per-process view *during* the next incident, before any restart | High | The one unproven link in the root-cause chain; only provable while it's happening |
| Add health-check timeout/retry tuning and a backoff-aware restart policy (replace bare `unless-stopped`) on the Postgres containers | High | Directly addresses the mechanism that turned a blip into a crash-restart loop |
| Add per-container memory limits (`--memory` / compose `deploy.resources.limits.memory`) | Medium | Prevents one container from being able to exhaust VM-wide memory |
| Add basic alerting for `docker.service` restarts / OOM-kill events (e.g. via the already-installed `netdata`) | Medium | Every occurrence so far was discovered by the user manually failing to connect — no early warning existed |
| Decide whether the above should be implemented directly (as done for swap/pruning this session) or through the separate `debian-server-scripts` repo that otherwise manages this VM's hardening | Low (process, not technical) | Keeps VM provisioning consistent with how the rest of its hardening is managed |
| Determine whether this same mechanism explains the 5 earlier, undiagnosed occurrences | Low (retrospective only) | Only the most recent prior boot's journal was checked; earlier boots' logs have long since rotated out and can't be recovered |

## Open questions

- What specifically triggered the 05:56:24 memory pressure (see Five Whys, step 5).
- Whether the 5 earlier occurrences share this root cause or had a different one that was never identified.

## References

- `README.md` — index and the one-page summary.
- `timeline.md` — full chronological log of every attempt, including the five ruled-out ones this RCA doesn't re-litigate.
- `analysis.md` — the detailed technical writeup this RCA is condensed from, including the note on which explanations from an earlier troubleshooting session (with a different AI assistant) didn't hold up technically.
- `configs.md` — current state of every config file touched, both machines.
- `runbook.md` — the diagnostic procedure that produced this RCA's evidence; kept for reuse.
- `Makefile` — `make recover` / `make check` / `make postmortem`, the automated version of `runbook.md`.
