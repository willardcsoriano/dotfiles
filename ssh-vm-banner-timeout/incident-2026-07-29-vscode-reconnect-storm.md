# Incident: VS Code Remote-SSH Reconnect Storm Exhausts Memory on `dev` (2026-07-29)

## Overview

On 2026-07-29, hours after a related investigation first floated the theory, a VS Code Remote-SSH reconnect storm actually happened on `dev`: a home wifi drop mid-session coincided with the local VS Code client auto-updating itself, forcing three separate Remote-SSH windows to each abandon their existing server-side session and boot a brand-new one instead of reattaching — Remote-SSH can only reattach to a server whose version exactly matches the current client. The orphaned trees left behind (six in total, spanning almost 24 hours of accumulation) each carried a full extension host plus a per-session Salesforce Apex Language Server JVM, and together exhausted swap and pinned the host memory ceiling, blocking any new `vscode-server` from starting. Plain `ssh` kept working throughout — a bare shell needs almost nothing by comparison, so only VS Code's own reconnect was affected. This document also covers the earlier client-side investigation (prompted by a separate 2026-07-28 incident) that first predicted this mechanism from `netdata`'s RAM history and `sshd` logs.

## Table of Contents

- [Overview](#overview)
- [What led here: a plausible contributing trigger, client-side](#what-led-here-a-plausible-contributing-trigger-client-side)
- [Confirmed occurrence: the predicted reconnect storm actually happened](#confirmed-occurrence-the-predicted-reconnect-storm-actually-happened)

## What led here: a plausible contributing trigger, client-side

Investigating the 2026-07-28 incident further (prompted by the user noticing they didn't recall actively developing on `wfmctrading` during the exact crash window) turned up two things:

1. **`netdata`'s retained `system.ram` history** (installed on `dev`, multi-day retention) showed RAM swinging between ~5% and ~88-89% used repeatedly across the full 53-hour window the leaking PHP-FPM worker was alive — not a smooth climb. Two *earlier* peaks (2026-07-26, 2026-07-27) hit similarly high levels without triggering an OOM at all. So the 11:33 crash wasn't uniquely extreme in raw percentage; something about that specific moment had less margin than the prior peaks.
2. **`sshd` logs on `dev`** showed real connection instability in the ~3 minutes right before the first OOM kill: `Connection timed out` read errors from a client IP that differed from the user's usual one, followed by a `Broken pipe`, all shortly before `wfmctrading-app-1` was OOM-killed at 11:33:36. The user confirmed this matches a long-standing pattern: **"the only time this ever happens is when connection gets cut."**

**The plausible mechanism:** VS Code Remote-SSH deliberately keeps its remote-side process (`vscode-server` + an extension-host tree) alive across a *clean* disconnect, so a reconnect can re-attach instantly instead of rebuilding from scratch. But a *bad* disconnect (timeout, broken pipe — not a clean close) can cause the client to spin up a **new** server-side process tree instead of trusting the old one, and VS Code's own troubleshooting docs confirm this is common enough to warrant a dedicated `Kill VS Code Server on Host` cleanup command. Repeated bad reconnects in a short window (flaky internet doing exactly that) can stack multiple such trees, each doing expensive startup work (re-indexing, restarting language servers) nearly simultaneously — a fast, concentrated memory/CPU burst that's much harder for an already-tight system to absorb gracefully than a slow leak is.

**Confidence level, stated plainly:** the RAM-swing pattern and the connection-instability logs are both directly confirmed. The specific claim that `vscode-server` churn was *the* thing spiking at 11:33 is not — no per-process memory snapshot survives from that exact moment (same limitation noted for the still-unconfirmed 2026-07-24 trigger). Treat this as a strong, well-corroborated contributing hypothesis sitting on top of the confirmed root cause of 2026-07-28 (the unrecycled PHP-FPM worker), not a replacement for it.

## Confirmed occurrence: the predicted reconnect storm actually happened

The finding above was a hypothesis about a *past* incident. Hours after it was first written, the exact mechanism it predicted happened live and was caught in the act.

**What happened:** home wifi dropped, then came back. The user had 3 separate VS Code Remote-SSH windows open against `dev` at the time. Plain `ssh dev` worked fine afterward, but none of the 3 VS Code windows could reconnect.

**Diagnosis on `dev`:**
- `free -h` showed swap **fully exhausted** (4.0Gi used / 8.0Ki free) and `user-1000.slice` sitting at `MemoryCurrent=13979181056` — right against the `MemoryHigh=13958643712` throttle line (see `self-healing.md`, item 3).
- `ps` showed **six distinct orphaned `vscode-server` sessions** (distinguishable by their `/tmp/user/1000/code-<uuid>` socket paths), with process start times spanning from the previous day at 15:41 through the incident — almost 24 hours of accumulated, never-cleaned-up sessions.
- Critically, those six sessions spanned **two different server commit hashes** (`125df467...` and `1b6a1881...`). That's the smoking gun: the local VS Code client auto-updated itself at some point during the repeated reconnect attempts. VS Code Remote-SSH can only reattach to a running server whose version matches the current client exactly — once the client updated, every further retry (across all 3 windows) was forced to install and boot an entirely fresh server + extension-host tree rather than reattaching to the one already running, and the old, now-orphaned trees had no client left that could ever ask them to shut down.
- Each session carried a full extension-host tree plus a per-session JVM (Salesforce Apex language server) — expensive to keep alive, and expensive multiplied by six. That's what actually exhausted swap and pinned the memory ceiling: not Docker, not a leak, but VS Code accumulating parallel copies of itself.
- A brand-new VS Code connection needs to fork a fresh server process; with swap gone and the cgroup already at its throttle line, there was no memory to give it. A bare interactive shell needs almost nothing by comparison, which is why plain `ssh` kept working the whole time.

**Immediate fix:** killed all orphaned `vscode-server` process trees and cleared the stale sockets in `/tmp/user/1000/`. Memory recovered instantly (`MemoryCurrent` dropped to ~354MB, swap back to near-zero). Confirmed the client-side `ServerAliveInterval 10` / `ServerAliveCountMax 3` settings were *not* the gap — the client detects a dead connection within ~30s just fine; the problem was entirely server-side non-cleanup.

**Lasting fix:** a scheduled reaper on `dev` for exactly this failure mode, since it can't be prevented at the client (a mid-outage auto-update forcing a version mismatch isn't something `ControlMaster`/keepalives can stop) and VS Code's own auto-shutdown clearly isn't reliable across a genuinely bad disconnect. See `self-healing.md`, item 6 — and [`incident-2026-08-03-vscode-server-pileup.md`](incident-2026-08-03-vscode-server-pileup.md) for what happened when that reaper turned out not to have actually been deployed.
