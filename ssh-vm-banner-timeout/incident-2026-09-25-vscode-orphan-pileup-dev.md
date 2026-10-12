# Incident: `vscode-server` Orphan Pileup on `dev`, Preceded by a Transient Port-22 False Alarm (2026-09-25)

## Overview

A manual `fix-ssh --vscode dev` failed with `Connection timed out` on port 22, which initially read as a repeat of the recurring client-network port-filtering mechanism (mobile hotspot/carrier DPI blocking SSH specifically) documented three times before in this directory. It wasn't: the client machine was on `Soriano_Home`, a normal home wifi network, not a hotspot, and a retry moments later succeeded cleanly — the timeout was a one-off transient blip, not a sustained block. `recon` then reached `dev` without issue and surfaced the real, unrelated problem: a `vscode-server` orphaned-session pileup (mechanism 2), with the oldest stale session clocking in at roughly 224 hours (over 9 days) old and swap at 80%. `fix-ssh --vscode dev` cleared it in one pass — no VM-side action, no reboot, tmux-hosted sessions untouched.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

The first signal was a pasted terminal snippet: `fix-ssh --vscode dev` returned `ssh: connect to host <dev-ip> port 22: Connection timed out` on its very first line. Given this directory's history (three prior incidents of exactly this signature turning out to be client-network port-22 filtering, most recently `incident-2026-09-04-mobile-hotspot-ssh-block-premature-hard-reset.md`), the same hypothesis was checked first rather than assumed.

A comparative reachability test was run immediately:

| Test | Result |
|---|---|
| `ping` to `dev`'s IP | 0% loss, ~216-250ms avg |
| TCP connect to `dev:443` | instant refused |
| TCP connect to `dev:80` | instant refused |
| TCP connect to `dev:22` | succeeded (`OPEN`) |

Port 22 responding cleanly on this test — the opposite of the hanging behavior in the original report — already suggested the earlier timeout hadn't persisted. Checking the active network connection confirmed it directly: `nmcli` showed the client on `Soriano_Home`, a saved home wifi network, not a mobile hotspot. None of the three prior network-filtering incidents involved a home network; this one didn't fit that pattern.

## Diagnosis

Running `recon` settled it. It reached `dev` over the existing SSH ControlMaster socket (`responded in 22ms`, ruling out both a dead connection and the resume-zombie ControlMaster bug) and pulled live metrics directly:

```
docker.service restarts : 0
RAM used                : 9047Mi / 15620Mi
swap used                : 3302Mi / 4095Mi (80%)
user-1000.slice          : 91% of MemoryHigh ceiling
load average (1m)        : 0.17
open vscode windows      : 1 (extensionHost count)
oldest vscode session    : ~224h old
```

`recon`'s own signature logic flagged this correctly: an oldest session nearly 10 days old, far past any real work session, with the window count not accounting for the memory pressure — the orphaned-session pileup mechanism (mechanism 2) already well documented in this directory (first seen `incident-2026-07-29-vscode-reconnect-storm.md`, most recently `incident-2026-08-21-wifi-switch-vscode-pileup.md`), not a new failure mode.

## Fix

`fix-ssh --vscode dev` was re-run and completed (`Killing vscode-server processes on dev... Done.`). A follow-up `recon` pass confirmed recovery:

```
RAM used                : 6379Mi / 15620Mi
swap used                : 3300Mi / 4095Mi (80%)
user-1000.slice          : 71% of MemoryHigh ceiling
load average (1m)        : 0.10
open vscode windows      : 0 (extensionHost count)
oldest vscode session    : ~0h old
```

RAM dropped by ~2.7GB and the pileup was gone (0 stale sessions, 0h oldest). Swap still read 80% used post-fix — expected, since Linux doesn't proactively reclaim swap once pages are paged out just because RAM pressure eased; not itself a sign of a lingering problem at this load level (0.10 load average). Docker was never implicated (`0` restarts throughout). No reboot, no VM-side action, and the tmux-hosted agent sessions on `dev` were never at risk.

## Open items

- **The initial port-22 timeout was never explained.** It didn't repeat on retry and the network (`Soriano_Home`) doesn't match the mobile-hotspot/carrier-DPI profile of the three prior filtering incidents, so it's logged as an unexplained transient rather than a confirmed instance of mechanism 5. If a similar one-off timeout recurs on a normal wifi network (not a hotspot), it's worth treating as a possible sixth mechanism rather than folding it into mechanism 5 by default.
- Same day, later in the session, a second incident occurred (`incident-2026-09-29-mobile-hotspot-blocks-pileup-fix.md` — despite the filename date, see that doc's own dating) involving the *same* mechanism-2 pileup signature recurring within days of this fix, this time compounded by an actual mechanism-5 network block. Worth watching whether the pileup's recurrence interval is shortening.
