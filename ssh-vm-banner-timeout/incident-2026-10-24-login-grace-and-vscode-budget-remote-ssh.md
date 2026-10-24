# Incident: sshd's 30 s Login Deadline and VS Code's Hidden 17 s Window (2026-10-24)

## Overview

On a route to `dev` losing up to 51% of packets (the router and the internet were clean), two separate timers were too short, one on each end. First, `ssh dev` failed with `Connection closed by <dev> port 22`. `dev`'s sshd drops any login not finished within `LoginGraceTime 30`, counted from TCP connect, and the lossy key exchange used up most of it. Second, after that was raised to 60, VS Code Remote-SSH still timed out while terminal `ssh` worked. The extension doesn't follow `Include`, so the dotfiles `ConnectTimeout 30` never reached it, and it used `remote.SSH.connectTimeout: 15`, a 17 s window that had to cover the login **and** starting its server. Fixes:

- `LoginGraceTime 60` on `dev` (debian-server-baselines#26/#27)
- `remote.SSH.connectTimeout: 60` (dotfiles#45)
- `vscode-ssh-budget`, so `check-net`, `check-dev` and `fix-ssh` grade against VS Code's real window (#45)

A suspected `PerSourcePenalties` lockout was checked and ruled out.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Fixes](#fixes)
- [Verification](#verification)
- [Open items](#open-items)

## What happened

All times are local (UTC+8). `dev`'s journal is in UTC, 8 hours behind.

- **About 21:13.** `ssh dev` printed `Connection closed by <dev> port 22`. `dev`'s sshd log for that connection:

  ```
  21:13:13  Connection from <laptop>
  21:13:15  Postponed publickey for <user> [preauth]      (key offered, waiting for the signature)
  21:13:43  Timeout before authentication                  (30 s after connect)
  21:13:43  srclimit_penalise: ... deferred penalty of 10 seconds for penalty: exceeded LoginGraceTime
  ```

- **About 21:16.** `check-net`: router 0% loss, internet 0%, `dev` **51%** loss at about 205 ms. Fresh logins took 15.0, 12.9 and 19.7 s. It graded MARGINAL against a "32.0 s" budget. That number was wrong, see below. The installed copy was also stale and still gave the withdrawn "run `ssh dev true` first" advice. It was reinstalled.
- **21:16–21:17.** Three verbose logins succeeded in 17, 3 and 2 s as the route recovered.
- **About 21:40.** `LoginGraceTime` was raised to 60 on `dev` and reloaded.
- **21:42:56.** VS Code Remote-SSH: `Using connect timeout of 17 seconds`, spawned `ssh … -o ConnectTimeout=15 dev`, and was logged in by 21:43:00. It then spent the rest of the window on server setup and failed at 21:43:15 with `Connecting with SSH timed out`. Terminal `ssh dev` worked at the same time.
- **22:58.** With `remote.SSH.connectTimeout: 60` set, the extension logged `Using connect timeout of 62 seconds` and connected.

## Diagnosis

**1. `LoginGraceTime 30` dropped a legitimate key login.**

- sshd's grace clock starts at TCP accept. Over the lossy route, reaching the key step took 1–32 s across the logins in the log. The 21:13 attempt offered its key at 2 s, but the signature exchange didn't complete in the remaining 28 s.
- When grace expires, sshd closes the socket, and the client prints `Connection closed by … port 22`. That message means the server closed on purpose, which is different from the banner-exchange and connect timeouts in earlier incidents.

**Ruled out: `PerSourcePenalties`.** OpenSSH 10.0 (Debian 13) has it on by default: `authfail:5 noauth:1 grace-exceeded:10 … max:600 min:15`, read from `sshd -T`.

- The laptop's address got two penalties: 1 s at 21:03:51 for a connection reset before auth, and 10 s at 21:13:43 for the grace timeout. That's 11 s total, below the 15 s `min` at which enforcement starts.
- Both are logged as `deferred`, and there's no `drop connection` line for the laptop.
- The same log shows internet scanners collecting 1 s penalties about every 30 s, so the mechanism is live. It just never tripped for us.

**Ruled out: fail2ban.** It's active on `dev`, but its sshd jail bans through nftables. A ban drops packets, so it shows up as a timeout, not as `Connection closed by`.

**2. VS Code's window was 17 s, not the 32 s everything assumed.**

`connectTimeoutMilliseconds()` in `ms-vscode-remote.remote-ssh-0.128.0/out/extension.js`:

- starts from `remote.SSH.connectTimeout`, 15 when unset
- replaces it with the host's `ConnectTimeout` from the extension's **own** parse of `~/.ssh/config` (0 means no limit)
- adds 2 s

When it finds no `ConnectTimeout`, it also passes `-o ConnectTimeout=<setting>` to ssh. The extension code has no `Include` handling. Since 2026-10-12 the dotfiles defaults, including `ConnectTimeout` (raised to 30 on 2026-10-15, dotfiles#45), have lived in the included `~/.ssh/config.d/dotfiles-defaults.conf`. From then on VS Code used the setting: a 17 s window. `ssh -G dev` reports `connecttimeout 30`, which is why `check-net`, `check-dev` and `fix-ssh` all assumed 32 s.

That window covers the whole connect, not just ssh. At 21:42 the ssh login took 2 s and server setup took the other 15.

## Fixes

- **`dev`: `LoginGraceTime 60`** (debian-server-baselines#26, PR #27). Set in `scripts/base.sh`, with the rationale in a comment there and in the walkthrough's sshd table. Applied live with `sed`, then `sshd -t`, then `systemctl reload ssh`.
  - Cost: a never-authenticating connection holds a pre-auth slot for up to 60 s. That's still bounded by `MaxStartups 100:30:150`, `PerSourcePenalties`, key-only auth and fail2ban.
  - Hosts provisioned earlier keep 30 until `base.sh` is re-run. `dev` is the only one.
- **VS Code: `remote.SSH.connectTimeout: 60`** (`vscode/settings.json`, dotfiles#45), a 62 s window that lines up with `dev`'s grace time. Cost: a dead host takes up to a minute to fail in VS Code.
- **`vscode-ssh-budget`** (dotfiles#45) prints the window VS Code will actually use by mirroring the extension's rule. `check-net`, `check-dev` and `fix-ssh --vscode` grade against it instead of `ssh -G`, and fail loudly if it's missing.
- **`check-net`** no longer prints "restart your router" advice under a GOOD verdict (dotfiles#43).
- **Doc corrections** (dotfiles#45): README, `configs.md` §3, the `defaults.conf` comment, and the 2026-10-12 and 2026-10-14 write-ups no longer say ssh's `ConnectTimeout` sets VS Code's window.

## Verification

- **Grace time, measured from the laptop.** An idle TCP connection to port 22 that never sends anything was closed by `dev` after **33.9 s** before the change and **61.3 s** after. `sshd -T` reports `logingracetime 60`.
- **VS Code window.** The extension's own log said `17 seconds` before the settings change and `62 seconds` after, and the 22:58 connect succeeded. `vscode-ssh-budget dev` printed 62 against the same configuration. Its test suite reproduces the 17 s case: `ConnectTimeout` only in an Included file, with the setting at 15.
- **Tools.** Run from the repo: `check-net` reports "Remote-SSH gives up at 62.0s" and GOOD on the recovered link (33% loss to `dev`, logins 4.5–6.5 s). With the helper removed from reach, it exits 2 with `vscode-ssh-budget not found`. Plain `fix-ssh` left the live master alone.
- `shellcheck` 0.10.0 is clean on every changed script. `check-net.test.sh` and `vscode-ssh-budget.test.sh` both pass.

## Follow-ups (closed 2026-10-24)

- **The route to `dev`.** Re-measured after the fixes. Ping loss to `dev` is bursty, varying from 0% to 20% between runs at every rate tried (0.2 s, 0.5 s and 1 s intervals), while the internet hop stays at 0%. A 25 MB transfer over ssh saw 0 TCP retransmits out of 807 segments, and fresh logins took 2.3–3.8 s. ICMP to `dev` overstates what TCP experiences. Nothing on the client or `dev` side can change the route, and the timers above now tolerate it. mosh was declined: the current setup stays as it is.
- **`check-dev` slice-ceiling false alarm.** Fixed in dotfiles#49. dotfiles#57 then judges the slice by its own cgroup PSI and reports an unreadable PSI as unknown rather than idle.
- **`check-net`** (dotfiles#55):
  - It stops at the first failed login, so one run can cost at most one `PerSourcePenalties` charge, which stays below the 15 s enforcement minimum.
  - Only a timeout counts as a stalled shared connection.
  - It grades the worst login plus VS Code's measured server setup. The 22:58 connect spent 6.6 s on setup after a 14.2 s login.
- **`vscode-ssh-budget`** (dotfiles#56):
  - It evaluates `Match` the way the extension does, read from `extension.js` 0.128.0, including case-sensitive directive names and `?` matching zero or one character.
  - It checks itself against the extension's own logged timeout.
- **Commit messages** `4e6669d` and `511701e` overstated the 10-15 stalled-master cause. They now carry correcting git notes (`git log` shows them, from `refs/notes/commits`).
