# Incident: VS Code Agent Host Wedged on New Connections, Existing Window Unaffected (2026-08-05)

## Overview

On 2026-08-05, a new VS Code Remote-SSH window against `dev` couldn't connect, while an already-open window kept working fine — a different shape from the earlier memory-exhaustion incidents. `dev` itself was healthy throughout (8.5Gi free RAM, swap barely touched, `docker.service` active, load under 1). The remote `vscode-server` "agent host" process — shared by every window, 2 days old at the time — accepted the new connection's TCP tunnel but hung indefinitely at the exec-server handshake step, the point where it spins up a session for a new window specifically. `fix-ssh --vscode dev` (force-kill + fresh respawn) resolved it immediately; the existing window dropped as expected and reconnected cleanly against the new agent host. A separate, unrelated symptom — lagginess right after reconnecting — turned out to be 50% packet loss and ~270ms latency on a newly-joined network, not anything to do with `vscode-server` at all.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Fix](#fix)
- [Unrelated finding: post-fix lag was a bad network, not the fix](#unrelated-finding-post-fix-lag-was-a-bad-network-not-the-fix)
- [Open question: why did the agent host wedge?](#open-question-why-did-the-agent-host-wedge)

## What happened

Terminal SSH to `dev` worked fine throughout. VS Code Remote-SSH also had one window already connected and functioning normally. But a new connection attempt hung with no error — no timeout, no visible failure, just stuck.

## Diagnosis

- `dev` was fully healthy: `free -h` showed 8.5Gi free of 15Gi, swap at 1.8Gi/4Gi (not climbing), `docker.service` active, load average under 1. Ruled out the memory-exhaustion pattern from the two prior incidents immediately.
- The local `~/.ssh/cm-*` ControlMaster socket was live and correctly multiplexing (`ssh -O check` confirmed `Master running`) — not a stale-socket problem either.
- The new connection's own `Remote - SSH` log (`~/.config/Code/logs/.../1-Remote - SSH.log`) showed the attempt getting as far as tunneling into the remote successfully (`Resolved "ssh-remote+dev" to "port 42699"`, `Tunneled port 35435 to local port 42699`), then hanging forever at `Resolving exec server at port 42699` — over 3 minutes with zero further progress at the time it was checked.
- On `dev`, the remote agent host process (`PID 1346626`, one process shared by every window connecting to that same commit hash) had been running for **2 days** uptime. A direct TCP probe (`/dev/tcp/127.0.0.1/35435`) from `dev` confirmed the port was open and accepting connections — so this wasn't a dead process or a closed port. Resource checks on that process came back clean too: only 15 open file descriptors (ulimit 524288), 9 threads, no sign of exhaustion.
- Conclusion: the agent host was alive, accepting raw TCP, and still correctly serving the one already-established window — but wedged specifically on the handshake needed to spin up a session for a *new* window. Not a crash, not resource exhaustion, just stuck on that one code path.

## Fix

`fix-ssh --vscode dev` (see `self-healing.md`, item 5) — force-kills every `vscode-server` process on the host. Run by hand this time (not by me — the user ran the already-installed alias directly). Confirmed effective: the old 2-day-old agent host (`PID 1346626`) was gone afterward, replaced by a freshly spawned one (`PID 1943431`, ~2 minutes old) once VS Code reconnected. The previously-stuck new-connection attempt succeeded once the wedged process was gone.

As expected per the tool's documented behavior, this also dropped the one already-connected window — it reconnected cleanly against the new agent host, no lost work.

## Unrelated finding: post-fix lag was a bad network, not the fix

Right after reconnecting, the session felt laggy. Two candidate explanations existed: (1) the fresh agent host's extension hosts and language servers cold-starting from zero, or (2) a newly-joined network with a bad path to `dev`. A direct ping test settled it: **50% packet loss, ~270ms RTT** to `178.104.35.30` on the new network — a real, separate problem with that network's route to Hetzner, unrelated to `vscode-server` and not fixable by restarting anything on either end. Worth keeping distinct: not every symptom reported right after a fix is caused by the same root cause as the fix.

## Open question: why did the agent host wedge?

Root cause of the wedge itself was not identified — no resource exhaustion, no crash, nothing in the process's own state suggested why it stopped completing new handshakes after 2 days of uptime while continuing to serve its existing connection. This is the first confirmed case of this specific symptom (one window fine, new ones hang, VM otherwise healthy); if it recurs, checking agent host uptime and re-running `fix-ssh --vscode dev` is the known-working move, but the underlying "why" remains unconfirmed.
