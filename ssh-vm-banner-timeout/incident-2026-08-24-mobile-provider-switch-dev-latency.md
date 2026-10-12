# Incident: New Mobile Data Provider Reproduces the Destination-Specific `dev` Degradation Pattern (2026-08-24)

## Overview

After switching mobile data providers (the old one was slow), `recon` started reporting `dev` as UNREACHABLE, and the initial assumption was that VS Code Remote-SSH had choked the VM again — the same story as prior incidents in this directory. It wasn't. `make check`'s `hcloud` calls failed on local DNS resolution (`10.168.203.17`, the new network's own resolver, timing out on `api.hetzner.cloud`), and `dev`'s disk metrics that did come through were idle, not the heavy-write signature of a crash loop. A retry of `fix-ssh --vscode dev` succeeded seconds before `recon` reported the fresh, non-multiplexed connection check failing again — the connection is flaky, not down. A comparative ping (`dev`'s IP vs. `github.com`, same network, same moment) confirmed it: 0% loss to both, but `dev` alone showed 264-715ms latency and 152ms jitter against GitHub's 59-363ms/117ms. This is the same destination-specific degradation pattern documented in `incident-2026-08-12-mobile-sim-connectivity-struggle.md`, now on a third distinct network. No VM-side action was taken — `dev`'s tmux-hosted coding-agent sessions were never at risk, since they persist independent of the SSH connection.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Why the existing hardening didn't help](#why-the-existing-hardening-didnt-help)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

`recon` reported:

```
[dev]
UNREACHABLE -- dev didn't respond even to a fresh, non-multiplexed connection.
```

which per `scripts/check-dev.sh`'s logic (a hang on the normal multiplexed connection, *and* a hang on a `ControlPath=none` fresh connection) is the branch that points at `make check` / `make recover`, not the ControlMaster-zombie branch. The initial read — "VS Code choked the VM again," matching the pileup mechanism from `incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md` — was a reasonable first guess given the history in this directory, but didn't hold up once checked:

- `fix-ssh --vscode dev` was run and completed cleanly (`Killing vscode-server processes on dev... Done.`) — a genuinely wedged VM under real memory/CPU pressure (the actual pileup signature) does not accept and complete a fresh SSH command that fast.
- `recon` immediately after still reported `dev` UNREACHABLE, in under a minute. A VM doesn't oscillate between "wedged" and "healthy enough to run a remote command" that quickly; a flaky client-side network path does.

## Diagnosis

`make check` was run for metrics and instead surfaced the real signal:

```
hcloud: Get "https://api.hetzner.cloud/v1/servers?name=dev": dial tcp: lookup api.hetzner.cloud on 10.168.203.17:53: read udp ...: i/o timeout
```

`10.168.203.17` is the new mobile network's own DNS resolver (confirmed via `/etc/resolv.conf` on `mba15` — `nameserver 10.168.203.17`, matching the `10.168.203.0/24` subnet `wlp3s0` is on). Two of three `hcloud` calls in the same loop iteration timed out on DNS; the third succeeded and returned real data — itself a sign of an intermittently flaky path rather than a hard outage. The `disk` metrics that did come through were effectively idle (0 read IOPS, single-digit-KB/s writes) — not the heavy-write signature of a Docker crash-restart loop from the earlier incidents in this directory.

Two follow-up checks confirmed the client-network theory directly, without touching `dev`:

1. **Retry a fresh, non-multiplexed SSH connection three times in a row**: attempt 1 failed, attempts 2 and 3 succeeded. Not a hard down.
2. **Comparative ping, `dev`'s IP vs. a same-distance control host, same network, same moment** (10 pings each):

   | | packet loss | latency (min/avg/max) | jitter (mdev) |
   |---|---|---|---|
   | `dev` (<dev-ip>) | 0% | 264 / 488 / 715 ms | 152 ms |
   | `github.com` | 0% | 59 / 203 / 363 ms | 117 ms |

   0% loss on both rules out a hard block, but `dev` alone is running 2-4x the latency and jitter of a comparable distant host on the identical network path at the identical moment — a destination-specific problem, not a broadly bad connection. This is the exact shape of the root cause identified in `incident-2026-08-12-mobile-sim-connectivity-struggle.md`, just manifesting as latency/jitter this time instead of that incident's heavier packet loss — plenty for SSH's handshake/banner-exchange timeout to trip on an unlucky attempt, which is why some connections succeed and others don't.

## Why the existing hardening didn't help

Nothing in `self-healing.md` was ever built for this mechanism, so its absence here isn't a regression:

- The Docker crash-loop guard and `vscode-server` reaper/memory-ceiling mitigations target VM-side resource exhaustion. `dev`'s own metrics (idle disk, a command that executed and returned cleanly) don't show that signature here.
- The `ssh-control-reset` sleep hook and `ControlMaster` client tuning target the *laptop-suspend/resume* zombie-socket failure mode. This incident didn't involve a suspend/resume cycle at all — it started fresh off a network switch, a trigger that hook was never wired to.
- `ConnectionAttempts 5` (added to `~/.ssh/config` during the 2026-08-12 incident) is exactly why `fix-ssh --vscode dev` was able to succeed on a retry within its own invocation, and is doing its job — it just isn't enough by itself to make every single manual invocation succeed against a genuinely degraded path.

The one mitigation that has ever actually resolved this specific mechanism — switching carriers entirely — is client-network-path-level, not something any of the deployed VM- or SSH-config hardening was designed to reach.

## Fix

No VM-side action taken or needed. `dev` was never down; the tmux-hosted agent sessions on it were never at risk, since they persist server-side independent of any single SSH connection (this is the exact scenario the `tmux.conf` deployment noted in the README was hardened for). The practical fix in the moment is simply retrying — the failure is intermittent, not absolute, and most attempts succeed.

## Open items

- **Third occurrence of the same pattern, now across three unrelated networks** (company Wi-Fi hard block, Smart SIM heavy loss, this new provider's latency/jitter) — see the "Open items" section of `incident-2026-08-12-mobile-sim-connectivity-struggle.md`, which already flagged this as a real pattern rather than coincidence and named a Tailscale/WireGuard overlay tunnel to `dev` as the strongest structural fix if it kept recurring. It has now recurred. Worth revisiting that recommendation rather than treating each occurrence as a one-off.
- **`check-dev.sh`'s UNREACHABLE branch has no way to distinguish** "genuinely down" from "flaky path, retry and it'll probably work" — both currently point at `make check` / `make recover`, which nudges toward VM-side action (up to and including a hard reset) for a class of failure a VM-side action can't fix. Worth adding a quick comparative-ping or multi-attempt retry step to that branch before it recommends `make recover`, so a future read of this script doesn't push straight toward rebooting a VM with live agent sessions on it for a problem that isn't the VM's.
