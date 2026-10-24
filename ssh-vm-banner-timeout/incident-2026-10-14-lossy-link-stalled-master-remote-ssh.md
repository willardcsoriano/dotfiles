# Incident: Lossy Links Time Out VS Code Remote-SSH, and the Fixes Made It Worse (2026-10-14/15)

## Overview

On two consecutive days VS Code Remote-SSH to `dev` failed with `Connecting with SSH timed out`, while `dev` itself was healthy and plain `ssh` worked. On 2026-10-14 the cause was the client link: phone data in a moving car, with 15% loss and 2.2 s stalls at the first hop, pushing a fresh SSH login to 16.2 s against Remote-SSH's 17 s budget. On 2026-10-15 a lossy route to `dev` (5–9% loss) did the same; five more attempts then timed out while a shared ControlMaster was open, and why those failed is **unconfirmed**. The reflexive fixes hurt: `fix-ssh --vscode` was run five times, and each run only made the next connect slower. Hardening that followed: `check-net` to grade the link (dotfiles#43), `fix-ssh` closing stalled or frozen masters and warning on a slow link (#44), and `ConnectTimeout` raised to 30 (#45). That last one turned out to reach plain `ssh` only. VS Code never saw it, which was found and fixed on 2026-10-24.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Fixes](#fixes)
- [Open items](#open-items)

## What happened

**2026-10-14, about 14:30 local, travelling by car on phone data.**

- Remote-SSH timed out at exactly 17 s (`Using connect timeout of 17 seconds`).
- `fix-ssh --vscode dev` was run five times in a row. Each run succeeded, which made it look like the fix, but it killed a healthy server each time.
- After 14:31 the VS Code window stopped retrying and sat on the error. Nothing in the Remote-SSH log changed while "retrying".

**2026-10-15, about 13:50–14:08 local.**

- Attempts at 13:51–13:53 timed out with no shared connection open.
- A master was opened by hand at 13:57. Attempts at 14:02:26, 14:02:54, 14:03:21, 14:03:49 and 14:04:56 still timed out, with no ssh output logged.
- At about 14:05 a command-line session through the same master, with the same `-D` flag VS Code uses, succeeded.
- By 14:08 that master was gone. VS Code's 14:08 attempt logged in directly in 2.4 s (`Server host key`, then `Authenticated`), became the new master, and connected.

## Diagnosis

| Measurement | 10-14 in the car | 10-14 at destination | 10-15 failing | 10-15 later |
|---|---|---|---|---|
| Laptop → router | 15% loss, 394 ms avg, 2.2 s worst | 0%, 30 ms | 0%, 11 ms | 0%, 2 ms |
| Laptop → internet | 0%, 206 ms | 0%, 88 ms | 5%, 117 ms | 0%, 67 ms |
| Laptop → dev | 0%, 424 ms | 15%, 557 ms | 9%, 354 ms | 5%, 307 ms |
| Fresh SSH login | 5.5 s, 16.2 s | 4.2 s | 4.4–11 s; 18.3 s and one failure in nearby runs | 3.4–3.6 s |

- **`dev` was healthy throughout:**
  - load under 0.4
  - no memory pressure (PSI 0)
  - sshd had no backlog of half-open connections
  - the VS Code server for the current commit was installed
- **The 17 s budget** was `remote.SSH.connectTimeout` (15) + 2 s. At the time it was attributed to ssh's `ConnectTimeout`, also 15, as in `incident-2026-10-12-slow-mobile-link-remote-ssh-timeout.md`. But that value lived in an included file, and the extension doesn't follow `Include` (found 2026-10-24, `incident-2026-10-24-login-grace-and-vscode-budget-remote-ssh.md`). Either way the window covers the ssh login **and** starting VS Code's server on `dev`. `ConnectTimeout` covers TCP, the banner and key exchange but not authentication (`man ssh_config`), so a slow login fails VS Code's budget without ever tripping ssh's own timeout.
- **Why `fix-ssh --vscode` couldn't help:** it acts on the server side, and the server was fine. Killing it means the next connect also has to start a new server inside the same budget.
- **Unconfirmed: the 14:02–14:04 failures with a master open.**
  - One hypothesis was a master stalled on the lossy link. `ssh -O check` would still pass such a master, because it only talks to the local process.
  - But a command-line session through that master succeeded at about 14:05, seconds after the 14:04:56 failure.
  - VS Code logs no ssh output when it times out, so where its connection stalled couldn't be pinned down.
  - What is confirmed: holding a master open did not help VS Code connect, and a direct attempt did.
  - **Candidate found 2026-10-24, not confirmed for 10-15:** the 17 s window also covers starting VS Code's server on `dev`. On 2026-10-24 ssh logged in within 2 s and the server start over a lossy route used the remaining 15 s. With a master open the login is instant, so the 14:02–14:04 attempts may have run out the clock in the same way.

## Fixes

- **`check-net [host]`** (dotfiles#43):
  - Pings the router, the internet and the host at the same moment, and names the hop at fault.
  - Times three fresh logins against VS Code's connect budget. That was derived from `ssh -G` at first, and from `vscode-ssh-budget` since 2026-10-24.
  - Sends one session through any open master to catch one that can't carry sessions.
  - Prints GOOD, MARGINAL, POOR or UNREACHABLE. For MARGINAL it says to retry, then fall back to `ssh dev` + tmux. An earlier draft advised pre-opening a master, which is withdrawn per the unconfirmed item above.
  - `recon` runs it.
- **`fix-ssh`** (dotfiles#44):
  - Bounds `ssh -O check` at 5 s, opens one real session through each live master with a 10 s limit, and closes masters that fail either check.
  - `--vscode` times its own fresh login and warns when the link, not `dev`, is the problem.
  - See `self-healing.md` item 5.
- **`ConnectTimeout 30`** (dotfiles#45):
  - Meant to raise Remote-SSH's budget to 32 s, above the worst login measured (18.3 s). It only reached plain `ssh`. The VS Code half, `remote.SSH.connectTimeout: 60` plus `vscode-ssh-budget` so the tools grade against the real window, landed in the same PR after the 2026-10-24 incident.
  - Cost: plain `ssh` takes longer to give up on a host that silently drops TCP.
  - `check-dev` now derives its probe timeouts from VS Code's real budget instead of hardcoding 15/20 s.
  - See `configs.md` §3.

## Open items

- **Root cause of the 14:02–14:04 failures.** Next time, capture the stuck ssh process during an attempt (`ps -o stat,wchan`, its sockets) and raise Remote-SSH's log level before retrying. Which `remote.SSH.loglevel` value shows full ssh output has not been verified.
- **mosh** for terminal-only work on lossy or roaming links. It survives IP changes and doesn't stall on loss. It needs UDP 60000–61000 opened in UFW and the Hetzner Cloud Firewall, which waits for an explicit go-ahead.
- **`check-dev` slice-ceiling signature.** On 2026-10-15 it reported `swap/memory ceiling pressure` with `user-1000.slice` at 98% of `MemoryHigh` while PSI was 0 and nothing was stalling. `memory.current` counts reclaimable page cache, so sitting near the ceiling isn't pressure by itself. Same class of false alarm as dotfiles#28. Tracked and fixed in dotfiles#49.
