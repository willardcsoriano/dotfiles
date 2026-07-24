# Next-Occurrence Runbook

## Overview

This is the concrete, ordered list of steps to run the next time SSH to the `dev` VM hangs at the banner exchange. It replaces an earlier version of this runbook that assumed the Hetzner out-of-band VNC console would be available — it wasn't, during the 2026-07-24 incident, so this version is based on what actually worked instead: the `hcloud` CLI plus a `journalctl -b -1` read taken immediately after recovery. That combination is how the Docker/OOM crash-restart cascade in [`analysis.md`](analysis.md) was found, without ever needing the console. All of Steps 1-2 are read-only or reversible; Steps 3-4 are the actual restart escalation, used only after Steps 1-2 don't resolve it.

## Table of Contents

- [Overview](#overview)
- [Step 1 — Confirm `hcloud` is pointed at the right project](#step-1-confirm-hcloud-is-pointed-at-the-right-project)
- [Step 2 — Pull metrics before touching anything](#step-2-pull-metrics-before-touching-anything)
- [Step 3 — Try the cheap, non-destructive options first](#step-3-try-the-cheap-non-destructive-options-first)
- [Step 4 — Escalate: soft reboot, then hard reset](#step-4-escalate-soft-reboot-then-hard-reset)
- [Step 5 — The moment SSH comes back, capture the previous boot's logs](#step-5-the-moment-ssh-comes-back-capture-the-previous-boots-logs)
- [Step 6 — Record it](#step-6-record-it)

## Step 1 — Confirm `hcloud` is pointed at the right project

The `dev` server does not live under the default/active `hcloud` context on this laptop — it's under a separate project. Check and switch if needed:

```bash
hcloud context list          # look for the context that isn't marked active
hcloud context use willard-mba15
hcloud server list -o columns=id,name,status,ipv4   # confirm "dev" shows up here
```

## Step 2 — Pull metrics before touching anything

This is read-only, needs no VM access, and is the single most useful diagnostic step — it's what actually found the 2026-07-24 cascade:

```bash
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$(date -u -d '12 hours ago' +%Y-%m-%dT%H:%M:%SZ)
for t in cpu network disk; do
  hcloud server metrics dev --type "$t" --start "$start" --end "$now" -o json > "/tmp/metrics_$t.json"
done
```

Look at the last 20-30 samples of each (CPU, disk bandwidth, network bandwidth/pps). What to look for, based on what was actually found last time:

- **Sustained (not bursty) CPU and/or disk-read spike, with network flat** → an internal process (very likely Docker again — check `docker.service` and `docker ps -a` the moment SSH is back) is pegging the VM. This is exactly what happened on 2026-07-24.
- **A spike in network in/pps.in correlating with the outage** → points back toward the original connection-churn theory (`MaxStartups`, `nf_conntrack`) instead — see the superseded hypotheses in `analysis.md`, which would become relevant again if the evidence actually looks like this next time.
- **Nothing abnormal in any metric** → the cascade this time isn't resource-based; go straight to Step 5 once back in, and check `journalctl -b -1` broadly rather than starting from the Docker angle.

## Step 3 — Try the cheap, non-destructive options first

```bash
hcloud server reset-password dev
```

This resets the root password live, via `qemu-guest-agent`, with **no reboot** — if it succeeds, the guest is at least partially responsive and you may be able to get in without restarting at all. If it fails with `guest_agent_unavailable`, that itself is useful evidence: the guest is too starved/wedged to service even this side-channel request (this is what happened on 2026-07-24, consistent with the severe CPU/disk pressure found in Step 2).

## Step 4 — Escalate: soft reboot, then hard reset

```bash
hcloud server reboot dev   # soft ACPI reboot — try this first
```

Wait ~30-60s, then re-check the metrics from Step 2 (or just try SSH). **If the CPU/disk anomaly continues unchanged, the soft reboot did not take effect** — a wedged guest can fail to honor a graceful ACPI signal, which is what happened on 2026-07-24. Escalate:

```bash
hcloud server reset dev   # hard power-cycle — use if the soft reboot had no effect
```

This is more abrupt (equivalent to yanking power) and can risk filesystem inconsistency if writes were in flight — check the Step 2 metrics for `disk.*.bandwidth.write` levels before doing this if there's time; on 2026-07-24 write levels were normal throughout (only reads were elevated), which made this an acceptable risk.

## Step 5 — The moment SSH comes back, capture the previous boot's logs

This is time-sensitive — don't do anything else first. `journalctl` only keeps a limited number of past boots, and the whole point is to read the boot that just ended, before it rotates out:

```bash
ssh dev 'journalctl --list-boots'
# then, using the boot index for the one that just ended (e.g. -1):
ssh dev 'journalctl -b -1 --since "<a few minutes before the outage started>" --no-pager'
```

Also worth checking immediately, given what turned up last time:

```bash
ssh dev 'free -h; systemctl --user status docker.service --no-pager -l; docker ps -a'
```

If the journal shows Docker health-check failures, OOM-killer activity, or a `docker.service` restart loop, that's the same cascade as 2026-07-24 — go straight to the fixes listed in `analysis.md` (swap, health-check resilience, memory limits) rather than re-diagnosing from scratch. If it shows something else entirely, this is a new failure mode — document it as a new entry, don't force-fit it into the existing analysis.

## Step 6 — Record it

Append what was found into [`timeline.md`](timeline.md) as a new dated entry, and update [`configs.md`](configs.md) / [`analysis.md`](analysis.md) if anything changed or was newly confirmed. If this turns out to be the same Docker/OOM cascade recurring, that itself is important information: it means the fixes listed in `analysis.md` still haven't been implemented, and should stop being optional.
