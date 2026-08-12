# Self-Healing, Early-Warning, and Client-Side Hardening (2026-07-29)

## Overview

Two diagnosed incidents (2026-07-24, 2026-07-28) shared one blind spot: by the time `Connection timed out during banner exchange` appears, `dev` is already too starved for SSH to work at all, leaving the `hcloud` API as the only recovery path. This document covers the follow-up work meant to close that gap — a systemd guard against Docker's crash-restart loop, a host-level memory ceiling for `vscode-server` processes (which sit outside container-level `mem_limit` protection), and a scheduled reaper for orphaned `vscode-server` sessions after VS Code Remote-SSH reconnect storms exhaust memory. This document tracks current mitigation status only; the incidents that drove each one live in their own per-incident files (linked below) so this one doesn't grow indefinitely.

## Table of Contents

- [Overview](#overview)
- [Incident log](#incident-log)
- [What's now in place](#whats-now-in-place)
  - [1. `docker.service` StartLimitBurst — stops the crash-restart loop from forming](#1-dockerservice-startlimitburst-stops-the-crash-restart-loop-from-forming)
  - [2. `netdata` email alerting](#2-netdata-email-alerting)
  - [3. Host-level memory ceiling (`user-1000.slice`)](#3-host-level-memory-ceiling-user-1000slice)
  - [4. Client-side: `ControlMaster` re-added](#4-client-side-controlmaster-re-added)
  - [5. Client-side: `fix-ssh` revived, modernized](#5-client-side-fix-ssh-revived-modernized)
  - [6. Server-side: `vscode-server-reap` timer](#6-server-side-vscode-server-reap-timer)
- [Still a manual habit, not automated](#still-a-manual-habit-not-automated)
- [What's still open](#whats-still-open)

## Incident log

Full write-ups live in their own files, one per incident, so this document stays a status reference rather than a growing log:

- [`incident-2026-07-29-vscode-reconnect-storm.md`](incident-2026-07-29-vscode-reconnect-storm.md) — first confirmed occurrence: a mid-outage VS Code client auto-update forced a version-mismatched reconnect, orphaning six `vscode-server` trees over ~24h until swap and the memory ceiling were exhausted.
- [`incident-2026-08-03-vscode-server-pileup.md`](incident-2026-08-03-vscode-server-pileup.md) — recurrence: the reaper documented in item 6 below had never actually been deployed to `dev`, so the same failure happened again; also found that a live remediation SSH session can itself drop mid-command during the sharpest moment of memory reclaim.
- [`incident-2026-08-05-vscode-agent-host-wedge.md`](incident-2026-08-05-vscode-agent-host-wedge.md) — different shape: `dev` was fully healthy, but a 2-day-old agent host wedged on handshaking *new* connections while continuing to serve an already-open window. `fix-ssh --vscode dev` fixed it; root cause of the wedge itself is unconfirmed.
- [`incident-2026-08-12-company-wifi-blocked-dev.md`](incident-2026-08-12-company-wifi-blocked-dev.md) — not a `dev`-side problem at all: a company Wi-Fi network was selectively blocking TCP to `dev`'s IP on every port (likely ASN/IP-reputation-based egress filtering), while ICMP and other hosts worked fine. Switching networks fixed it. Also surfaced an unpatched `pkill -f` self-kill bug in `fix-ssh --vscode` — see "What's still open" below.

## What's now in place

### 1. `docker.service` StartLimitBurst — stops the crash-restart loop from forming

Both incidents' actual "VM unreachable" symptom came from `docker.service` restarting repeatedly, each restart re-attempting expensive cleanup. Systemd's own crash-loop guard was never configured. Added:

**File:** `~/.config/systemd/user/docker.service.d/override.conf` on `dev`
```ini
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Restart=on-failure
RestartSec=10
```

If `docker.service` fails 3 times within 5 minutes, systemd stops retrying instead of looping — converting "CPU pegged for an hour, VM unreachable" into "`docker.service` sits stopped, VM stays reachable, `journalctl` shows exactly why." Verified live: `systemctl --user show docker.service -p StartLimitIntervalUSec,StartLimitBurst,Restart,RestartUSec` confirms the override applied (`StartLimitIntervalUSec=5min`, `StartLimitBurst=3`). This alone would likely have kept SSH alive during both prior incidents. No new failure risk — it's a stop button, not an action that touches live data.

### 2. `netdata` email alerting

**Status: deferred by choice (2026-07-29).** Command block is documented in `setup-alerting-and-memory-ceiling.md` for whenever this gets picked back up — needs `sudo` + the user's own SMTP relay credentials, neither of which should be piped through a non-interactive session. `/etc/netdata` is root-owned and no mail transport (`sendmail`/`mail`/`msmtp`/`ssmtp`) was installed on `dev` at all, so this starts from zero whenever it's revisited.

Once applied: `/etc/netdata/health.d/dev-memory.conf` adds a `system.ram` alarm (warn at 80% used, critical at 90%), and `/etc/netdata/health_alarm_notify.conf` is configured to email the result. Every incident so far (all ~7, diagnosed and undiagnosed) was discovered by the user manually failing to connect — this is meant to close that gap by surfacing a developing problem before it gets that far.

### 3. Host-level memory ceiling (`user-1000.slice`)

**Status: applied and verified (2026-07-29).** `vscode-server` runs natively as the `willard` user on `dev`, entirely outside Docker — none of the `mem_limit` work protects against a `vscode-server` pile-up (per the finding above) OOMing the host directly the same way an unbounded container used to. Verified live: `systemctl show user-1000.slice -p MemoryMax,MemoryHigh` returns `MemoryMax=15032385536` (14GB) and `MemoryHigh=13958643712` (13GB), confirming systemd actually picked up the override, not just that the file was written.

```ini
# /etc/systemd/system/user-1000.slice.d/override.conf
[Slice]
MemoryMax=14G
MemoryHigh=13G
```

Deliberately generous — rootless `docker.service` also runs under this same user slice, so this is a belt-and-suspenders outer boundary (leaving ~2GB for the system itself), not the primary control. `MemoryHigh` below `MemoryMax` gives the kernel room to reclaim gracefully before anything gets killed.

### 4. Client-side: `ControlMaster` re-added

`~/.ssh/config`'s `Host *` block on `mba15` had `ControlMaster`/`ControlPath`/`ControlPersist` completely removed during the original (pre-2026-07-24) troubleshooting, based on a theory — that multiplexed control sockets were causing "ghost hangs" — that was later disproven by the `nc` test (see `timeline.md`, `analysis.md`'s "note on secondary troubleshooting sources"). VS Code's own official troubleshooting docs recommend `ControlMaster` specifically for unstable connections, since multiplexing shares one TCP connection across a window's sessions instead of opening a fresh one per session/reconnect — directly shrinking the reconnect-storm surface described above. Re-added:

```sshconfig
Host *
    ...
    ControlMaster auto
    ControlPath ~/.ssh/cm-%h
    ControlPersist 2h
```

Verified live: a master connection to `dev` was established and confirmed via `ssh -O check dev` (`Master running (pid=...)`).

### 5. Client-side: `fix-ssh` revived, modernized

A `fix-ssh` alias existed previously (from an earlier troubleshooting session with a different AI assistant) that aggressively `pkill`ed SSH processes and deleted all `~/.ssh/cm-*` sockets — deleted on 2026-07-24 specifically because `ControlMaster` was removed at the same time (nothing left to clean up). Now that `ControlMaster` is back, stale sockets are possible again after a bad disconnect.

Rewritten as `dotfiles/scripts/fix-ssh.sh`, installed to `~/.local/bin/fix-ssh` (both directly, and via a new block in `install.sh` for future re-installs — though `install.sh` always fetches from the tagged GitHub release, so the installer path won't pick this up until the next version bump/tag/push). Unlike the original, it checks each socket's liveness (`ssh -O check`) before touching anything, rather than nuking indiscriminately:

```bash
for sock in ~/.ssh/cm-*; do
    ssh -O check -S "$sock" x 2>/dev/null && echo "Live" || { rm -f "$sock"; echo "Stale, removed"; }
done
```

Verified both branches live: a real master connection was correctly left alone; a separately-created master was killed (`kill -9`) to orphan its socket, and `fix-ssh` correctly detected and removed it.

**Extended 2026-08-03:** added a `--vscode [host]` flag (default host: `dev`) that force-kills every `vscode-server` process tree on the remote — the terminal equivalent of VS Code's own "Kill VS Code Server on Host" (command-palette-only, requires closing the connection first, has open reliability bugs). Kept behind an explicit flag rather than folded into the default behavior: unlike the socket cleanup above, it's destructive to a *live* session too, not just an orphaned one, since there's no remote-side way to tell the difference. See [`incident-2026-08-03-vscode-server-pileup.md`](incident-2026-08-03-vscode-server-pileup.md).

**Confirmed effective against a second, different symptom (2026-08-05):** not just orphaned-tree pileup — also fixes a wedged agent host that's still serving an existing connection but stuck handshaking new ones. See [`incident-2026-08-05-vscode-agent-host-wedge.md`](incident-2026-08-05-vscode-agent-host-wedge.md).

**Expect a brief load spike right after running `--vscode`, not a sign of a new problem:** force-killing a whole process tree at once (extension host, language servers, etc.) causes a short, sharp CPU/reclaim burst on `dev` — observed as a decaying 15-minute load average shortly after the 2026-08-05 fix, with the 1-minute average already back to normal by the time it was checked. Give it a few minutes to settle before treating elevated load as a separate incident.

### 6. Server-side: `vscode-server-reap` timer

**Status: written 2026-07-29, not actually deployed until confirmed otherwise.** The script and unit files were committed to this repo but never copied to `dev` or registered with systemd — a gap only discovered on 2026-08-03 when the exact failure mode recurred untouched (see [`incident-2026-08-03-vscode-server-pileup.md`](incident-2026-08-03-vscode-server-pileup.md)). The install command below was handed to the user on 2026-08-03; **do not treat this item as done until it's re-verified live on `dev`** (`systemctl list-timers vscode-server-reap.timer`).

Once actually installed: a systemd timer on `dev` runs [`reap-vscode-server.sh`](reap-vscode-server.sh) every 6 hours as the `willard` user, killing any `vscode-server` session process (matched by its real binary path — `agent host`, `command-shell`, `code-server`, `server-main.js`, `bootstrap-fork`) older than 24 hours, then sweeping any leftover stale sockets under `/tmp/user/1000/`.

This is deliberately **age-based, not connection-aware** — it does not try to determine whether a session currently has a live client attached, only how old it is. That's a conscious tradeoff, not an oversight: accurately detecting "orphaned vs. currently connected" would require checking for an established peer on each session's control socket, which is fiddly to get right and risks the exact wrong failure mode (killing a session someone is actively using) if the liveness check has any edge case. A flat 24-hour age ceiling is much harder to get wrong — no single VS Code Remote-SSH window realistically stays open for a full day without at least one reconnect in between, and worst case if it ever does, the cost is one forced reconnect (a few seconds), not lost work. It would have caught the confirmed incident, whose oldest orphaned session was already ~19 hours old.

Unit files: [`vscode-server-reap.service`](vscode-server-reap.service), [`vscode-server-reap.timer`](vscode-server-reap.timer). Installed to `/usr/local/bin/reap-vscode-server.sh` and `/etc/systemd/system/` — see `setup-alerting-and-memory-ceiling.md` for the install commands.

## Still a manual habit, not automated

**After any `Connection timed out` / `Broken pipe`, run `fix-ssh --vscode dev` before reconnecting** — it's faster than waiting for the reaper's next 6-hour cycle (once that's actually deployed), and more reliable than VS Code's own `Remote-SSH: Kill VS Code Server on Host` command, which is command-palette-only, requires closing the connection first, and has open reliability bugs. Item 6 above is a backstop for when this manual step gets skipped, not a replacement for it — and as of 2026-08-03, item 6 isn't actually live yet, so this is currently the *only* mitigation in place. Bare `fix-ssh` (no flag) only cleans up the *client's* stale control sockets, not anything left running on the VM itself.

**Avoid piling up many concurrent Remote-SSH windows against `dev` at once** — still the standing recommendation from the 2026-07-24 `analysis.md` (each window runs its own independent `vscode-server` + extension-host tree). Now with a much stronger reason to actually follow it, given the reconnect-storm mechanism documented in the incident log above.

## What's still open

- **`fix-ssh --vscode`'s remote `pkill -9 -f "\.vscode-server/"` can self-kill its own invoking shell mid-script**, since the pattern text matches the full command line ssh passes to the remote — silently truncating the script before its cleanup/completion output runs. Fix identified (bracket trick: `"[.]vscode-server/"`) but not yet applied. See [`incident-2026-08-12-company-wifi-blocked-dev.md`](incident-2026-08-12-company-wifi-blocked-dev.md).
- **Not actually deployed:** item #6 above (`vscode-server-reap` timer) — written 2026-07-29, confirmed *not* live on `dev` as of 2026-08-03. Install command is in item 6; re-verify with `systemctl list-timers vscode-server-reap.timer` after running it.
- **Deferred by choice:** item #2 above (`netdata` email alerting) — skipped for now, command block kept in `setup-alerting-and-memory-ceiling.md` for later.
- **Applied and verified:** item #3 above (host memory ceiling) — done 2026-07-29.
- **`mem_limit` still missing on `turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold`'s production paths** — see `analysis.md`'s corrective-actions checklist; unrelated to this document's scope but still an open gap on the same VM.
- **The exact 2026-07-24 initial trigger remains unconfirmed** — the connection-instability finding in the incident log above is new evidence for a *pattern*, not a retroactive confirmation of that specific incident's cause.
- **`pm.max_requests` for `wfmctrading`** was handed to a separate agent working directly in that repo (see `wfmctrading/docs/learnings/03-php-fpm-worker-lifetime-and-memory-limits.md`) — not tracked here, confirm separately.
