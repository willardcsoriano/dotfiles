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
  - [7. Client-side: agent CLI sessions moved into `tmux`](#7-client-side-agent-cli-sessions-moved-into-tmux)
  - [8. Server-side: `vscode-server-reap-orphans` timer (fast, connection-aware)](#8-server-side-vscode-server-reap-orphans-timer-fast-connection-aware)
- [Still a manual habit, not automated](#still-a-manual-habit-not-automated)
- [What's still open](#whats-still-open)

## Incident log

Full write-ups live in their own files, one per incident, so this document stays a status reference rather than a growing log:

- [`incident-2026-07-29-vscode-reconnect-storm.md`](incident-2026-07-29-vscode-reconnect-storm.md) — first confirmed occurrence: a mid-outage VS Code client auto-update forced a version-mismatched reconnect, orphaning six `vscode-server` trees over ~24h until swap and the memory ceiling were exhausted.
- [`incident-2026-08-03-vscode-server-pileup.md`](incident-2026-08-03-vscode-server-pileup.md) — recurrence: the reaper documented in item 6 below had never actually been deployed to `dev`, so the same failure happened again; also found that a live remediation SSH session can itself drop mid-command during the sharpest moment of memory reclaim.
- [`incident-2026-08-05-vscode-agent-host-wedge.md`](incident-2026-08-05-vscode-agent-host-wedge.md) — different shape: `dev` was fully healthy, but a 2-day-old agent host wedged on handshaking *new* connections while continuing to serve an already-open window. `fix-ssh --vscode dev` fixed it; root cause of the wedge itself is unconfirmed.
- [`incident-2026-08-12-company-wifi-blocked-dev.md`](incident-2026-08-12-company-wifi-blocked-dev.md) — not a `dev`-side problem at all: a company Wi-Fi network was selectively blocking TCP to `dev`'s IP on every port (likely ASN/IP-reputation-based egress filtering), while ICMP and other hosts worked fine. Switching networks fixed it. Also surfaced an unpatched `pkill -f` self-kill bug in `fix-ssh --vscode` — see "What's still open" below.
- [`incident-2026-08-12-mobile-sim-connectivity-struggle.md`](incident-2026-08-12-mobile-sim-connectivity-struggle.md) — same day, different network: a mobile SIM showed the same destination-specific pattern (heavy loss to `dev` specifically, 0% loss to comparison hosts). Switching carriers fixed it. Also confirmed not a compromise, ruled out the local Wi-Fi hop, and found Hetzner's browser-based console (`hcloud server request-console`) as an SSH-independent emergency fallback.
- [`incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md`](incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md) — third occurrence of the same pileup mechanism as 07-29/08-03; live-verified this was the `vscode-server` pileup and not the Docker crash-loop mechanism (`docker.service` had 0 restarts throughout). `fix-ssh --vscode dev` recovered it without any VM reboot, needing 3 attempts because the VM was under heavier pressure than prior occurrences. Root cause: the reaper timer below was, again, not actually deployed — the third time this exact gap has been found. Added `make verify-hardening` so this can't silently recur a fourth time.
- [`incident-2026-08-21-wifi-switch-vscode-pileup.md`](incident-2026-08-21-wifi-switch-vscode-pileup.md) — fourth occurrence, but a new trigger shape: a wifi network switch (not a slow multi-hour/day accumulation) took swap to 100% full and load average to ~95 in under an hour — inside the 24h reaper's detection window entirely. `fix-ssh --vscode dev` recovered it; `tmux`-hosted agent sessions survived untouched, confirming item 7 still works. Closed the gap with a second, faster, connection-aware reaper (item 8).

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

**Fixed 2026-08-12: self-kill bug in the remote kill command.** `pkill -9 -f "\.vscode-server/"` matched not just its intended targets but the full command line of its own invoking shell (the whole 3-line remote script is passed to `ssh` as one argument, and that argument's text contains the same pattern it's searching for) — since the invoking shell's PID is always the newest/highest of the matched set, `pkill`'s numeric-order kill sequence took out the real targets first and its own parent last, silently truncating the script before `find`/`echo "Done."` ever ran. Fixed by switching the pattern to `"[.]vscode-server/"` (same bracket trick used to self-exclude `ps`/`grep` from their own output) — verified live with `pgrep` (non-destructive) that the parent shell no longer matches while every real target still does. See [`incident-2026-08-12-company-wifi-blocked-dev.md`](incident-2026-08-12-company-wifi-blocked-dev.md) for the full diagnosis.

**Expect a brief load spike right after running `--vscode`, not a sign of a new problem:** force-killing a whole process tree at once (extension host, language servers, etc.) causes a short, sharp CPU/reclaim burst on `dev` — observed as a decaying 15-minute load average shortly after the 2026-08-05 fix, with the 1-minute average already back to normal by the time it was checked. Give it a few minutes to settle before treating elevated load as a separate incident.

### 6. Server-side: `vscode-server-reap` timer

**Status: actually deployed and verified live 2026-08-17 — treat any earlier "applied" claim below as historical, not current.** Written 2026-07-29, found *not* actually deployed on 2026-08-03 (script/units existed only in this repo, never copied to `dev`), found *still* not deployed on 2026-08-17 despite the 08-03 write-up's install command having been handed over again — see [`incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md`](incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md). Finally confirmed live on 2026-08-17: `systemctl list-timers vscode-server-reap.timer` shows `NEXT`/`LEFT` populated (not blank), scheduled ~6h out, matching `OnUnitActiveSec=6h`. **Going forward, verify with `make verify-hardening` (this repo's `Makefile`) rather than trusting this status line** — it queries `dev` directly instead of relying on a doc being kept in sync with reality, which failed twice in a row here.

Once actually installed: a systemd timer on `dev` runs [`reap-vscode-server.sh`](reap-vscode-server.sh) every 6 hours as the `willard` user, killing any `vscode-server` session process (matched by its real binary path — `agent host`, `command-shell`, `code-server`, `server-main.js`, `bootstrap-fork`) older than 24 hours, then sweeping any leftover stale sockets under `/tmp/user/1000/`.

This is deliberately **age-based, not connection-aware** — it does not try to determine whether a session currently has a live client attached, only how old it is. That's a conscious tradeoff, not an oversight: accurately detecting "orphaned vs. currently connected" would require checking for an established peer on each session's control socket, which is fiddly to get right and risks the exact wrong failure mode (killing a session someone is actively using) if the liveness check has any edge case. A flat 24-hour age ceiling is much harder to get wrong — no single VS Code Remote-SSH window realistically stays open for a full day without at least one reconnect in between, and worst case if it ever does, the cost is one forced reconnect (a few seconds), not lost work. It would have caught the confirmed incident, whose oldest orphaned session was already ~19 hours old.

Unit files: [`vscode-server-reap.service`](vscode-server-reap.service), [`vscode-server-reap.timer`](vscode-server-reap.timer). Installed to `/usr/local/bin/reap-vscode-server.sh` and `/etc/systemd/system/` — see `setup-alerting-and-memory-ceiling.md` for the install commands.

### 7. Client-side: agent CLI sessions moved into `tmux`

**Added 2026-08-17.** `fix-ssh --vscode dev` is destructive to every session in the `vscode-server` process tree, not just orphaned ones — including any long-running agent CLI (e.g. Claude Code) started directly in a VS Code integrated terminal, since its shell is a child of that same tree. That made the tool something to reach for reluctantly, which defeats the point of having a fast, reflexive fix for pileup.

Fix: run agent CLI sessions inside `tmux` on `dev` instead of directly in a VS Code terminal (`tmux new -s <name>`, reattach later with `tmux attach -t <name>`). `tmux`'s server is its own independent process, entirely outside the `vscode-server` tree — `fix-ssh --vscode dev` cannot reach it. This makes the tool safe to run freely and immediately after any bad disconnect, rather than something to hesitate over. Tradeoffs worth knowing: `tmux` sessions don't self-clean any more than the old `vscode-server` trees did (same shape of risk, much smaller blast radius — a bare shell + one process, not a full extension host + JVM), it doesn't protect against the VM itself running out of memory for unrelated reasons, and it doesn't survive an actual VM reboot (only SSH/`vscode-server` churn).

Config: [`tmux.conf`](tmux.conf), deployed to `~/.tmux.conf` on `dev` (manually — `scp` + `tmux source-file ~/.tmux.conf`, since `dev` isn't reachable via `dotfiles/install.sh`) and on mba15 (via `install.sh`, which also installs `tmux` itself if missing). Fixes two related, non-obvious problems, both confirmed via `tmux list-keys`/`man tmux` on the live 3.5a install rather than assumed, since these bindings have shifted across `tmux` versions:

- **Scroll landing in the foreground app instead of tmux's history.** `tmux`'s default `WheelUpPane` binding defers to whatever app is running if it's requested its own mouse tracking (Claude Code's CLI does). Forced to always enter `tmux` copy-mode regardless of what the foreground app wants.
- **Click-drag copy not reaching the real clipboard.** `dev` is headless — no X11, no `xclip` — so there is no local clipboard on the machine `tmux` runs on at all. `set-clipboard` makes `tmux` relay via the xterm OSC 52 escape sequence, which the *client* terminal (wherever you're actually sitting) intercepts and writes to the real system clipboard, transparently over SSH. But this only fires for tmux's own native copy commands, not `copy-pipe`/`copy-pipe-and-cancel` (which pipe to an external command instead) — and `tmux`'s default mouse-drag-release binding uses `copy-pipe-and-cancel` with no command specified, an effective no-op on a host with no `xclip`. Rebound to the native `copy-selection-and-cancel` so the relay actually fires.

Both verified working live after deploying.

### 8. Server-side: `vscode-server-reap-orphans` timer (fast, connection-aware)

**Added 2026-08-22**, after [`incident-2026-08-21-wifi-switch-vscode-pileup.md`](incident-2026-08-21-wifi-switch-vscode-pileup.md) exposed a gap item 6 was never designed to cover: a wifi-switch-triggered pileup reached crisis level (load average ~95, swap 100% full) in under an hour, well inside the 24h age threshold that reaper checks for.

Item 6's own writeup explicitly chose age over connection-awareness because "accurately detecting orphaned vs. currently connected... is fiddly to get right and risks the exact wrong failure mode." This reaper avoids that risk with a narrower, structurally-safe signal instead of a general liveness check: it only kills a `vscode-server` tree whose top-level launcher (the `command-shell`/`agent host` process sshd spawns directly per connection) has `PPID=1`. A tree still attached to a live SSH session always has a real, live process as its parent — `PPID=1` can only happen once that session has actually died and the kernel has reparented its orphaned children. There's no ambiguous case to get wrong, unlike trying to infer liveness from a control socket.

```bash
kill_tree() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -9 "$pid" 2>/dev/null || true
}

ps -eo pid,ppid,args --no-headers \
  | grep -E '\.vscode-server/code-[0-9a-f]+ (agent host|command-shell)' \
  | while read -r pid ppid _rest; do
      [ "$ppid" -eq 1 ] && kill_tree "$pid"
    done
```

Runs every 2 minutes via [`vscode-server-reap-orphans.timer`](vscode-server-reap-orphans.timer) (`OnBootSec=1min`, `OnUnitActiveSec=2min`) → [`vscode-server-reap-orphans.service`](vscode-server-reap-orphans.service), installed alongside item 6's units rather than replacing them — the two cover different accumulation speeds (this one: single-event pileups in minutes; item 6: slow multi-hour/day accumulation from causes like a version-mismatched reconnect, per item 6's own note). Script: [`reap-vscode-orphans.sh`](reap-vscode-orphans.sh).

Verified live against `dev`: correctly found and *ignored* a freshly-reconnected window's tree (confirmed its `PPID` traced to a live shell process, not `1`).

**Also investigated during this incident, but not the fix:** `salesforce.apex-language-server-extension` (a separate, early-stage TypeScript rewrite of the Apex language server) was found using 1.36-2.36GB per window — its upstream repo states "experimental - DO NOT USE." Updated, concurrency-capped, then uninstalled entirely (confirmed via `extensionDependencies` check that nothing else in the Salesforce pack requires it). This reduced each window's baseline footprint but is unrelated to the reap-orphans fix above — a pileup of even lean trees still compounds. Also considered and **reverted**: disabling `ControlMaster` for `dev` to reduce reconnect blast radius — see the incident file's "ControlMaster red herring" section for why this doesn't actually help and would have undone item 4's deliberate decision.

## Still a manual habit, not automated

**After any `Connection timed out` / `Broken pipe`, run `fix-ssh --vscode dev` before reconnecting** — it's faster than waiting for the reaper's next 6-hour cycle (once that's actually deployed), and more reliable than VS Code's own `Remote-SSH: Kill VS Code Server on Host` command, which is command-palette-only, requires closing the connection first, and has open reliability bugs. Item 6 above is a backstop for when this manual step gets skipped, not a replacement for it — and as of 2026-08-03, item 6 isn't actually live yet, so this is currently the *only* mitigation in place. Bare `fix-ssh` (no flag) only cleans up the *client's* stale control sockets, not anything left running on the VM itself.

**Avoid piling up many concurrent Remote-SSH windows against `dev` at once** — still the standing recommendation from the 2026-07-24 `analysis.md` (each window runs its own independent `vscode-server` + extension-host tree). Now with a much stronger reason to actually follow it, given the reconnect-storm mechanism documented in the incident log above.

## What's still open

- **Deferred by choice:** item #2 above (`netdata` email alerting) — skipped for now, command block kept in `setup-alerting-and-memory-ceiling.md` for later. Worth reconsidering: all 3 vscode-server pileup occurrences (07-29, 08-03, 08-17) and both Docker occurrences were discovered only by the user manually failing to connect — zero automated detection exists on this VM as of 2026-08-17.
- **Applied and verified:** item #3 above (host memory ceiling) — done 2026-07-29.
- **`mem_limit` still missing on `turtley`, `bodego`, `erpnext-scaffold`, `odoo-scaffold`'s production paths** — see `analysis.md`'s corrective-actions checklist; unrelated to this document's scope but still an open gap on the same VM.
- **The exact 2026-07-24 initial trigger remains unconfirmed** — the connection-instability finding in the incident log above is new evidence for a *pattern*, not a retroactive confirmation of that specific incident's cause.
- **`pm.max_requests` for `wfmctrading`** was handed to a separate agent working directly in that repo (see `wfmctrading/docs/learnings/03-php-fpm-worker-lifetime-and-memory-limits.md`) — not tracked here, confirm separately.
