# Timeline of Attempts

## Overview

This is the chronological record of every fix attempted for the SSH banner-exchange timeout on the `dev` VM, in the order they happened, before this documentation existed. Each entry lists the theory that motivated it, the exact change made, and the result. None of the five attempts fixed the underlying issue, and one (attempt 4's `IPQoS` line) turned out to be a syntax bug that broke the SSH client entirely, unrelated to the VM problem. They are recorded in detail specifically so they are not repeated — each looked plausible at the time, and without this record the same dead ends would likely get re-tried after the next Wi-Fi drop. The common thread across attempts 1-4: every one of them modified SSH-layer or client/network-path behavior, and none of them addressed the system resource layer underneath `sshd`, which is where the evidence now points (see [`analysis.md`](analysis.md)) — a conclusion attempt 5 (a network-independent retry from a mobile hotspot) further confirms.

## Table of Contents

- [Overview](#overview)
- [Attempt 1 — Mitigate VS Code multiplexing storms](#attempt-1-mitigate-vs-code-multiplexing-storms)
- [Attempt 2 — Systemd socket activation deadlock](#attempt-2-systemd-socket-activation-deadlock)
- [Attempt 3 — Complete removal of client multiplexing](#attempt-3-complete-removal-of-client-multiplexing)
- [Attempt 4 — Client proxy and MTU blackholing](#attempt-4-client-proxy-and-mtu-blackholing)
- [Diagnostic that reframed the problem](#diagnostic-that-reframed-the-problem)
- [Attempt 5 — Switch client network entirely (mobile hotspot)](#attempt-5-switch-client-network-entirely-mobile-hotspot)
- [Self-inflicted regression — invalid `IPQoS` syntax broke the SSH client outright](#self-inflicted-regression-invalid-ipqos-syntax-broke-the-ssh-client-outright)
- [Attempt 6 (2026-07-24) — Live diagnosis via `hcloud`, cascade mechanism found](#attempt-6-2026-07-24-live-diagnosis-via-hcloud-cascade-mechanism-found)
- [Follow-up (2026-07-24) — Partial mitigation implemented](#follow-up-2026-07-24-partial-mitigation-implemented)
- [Recurrence (2026-07-28) — Same cascade, different trigger: wfmctrading OOM](#recurrence-2026-07-28-same-cascade-different-trigger-wfmctrading-oom)

## Attempt 1 — Mitigate VS Code multiplexing storms

- **Theory:** VS Code Remote-SSH opens 10-20 multiplexed connections per window. A network drop leaves dead TCP sockets behind; on reconnect, the burst of new VS Code connections exhausts the server's connection queue.
- **Action (server, `/etc/ssh/sshd_config`):** increased `MaxStartups`, disabled `TCPKeepAlive`, increased `LoginGraceTime`.
- **Result:** Failed. Still timed out on the next drop.

## Attempt 2 — Systemd socket activation deadlock

- **Theory:** Debian 13 defaults to `ssh.socket` activation. Under a sudden drop with many active connections, systemd's socket wrapper deadlocks and stops handing connections to `sshd`.
- **Action (server):** disabled `ssh.socket`, enabled and started the persistent `ssh.service` (classic standalone daemon). Confirmed running on a stable PID.
- **Result:** Failed. Still timed out on network drops with the classic daemon running.

## Attempt 3 — Complete removal of client multiplexing

- **Theory:** Client-side `ControlMaster` sockets were becoming corrupted on a drop, causing ghost hangs on the next connection attempt.
- **Action (client, `~/.ssh/config`):** removed `ControlMaster`, `ControlPath`, `ControlPersist` entirely. Removed the local `fix-ssh` cleanup alias that used to `pkill` SSH and delete `~/.ssh/cm-*` control sockets.
- **Result:** Failed. `ssh -v` showed the client completing TCP establishment cleanly, then hanging waiting for the server's banner string — i.e. the hang was confirmed to be server-side, not a client control-socket artifact.

## Attempt 4 — Client proxy and MTU blackholing

- **Theory:** A systemd SSH proxy unit on the client, or Path MTU fragmentation over Wi-Fi, was silently dropping the banner packet in transit.
- **Action (client):** deleted `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf`. Added `IPQoS 0x00` to the client config.
- **Result:** Failed.

## Diagnostic that reframed the problem

After attempt 4, running two plain `nc` tests (not SSH at all) established the actual failure point:

```
nc -zv -w 3 178.104.35.30 22   →  succeeds, port 22 is open (TCP handshake completes)
nc 178.104.35.30 22            →  hangs indefinitely, zero bytes returned
```

Because `nc` is a completely different client than either OpenSSH or VS Code's SSH implementation, and it fails identically, this ruled out every client-side theory (attempts 3 and 4) and reframed the problem as: the TCP handshake is being completed by the kernel, but nothing is ever sending application data back — which points below the SSH application layer entirely. See [`analysis.md`](analysis.md) for what that implies and the ranked hypotheses for the actual cause.

## Attempt 5 — Switch client network entirely (mobile hotspot)

- **Theory:** the home Wi-Fi router or ISP was CGNAT-shifting the public IP on reconnect, or a Hetzner/`fail2ban`-style edge rule had temporarily banned the home IP after the earlier reconnect burst.
- **Action (client):** disconnected from home Wi-Fi entirely and retried from a mobile carrier hotspot — a completely different public IP, different NAT, different network path.
- **Result:** Failed identically (`Connection timed out during banner exchange`). This is important confirmed evidence: since the failure persists across a totally unrelated network and public IP, it rules out CGNAT/IP-roaming and any IP-specific ban or rate-limit as the cause. The problem is not in the path between client and server — it's at (or behind) the server itself, which strengthens all three ranked hypotheses in [`analysis.md`](analysis.md) and closes off any remaining client/network-path theory.

## Self-inflicted regression — invalid `IPQoS` syntax broke the SSH client outright

During attempt 4, `IPQoS 0x00` was added to `~/.ssh/config` on the theory that it would stop routers from mishandling QoS-marked SSH packets. This value is **invalid syntax** for OpenSSH's `IPQoS` directive — it needs a plain decimal value (`IPQoS 0`), a named DSCP class (e.g. `cs0`), or `none`; the `0x`-prefixed hex form is rejected outright. On this client's OpenSSH 10.0p2, that made the *entire* SSH client refuse to run at all, for any host, with:

```
/home/willard/.ssh/config line 7: Bad IPQoS value: 0x00
/home/willard/.ssh/config: terminating, 1 bad configuration options
```

This was never caught at the time because the follow-up test was a raw `nc 178.104.35.30 22` (which doesn't read `~/.ssh/config` at all), not `ssh -v`. So for some period, *every* SSH connection from this client was failing at config-parse time, before ever reaching the network — a self-inflicted bug layered on top of the real VM issue, discovered and fixed in this session (2026-07-24) by changing the line to `IPQoS 0`. See [`analysis.md`](analysis.md) for why the underlying "IPQoS fixes MTU blackholing" theory was technically unsound to begin with (IPQoS sets DSCP/QoS marking bits; it has no relationship to packet size or MTU).

## Attempt 6 (2026-07-24) — Live diagnosis via `hcloud`, cascade mechanism found

- **Access problem:** the user could no longer reach the Hetzner out-of-band VNC console at all (believed to be a side effect of the base/dev hardening scripts from a separate "debian server scripts" repo, which may have removed root login or console-usable credentials).
- **Action:** used the `hcloud` CLI directly instead of the web dashboard (had to switch context — the `dev` server lives under a different Hetzner project than the one active by default).
  - `hcloud server metrics dev --type cpu|network|disk` (read-only, no VM access needed) showed a sustained anomaly starting exactly **05:56:24 UTC**: CPU at 600-800% and disk reads at ~1.0-1.3 GB/s, continuously, with **no corresponding network spike** — ruling out an external/network cause and pointing at something internal to the VM.
  - `hcloud server reset-password dev` (a live, no-reboot root-password reset via `qemu-guest-agent`) was tried first as a cheap option — failed with `guest_agent_unavailable`, itself useful evidence that the guest was too starved to service even a side-channel request.
  - `hcloud server reboot dev` (soft ACPI reboot) was tried next — issued successfully but had no effect; metrics showed the CPU/disk anomaly continuing unchanged afterward, meaning the wedged guest never actually honored the signal.
  - `hcloud server reset dev` (hard power-cycle) was used as the final escalation — this one worked; SSH was back within ~20 seconds.
  - Immediately after recovery, `journalctl -b -1` (previous boot's logs, read before they aged out) showed a Docker container health-check failure at 05:56:24 that cascaded into the rootless `docker.service` getting OOM-killed and stuck in a crash-restart loop. An SSH disconnect was logged in the same second, but a follow-up check (`docker inspect` on the affected containers) showed their health checks are self-contained `pg_isready` probes with no dependency on the SSH session — so the SSH drop and the health-check failure are **both symptoms of the same moment**, not cause-and-effect. What actually triggered that moment (05:56:21-24) is still unidentified: no cron job or systemd timer was due then, and `journalctl` shows nothing in the few minutes prior except a new SSH session starting at 05:54:21 from the same client IP.
- **Result:** VM recovered, and the crash-restart cascade is confirmed with direct evidence (not a hypothesis) — but the initial trigger for the cascade, and whether this same mechanism explains attempts 1-5 above, are both still open. See [`analysis.md`](analysis.md) for the full mechanism, what's confirmed vs. not, and what's still needed to prevent a recurrence (swap, container health-check resilience, memory limits).

## Follow-up (2026-07-24) — Partial mitigation implemented

With SSH access restored, two items from `analysis.md`'s fix list were implemented directly on the VM:

- **Swap added:** a 4GB swapfile (`/swapfile`), persisted via `/etc/fstab`, with `vm.swappiness=10`. Confirmed live via `free -h` (`Swap: 4.0Gi`, `0B` used). This required an interactive `sudo` password, so the commands were handed to the user to run directly rather than piped through a non-interactive SSH command.
- **Old containers pruned:** all 24 `erpnext-distribution-*` and `frappe_docker-*` containers (2-8 weeks old, `docker ps -a` showed them all `Exited`) were removed. `wfmctrading-*` and `ollama` were deliberately left alone — those had only exited 3-5 days prior, too recent to assume they're dead weight rather than intentionally stopped.

Not yet done: health-check/restart resilience, per-container memory limits, and confirming the actual trigger (still an open question — see `analysis.md`). Also found but not acted on: `docker system df` shows ~7.4GB of unused images and ~8.8GB of reclaimable build cache — left alone since clearing it wasn't part of the original fix list and would just mean slower rebuilds next time those layers are needed.

## Recurrence (2026-07-28) — Same cascade, different trigger: wfmctrading OOM

Four days after the July 24 fix, the identical symptom returned: `ssh dev` failing repeatedly with `Connection timed out during banner exchange`. This section documents the full sequence, step by step, including what worked on the first try (unlike the five SSH-layer dead ends above, this occurrence went straight to a fix — because the July 24 `Makefile`/runbook existed specifically to skip re-litigating those).

- **Confirmed down directly:** `ssh -o BatchMode=yes -o ConnectTimeout=5 dev 'true'` reproduced the exact same failure live, ruling out a stale/cached report.
- **`make check` (read-only, no VM access):** metrics for the prior 30 minutes showed CPU sustained at 690-720%, disk reads at a continuous 1.0-1.3 GB/s with near-zero writes, and network traffic low/flat — a near-exact match for the July 24 signature. This was read-only evidence gathered *before* any recovery action was taken, per the "check `docker.service`/`journalctl` before assuming SSH" rule established after July 24.
- **User hypothesis raised mid-investigation:** "could i be spinning up repeating containers?" — flagged at the time as plausible but unconfirmed (matches the CPU-pegged/disk-read-heavy signature of a restart loop), pending direct log evidence.
- **`make recover` executed (explicit user go-ahead given first, since it can reboot/reset the VM):** the Makefile's escalation ladder ran to completion — non-destructive password-reset first, then soft ACPI reboot, then hard power-cycle as needed, per its documented logic (see `Makefile`). The run's full step-by-step console output was not preserved verbatim past a later context-compaction boundary in this session, so which exact rung of the ladder succeeded isn't re-confirmable from this record. What **is** confirmed directly from `journalctl --list-boots` on the recovered VM: the previous boot's journal ends at `11:43:42 UTC`, and the next boot only starts at `12:03:38 UTC` — a ~20-minute gap during which the VM was fully unreachable (not merely busy), consistent with the ladder needing to escalate all the way to a hard reset rather than the non-destructive password-reset alone succeeding.
- **Postmortem auto-captured** by `make recover` on successful recovery, saved to `~/vm-incident-logs/20260728T120346Z.log` (`uptime`, `free -h`, top memory processes, `docker.service` status, `docker ps -a`, `journalctl --list-boots`, and a `tail -300` of the crashed boot's journal).
- **Live diagnosis, round 1 (the `tail -300` in the postmortem):** showed `docker.service` already mid-restart at `11:40:09-11:40:13`, with two containers (`bodego-postgres`, `turtley-db-1`) failing to start on `"container with given ID already exists"` shim conflicts before `dockerd` finished loading successfully. This tail window didn't reach far enough back to show *why* the restart happened in the first place — the trigger was outside the last 300 lines.
- **Live diagnosis, round 2 (full-boot journal grep, run directly over SSH once access was back):** `journalctl -b -1 | grep -iE "oom|killed process|..."` found the actual chain:
  ```
  11:33:36  docker-0ae9c5fbb44c...scope: process killed by the OOM killer
  11:40:06  docker.service: killed by the OOM killer
  11:40:07  docker.service: Failed with result 'exit-code'; app.slice also hit by OOM killer
  11:40:09  docker.service: Scheduled restart job, restart counter is at 1
  ```
- **User hypothesis, round 2:** "was it the wfmctrading repo? i was devving hard, its a laravel app" — checked directly against `docker ps -a` from the postmortem: container `0ae9c5fbb44c` is `wfmctrading-app-1`. **Confirmed correct.**
- **Why the container could accumulate enough memory to trigger a system-wide OOM kill — two compounding gaps found:**
  1. `~/repos/wfmctrading/docker-compose.yml` set no `mem_limit` on any of its three services (`app`, `nginx`, `postgres`) — the same "no per-container memory limits" gap flagged as open after July 24, just never applied to this specific project (the July 24 session's cleanup deliberately left `wfmctrading-*` alone, since those containers were only recently exited at the time and weren't part of that day's fix scope).
  2. The `wfmctrading-app-1` PHP-FPM error log showed `child 7 exited on signal 9 (SIGKILL) after 192096.897489 seconds from start` — **that worker process had been continuously alive for ~53 hours.** The Dockerfile never sets `pm.max_requests` on the php-fpm pool (disabled/commented-out by default in the stock `php:8.4-fpm` image), so workers are never recycled. `uploads.ini` caps a single request's memory at 256M, but that doesn't bound a long-lived worker's cumulative RSS growth from Laravel/Filament's per-request static caches, event-listener bindings, and Livewire component-state registries — none of which fully release between requests. Over 53 hours of active dev traffic on one process, that's enough slow accumulation to matter, independent of concurrent request volume (this was one developer, not production load).
- **Verified before recommending a fix (not assumed from training data):** queried Context7's live Docker Compose documentation to confirm `mem_limit`/`deploy.resources.limits.memory` is actually enforced by a plain `docker compose up` on this VM's installed version (Compose v5.3.1) and not a Swarm-only no-op — confirmed via the `getDeployResources`/`setLimits` source mapping in `docker/compose`.
- **Fix applied (2026-07-28, this session):** added `mem_limit: 2g` / `mem_reservation: 512m` to `app`, `mem_limit: 256m` to `nginx`, and `mem_limit: 1g` to `postgres` in `~/repos/wfmctrading/docker-compose.yml`, directly on the VM. Validated with `docker compose config` (parses cleanly). The file is git-tracked in the separate `wfmctrading` repo; the change is applied to the working tree but **deliberately left uncommitted** — that repo isn't managed by this dotfiles repo or session, so the commit is the user's call.
- **Recommended but not yet applied:** set `pm.max_requests` (commonly 300-500) on the php-fpm pool in the wfmctrading `Dockerfile`. `mem_limit` bounds the *blast radius* if a worker's memory grows unbounded again; `pm.max_requests` addresses the *behavioral root cause* (workers that are never recycled) that let it grow unbounded in the first place. Both are complementary, not substitutes for each other.
- **An open nuance, recorded honestly:** `docker.service`'s own log shows it restarted cleanly by `11:40:13` — unlike July 24, there's no evidence in the retained logs of a *repeating* crash-restart loop at the `docker.service`-unit level this time. Yet the CPU/disk-starved signature measured via `hcloud server metrics` continued through at least `11:59 UTC`, and the VM stayed fully unreachable until the hard reset at `~12:03:38 UTC` — roughly 23 minutes after `docker.service` itself had already come back up. What consumed CPU/disk that heavily during that gap (the two containers retrying their own crash-recovery, e.g. Postgres WAL replay after the earlier unclean OOM kill, versus something else) is **not confirmed** — no journal data survives from inside that window, since the boot itself ended at `11:43:42` and the VM was down (not just busy) until the next boot started. Flagged here rather than glossed over, matching this repo's existing standard of not overstating certainty (see `analysis.md`'s "confirmed vs. still open" sections).
- **Result:** SSH access confirmed stable and reachable from `~12:03:38 UTC` onward through the end of this session.
