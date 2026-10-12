# Incident: Slow Mobile Link Times Out VS Code Remote-SSH, Hidden by a 7-Second Budget (2026-10-12)

## Overview

VS Code Remote-SSH to `dev` failed with `Connecting with SSH timed out` even after `fix-ssh --vscode dev` succeeded, while a plain `ssh dev` from the terminal worked. `dev` was healthy throughout and port 22 was open, so this was not any of the five known VM-side or port-filtering mechanisms. The client was on a mobile SIM delivering ~0.7 Mbit/s with 290–930 ms RTT, so a single SSH handshake took 4.4–5.5 s. Remote-SSH ignores `remote.SSH.connectTimeout` (set to 15) whenever `~/.ssh/config` sets `ConnectTimeout`, and uses that value + 2 s instead: with `ConnectTimeout 5`, that left a 7 s budget, which the link couldn't meet. Switching SIMs fixed the immediate problem, `ConnectTimeout` was raised to 15, and `check-dev` no longer misreports a slow link as a zombie ControlMaster.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

- `fix-ssh --vscode dev` ran successfully. VS Code still couldn't connect.
- The Remote-SSH log (`~/.config/Code/logs/*/window*/exthost/output_logging_*/1-Remote - SSH.log`) showed:

  ```
  Using connect timeout of 7 seconds
  > local-server-1> Running ssh connection command: ssh -v -T -D 35167 dev
  Terminating local server
  Resolver error: Error: Connecting with SSH timed out
  ```

  `ssh -v` produced no output at all before being killed 7 s later.
- `recon` reported `LOCAL ISSUE -- ... your local SSH ControlMaster to dev is likely a zombie` and recommended `fix-ssh`. That was wrong: no `~/.ssh/cm-*` socket existed, so there was no master to be a zombie.

## Diagnosis

| Check | Result | Rules out |
|---|---|---|
| `ping dev` | 0% loss, 290–930 ms RTT | VM down |
| TCP `dev:22` vs `dev:443` | 22 open, 443 instant refusal | Mechanism 5 (port-22 filtering) |
| `ssh dev 'uptime; free -h'` | load 0.28, 8.2 GiB available | Mechanisms 1, 2, 4 |
| `globalStorage/ms-vscode-remote.remote-ssh/*/data.json` | absent | 2026-10-03 stale-cache issue |
| Fresh non-multiplexed handshake | 4.4–5.5 s | — this is the cause |
| `curl` 5 MB download | ~89 KB/s, did not finish in 20 s | — confirms a slow link |

**Where 7 s comes from.** In `ms-vscode-remote.remote-ssh-0.128.0/out/extension.js`, `connectTimeoutMilliseconds` starts from `remote.SSH.connectTimeout` (default 15) but replaces it with the host's ssh `ConnectTimeout` when one is set, then adds 2 s. `~/.ssh/config`'s `Host *` block had `ConnectTimeout 5`, inherited from the original baseline with no recorded rationale. The `remote.SSH.connectTimeout: 15` that this repo's `vscode/settings.json` installs had never taken effect.

**Why `recon` was wrong.** `check-dev` probed with a 6 s hard timeout, then retried without multiplexing using an 8 s one. On a ~5.5 s link the first probe failed and the second succeeded, which the script read as "zombie ControlMaster" without checking whether a master existed.

## Fix

- **Network:** switched SIMs. On the new SIM: 283–328 ms RTT, ~10 Mbit/s, 3.5 s handshake.
- **`~/.ssh/config` (live, untracked):** `ConnectTimeout 5` → `15`, giving Remote-SSH a 17 s budget. A backup was saved as `~/.ssh/config.bak-2026-10-12`. Documented in `configs.md` §3. Trade-off: a plain `ssh` to a truly dead host now waits up to 15 s per attempt (× `ConnectionAttempts 5`) before failing.
- **`scripts/check-dev.sh`:**
  - A zombie verdict now requires that a ControlMaster socket existed before probing. Otherwise the script reports `FLAKY LINK`.
  - Probes use 15 s connect / 20 s hard timeouts, so a slow link isn't misread as a dead VM.
  - Each healthy run times a fresh handshake and reports a `slow client link` signature at ≥ 4 s, because the multiplexed probe can hide a slow link behind an existing master.
- **`README.md`:** notes that `remote.SSH.connectTimeout` only applies when ssh config doesn't set `ConnectTimeout`.

## Open items

- After `fix-ssh --vscode` ran, `check-dev` showed `dev` at 86% swap with 0 windows open, while RAM had 8 GiB available. That's most likely pages that stayed in swap after the kill rather than live pressure, but `check-dev`'s swap rule flags it anyway. Re-check later; if it persists with RAM free, consider `swapoff -a && swapon -a` on `dev` (sudo, user-run) or weighting the rule on available RAM.
- The Tailscale/WireGuard overlay recommended for mechanism 5 would not help here: this was bandwidth and latency, not filtering.
