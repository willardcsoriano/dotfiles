# Wifi Switch Triggers a Fast vscode-server Pileup, Undetected by the 24h Reaper

## Overview

On 2026-08-21, switching wifi networks on `mba15` while 3 VS Code Remote-SSH windows were open to `dev` triggered a `vscode-server` pileup that reached crisis level (swap fully exhausted, load average ~95 on an 8-core box) in under an hour — well inside the 24-hour age threshold `reap-vscode-server.sh` (see `self-healing.md` item 6) checks for, so the existing reaper never had a chance to catch it. The session was recovered manually with `fix-ssh --vscode dev`, which dropped memory usage from crisis level back to near-idle almost immediately, confirming `vscode-server` processes — not Docker, which was already stopped for an unrelated reason at the time — were the entire cause. This incident is the same underlying pileup mechanism as 07-29/08-03/08-17, but the first one *not* caused by a slow multi-hour/multi-day accumulation, closing the specific gap the age-based reaper was never designed to catch (see item 6's own note: "deliberately age-based, not connection-aware").

## Table of Contents

- [Overview](#overview)
- [Timeline](#timeline)
- [Root cause](#root-cause)
- [Fix](#fix)
- [A ControlMaster red herring, corrected](#a-controlmaster-red-herring-corrected)

## Timeline

- Wifi network switched on `mba15` while 3 VS Code Remote-SSH windows were open to `dev`, each running a full extension host + language server stack (notably `salesforce.apex-language-server-extension`, a separate memory-heavy TypeScript rewrite of the Apex LSP — see below).
- Within roughly an hour, `recon`/`check-dev` reported `PARTIAL/HUNG` — basic commands (`free`, `systemctl show`) were timing out under real load rather than returning quickly.
- Direct investigation found: swap **100% full** (4.0GB/4.0GB, 0 free), 1-minute load average **94.77** on an 8-core machine, `free -h` itself taking 6.5s wall-clock despite near-zero actual CPU time (classic thrashing signature — mostly waiting, not working).
- `fix-ssh --vscode dev` was run. Memory dropped from 13GB+ used to 2GB used almost immediately; swap began draining. All 4 `tmux` sessions (`sbintern-agent1`, `sbintern-agent2`, `thesis-1`, `wfmc-1`) and the agents running inside them survived untouched, confirming the 2026-08-17 decision to run agent CLI sessions in `tmux` (item 7) did its job.

## Root cause

Each VS Code Remote-SSH window maintains its own independent `vscode-server` process tree on `dev`, regardless of whether the client-side SSH connection is shared via `ControlMaster` (confirmed against this repo's own existing "avoid piling up many concurrent windows" note under "Still a manual habit, not automated" — that guidance already anticipated this). A wifi network switch is a full local-interface-level event: it doesn't glitch one connection while others survive, it takes down everything on that interface at once, prompting VS Code's own reconnect logic to fire for all 3 windows close together. VS Code Remote-SSH has a long-standing, still-open upstream limitation where reconnects don't reliably clean up the prior server-side process tree first (confirmed via [microsoft/vscode-remote-release#262](https://github.com/microsoft/vscode-remote-release/issues/262), which describes shared dev servers accumulating 100+ orphaned processes from the same pattern) — this is not something fixable from the client or server config alone; it's a defect in the tool's own reconnect handling.

Separately, though not the root cause of *this* incident's speed, `salesforce.apex-language-server-extension` (a distinct, early-stage TypeScript rewrite of the Apex language server, separate from the mature Java-based one in `salesforcedx-vscode-apex`) was found using 1.36-2.36GB per window — its own upstream repo (`forcedotcom/apex-language-support`) states "experimental - DO NOT USE" in its README. Updated to its latest version, concurrency capped (`apex.experimental.workers.poolSize: 1`), and ultimately uninstalled entirely once confirmed to have no `extensionDependencies` relationship to anything else in the Salesforce extension pack. This made each window's baseline footprint much smaller, but doesn't address the pileup mechanism itself — a pileup of even lean trees still adds up across enough orphaned reconnects.

## Fix

`reap-vscode-orphans.sh` (new, alongside the existing `reap-vscode-server.sh`), installed via [`vscode-server-reap-orphans.service`](vscode-server-reap-orphans.service) + [`vscode-server-reap-orphans.timer`](vscode-server-reap-orphans.timer), running every 2 minutes. Unlike the 24h age-based reaper, this one is connection-aware without the "fiddly to get right" risk item 6 originally flagged for that approach: it only kills a `vscode-server` tree whose top-level launcher (the `command-shell`/`agent host` process sshd spawns directly per connection) has been reparented to PID 1 — which is structurally only true once that connection's actual SSH session has already died. A tree still attached to a live session always has a real `sshd`-descended process as its parent, so this cannot misidentify a live session as orphaned. Verified live against `dev`: found and correctly ignored a freshly-reconnected window's tree (confirmed its parent PID was a live shell, not `1`).

This closes the specific gap this incident exposed — a fast pileup (minutes to an hour) from a single trigger event, which the 24h/6h-cadence reaper was never designed to catch — while leaving that reaper in place as a backstop for the slower accumulation pattern it does handle well (07-29/08-03/08-17's multi-hour/multi-day cases).

## A ControlMaster red herring, corrected

Mid-investigation, disabling `ControlMaster` for `dev` specifically (so each window gets an independent client-side connection) was proposed and briefly applied to `~/.ssh/config.local`, on the theory that a shared connection was amplifying the blast radius of the wifi switch. This was reverted before being deployed anywhere else, for two reasons surfaced by actually reading this document first: `ControlMaster` was deliberately *re-added* on 2026-07-29 (item 4) after being removed on a now-disproven "ghost hangs" theory, and — more directly — this document's own existing "avoid piling up many concurrent windows" note already establishes that each window's server-side tree is independent of client-side connection sharing regardless. Since a full interface-level wifi switch hits every connection at once whether or not they're multiplexed, splitting them apart would not have changed how many windows disconnected simultaneously tonight. Recorded here so the same proposal isn't re-litigated from scratch next time without this context.
