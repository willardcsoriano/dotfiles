# Incident: VS Code Remote-SSH Broken on `dev` Again — Reaper Confirmed Never Actually Deployed (2026-08-17)

## Overview

On 2026-08-17, closing the laptop lid and reopening it on a different network (a phone hotspot, after leaving home) left VS Code Remote-SSH against `dev` unable to connect. Two distinct problems stacked on top of each other, and it's worth keeping them separate: a client-side SSH ControlMaster zombie (documented separately in `dotfiles/notes/ssh-controlmaster-zombie-after-resume.md`) that made even a plain `ssh dev` hang, and — once that was cleared — a second, server-side problem underneath it. `dev` itself was in the exact memory-exhaustion state the 2026-07-29 and 2026-08-03 incidents already diagnosed: swap fully exhausted, the `user-1000.slice` memory ceiling pinned at its `MemoryHigh` throttle line, load average over 120. `docker.service` was confirmed stable throughout (0 restarts) — this was not a recurrence of the 2026-07-24/2026-07-28 Docker crash-loop mechanism, despite looking similar from the outside ("VM unreachable"). The actual root cause was the same one identified twice before and never actually fixed: `vscode-server-reap.timer`, meant to age out orphaned sessions every 6 hours, had never been deployed to `dev` — confirmed again via `systemctl list-timers` returning zero results, the third time this exact gap has been found. `fix-ssh --vscode dev` recovered the VM without any reboot (three attempts — the first two were themselves interrupted mid-kill by the memory pressure, consistent with the 2026-08-03 precedent). The reaper was then actually deployed and verified live this time, and a new `make verify-hardening` target was added so "documented as applied" can't silently diverge from "actually applied" a fourth time without being caught immediately.

## Table of Contents

- [Overview](#overview)
- [Timeline](#timeline)
- [Diagnosis: ruling out the Docker mechanism, confirming the vscode-server one](#diagnosis-ruling-out-the-docker-mechanism-confirming-the-vscode-server-one)
- [Fix](#fix)
- [The real root cause: two false "applied" claims](#the-real-root-cause-two-false-applied-claims)
- [Hardening added](#hardening-added)

## Timeline

All times approximate, mba15 local:

1. Laptop lid closed at home (on home wifi), later reopened elsewhere and joined a phone hotspot instead.
2. VS Code Remote-SSH's own reconnect attempts, plus the user's own terminal `ssh dev`, both hung — traced to a stale local `ssh` ControlMaster whose underlying TCP connection had died silently during suspend (`ServerAliveInterval` can't fire while the client process itself is frozen). See `dotfiles/notes/ssh-controlmaster-zombie-after-resume.md` for that half; a new `ssh-control-reset` systemd sleep hook was added to `dotfiles` to prevent recurrence.
3. Once the zombie master was cleared, a *fresh* `ssh dev` succeeded, but VS Code's Remote-SSH log showed a different, new stall: the remote CLI spawned successfully (`Spawned remote CLI: ...`) and then sat at `Waiting for server log...` indefinitely — this was the first sign of a second, independent problem.
4. Live checks on `dev` confirmed severe resource exhaustion: `df`/`free -h`/`ps aux` all stalled or timed out over SSH; `hcloud server metrics` (via `make check`) showed CPU pegged and sustained.
5. User asked whether this was the same Docker OOM mechanism as before; live verification (below) confirmed it was not — the `vscode-server` pileup mechanism instead.
6. `fix-ssh --vscode dev` run three times: attempts 1 and 2 each printed "Killing vscode-server processes on dev..." then hit the 30s local timeout with no completion message (SSH session dropped mid-kill, same as the 2026-08-03 precedent); memory partially recovered between attempts (13Gi→11Gi used, swap 4.0Gi→2.6Gi used) confirming each attempt did real work despite the dropped connection. Attempt 3 completed cleanly (`Done.`, rc 0).
7. Post-fix: 895Mi RAM used (from 13Gi), 185Mi swap used (from a full 4.0Gi), zero remaining `vscode-server` processes, `docker.service` still active/stable throughout. No VM reboot or `make recover` needed at any point.
8. `systemctl list-timers vscode-server-reap.timer` confirmed, for the third time since it was first "written" on 2026-07-29, that it had never actually been installed on `dev`.
9. Reaper files copied to `dev:/tmp/` (no `sudo` needed for that half); user ran the `sudo`-gated move-into-place + `systemctl enable --now` commands themselves in their own terminal (handed over rather than run non-interactively, since `dev` requires an interactive `sudo` password and secrets/passwords are never piped through this session).
10. Verified live: `NEXT = Mon 2026-08-17 19:59:38 UTC`, `LEFT = 5h 58min`, matching the timer's `OnUnitActiveSec=6h` exactly, and `LAST` showing it had already fired once on enable (`Persistent=true` + `OnBootSec=15min` triggering an immediate catch-up run). Genuinely live this time.

## Diagnosis: ruling out the Docker mechanism, confirming the vscode-server one

| Signal | Docker crash-loop (07-24, 07-28) | vscode-server pileup (07-29, 08-03, **08-17**) | What was observed today |
|---|---|---|---|
| `docker.service` restarts | Repeated (crash-restart loop) or one OOM-kill of the daemon itself | Stable, no restarts | `systemctl --user show docker.service -p NRestarts` → `NRestarts=0` — **matches pileup, not Docker** |
| Swap | Not the driver (07-24 had zero swap at the time; 07-28 had swap but wasn't the bottleneck) | Fully exhausted | `4.0Gi used / 252Ki free` — **matches pileup** |
| `user-1000.slice` memory | Not tracked at this granularity in the Docker incidents | Pinned at/near `MemoryHigh` | `MemoryCurrent=13966409728` vs `MemoryHigh=13958643712` — **matches pileup exactly**, same shape as 07-29's `MemoryCurrent=13979181056` against the same `MemoryHigh` |
| CPU signature | Sustained 600-800%, disk reads ~1-1.3GB/s | Swap-thrashing, high `sy` (kernel) time | Load average 124/123/104 — consistent with severe thrashing, not the Docker containerd/runc teardown loop's disk-read pattern specifically (disk wasn't separately isolated this time, but the other three signals were unambiguous) |
| Fix that worked | VM reboot/reset (`make recover`) | `fix-ssh --vscode dev`, no reboot | **`fix-ssh --vscode dev` alone fully recovered the VM** — would not have worked on the Docker mechanism, which required an actual reboot both prior times |

## Fix

Identical to the proven fix from 2026-08-03 and 2026-08-05: `fix-ssh --vscode dev` (force-kills every `vscode-server` process tree on the host via `pkill -9 -f "[.]vscode-server/"`, see `self-healing.md` item 5). Needed three attempts this time specifically because the VM was under heavier pressure than either prior occurrence (100+ load average vs. 98.9% single-core kernel time in 08-03) — the first two invocations' SSH sessions were themselves dropped mid-kill by the sharp reclaim burst, exactly the "expected, not a failure" pattern `incident-2026-08-03-vscode-server-pileup.md` already documented. Checking `free -h` after each attempt (rather than trusting the dropped session's exit code) confirmed forward progress each time.

## The real root cause: two false "applied" claims

The proximate cause (orphaned `vscode-server` sessions after a bad disconnect) was diagnosed and supposedly fixed on 2026-07-29. It was found still-undeployed on 2026-08-03. It was found still-undeployed again today, 2026-08-17 — two weeks after the second "fix." The pattern both times: the reaper's install commands were written into `setup-alerting-and-memory-ceiling.md` and handed to the user as a copy-paste block, and the status line was then marked "applied" based on the handoff happening, not on any live check of `dev` afterward. Both prior write-ups quietly assumed intent equaled completion.

This is a process gap, not a technical one — the reaper script and unit files themselves were correct both times; they just never got copy-pasted through to completion on the live box. Handing over a sudo-gated command block and moving on is exactly the shape of task that silently doesn't happen.

## Hardening added

1. **`make verify-hardening`** (new `Makefile` target, this repo): a read-only check that queries `dev` directly for all three of `self-healing.md`'s live mitigations — the `docker.service` crash-loop guard, the `user-1000.slice` memory ceiling, and the `vscode-server-reap.timer` schedule — and prints an explicit list of red flags (`infinity`, `0 timers listed`, `disabled`) to watch for. Run this instead of trusting any status line in the docs; it would have caught both prior false "applied" claims immediately. Verified working: all three mitigations confirmed live as of this incident.
2. **`etc/systemd/system-sleep/ssh-control-reset`** (`dotfiles` repo, separate but related): prevents the client-side half of today's incident (the SSH ControlMaster zombie) from recurring after future suspend/resume + network-change cycles. See `dotfiles/notes/ssh-controlmaster-zombie-after-resume.md`.
3. **`self-healing.md` item 6's status corrected** to reflect actual verification history (written 07-29 → found undeployed 08-03 → found undeployed again 08-17 → actually deployed and verified 08-17), rather than the single, since-disproven "applied" claim it carried before.

Not yet addressed, still open from prior incidents: `netdata` email alerting (deferred by choice, needs SMTP credentials), and `mem_limit` on the `turtley`/`bodego`/`erpnext-scaffold`/`odoo-scaffold` Docker stacks (unrelated to this incident's mechanism, but still a standing gap on the same VM per `rca.md`'s corrective-actions checklist).
