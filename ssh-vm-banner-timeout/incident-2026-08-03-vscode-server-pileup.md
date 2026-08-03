# Incident: Orphaned `vscode-server` Sessions Recur on `dev` — Reaper Was Never Deployed (2026-08-03)

## Overview

On 2026-08-03, VS Code Remote-SSH against `dev` stopped reconnecting after a network interruption — the same failure mode [`incident-2026-07-29-vscode-reconnect-storm.md`](incident-2026-07-29-vscode-reconnect-storm.md) was supposed to have fixed via a scheduled reaper. It hadn't: the reaper script and systemd units existed only as untracked files in the local `dotfiles` repo, never actually copied to `dev` or registered with systemd, so four orphaned `vscode-server` session trees from earlier that day were free to accumulate and exhaust RAM and swap (98.9% of CPU stuck in kernel time from thrashing). Plain terminal SSH survived light commands throughout, but a live remediation session running a mass process kill was itself dropped mid-command — a new finding, since the 2026-07-29 incident had assumed terminal SSH was unconditionally immune. Killing the orphaned trees by hand recovered memory within seconds; deploying the reaper for real remains the actual outstanding fix.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [New finding: terminal SSH is not unconditionally reliable during remediation either](#new-finding-terminal-ssh-is-not-unconditionally-reliable-during-remediation-either)
- [Immediate fix](#immediate-fix)
- [Lasting fix, still not actually done](#lasting-fix-still-not-actually-done)

## What happened

VS Code Remote-SSH against `dev` stopped reconnecting after a network interruption. Plain `ssh dev` worked, but diagnostic commands run over that connection were themselves sluggish — some needed 10-20s just to return, which turned out to be a signal, not just an inconvenience.

## Diagnosis

- `free -h` showed 13Gi/15Gi RAM and the full 4.0Gi swap in use; `top` showed 98.9% of CPU in kernel time (`sy`) — swap thrashing, not a Docker crash-loop (`docker.service` was confirmed stable, running continuously since 2026-07-28 with no restarts).
- `ps aux --sort=-%mem` found **four** orphaned `vscode-server` session trees, all started earlier the same day (07:10, 07:37, 09:04, 09:21) — each carrying its own extension host, a Salesforce Apex Language Server JVM, and a `salesforce-mcp` Node process. Together they accounted for roughly 11 of the 13GB in use.
- Unlike the 2026-07-29 incident, no check was made of whether the four trees spanned different server commit hashes before killing them, so **this occurrence does not confirm the "client auto-updated mid-reconnect" mechanism** — only that the same end state (accumulated orphaned trees exhausting memory) happened again. Repeated bad reconnects with no version change is an equally plausible, unruled-out explanation this time.
- **The actual root cause of the recurrence:** the `vscode-server-reap` timer (see `self-healing.md`, item 6) was documented as "applied 2026-07-29," but that status was never true on the live system — the script and unit files existed only as untracked files in the local `dotfiles` repo on `mba15`, never copied to `dev`, never registered with systemd. Checking `dev` directly on 2026-08-03 confirmed `/usr/local/bin/reap-vscode-server.sh` didn't exist and no `vscode-server-reap.timer` was registered. The documented mitigation was not actually in place — that's the more important root cause of this repeat than any client-side trigger.

## New finding: terminal SSH is not unconditionally reliable during remediation either

The 2026-07-29 incident's own write-up states plain `ssh` "kept working the whole time." That held for lightweight commands (`whoami`, `free -h`) even under 98.9% sys-time thrashing here — but a *live* SSH session running `pkill -9` against all four ~1-2GB trees at once was itself dropped mid-command (connection closed, exit 255) partway through.

Likely explanation: force-killing that much resident/swapped memory simultaneously triggers a sharp, concentrated burst of page-table teardown and swap-slot reclaim — sharper than the steady-state thrashing a short read-only command can usually dodge between scheduler gaps. A fresh, non-multiplexed reconnect (`ssh -o ControlPath=none`) immediately afterward succeeded normally, and memory had already fully recovered by then.

**Practical takeaway: if a remediation session drops mid-kill, that's expected under this failure mode, not a sign the fix failed — reconnect and check `free -h` rather than treating the drop itself as a new problem.**

## Immediate fix

Same as 2026-07-29 — killed all four orphaned trees (`pkill -9 -f '\.vscode-server/'`) and swept `/tmp/user/1000/code-*` sockets. Memory recovered fully within seconds of the kill actually completing (confirmed via a fresh connection): 13Gi free, swap down to ~200Mi from a full 4Gi.

Now wrapped in a single reusable command instead of ad hoc one-offs — `fix-ssh --vscode [host]` (see `self-healing.md`, item 5), the terminal equivalent of VS Code's own "Kill VS Code Server on Host." Kept as a *separate flag* rather than folded into `fix-ssh`'s default behavior specifically because it's destructive to any live session too, not just orphaned ones — the default `fix-ssh` (no flag) remains safe to run reflexively; `--vscode` is not.

## Lasting fix, still not actually done

Deploy the reaper for real this time. See `self-healing.md`, item 6, for the exact install command — handed to the user as a copy-paste block on 2026-08-03, not yet confirmed run.
