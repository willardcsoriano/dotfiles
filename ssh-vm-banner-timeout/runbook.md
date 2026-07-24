# Next-Occurrence Runbook

## Overview

This is the concrete, ordered list of steps to run the next time SSH to the `dev` VM hangs at the banner exchange — before rebooting anything. Every prior incident ended in a full reboot, which erases the exact evidence (process state, memory, kernel logs, connection tables) needed to tell apart the three hypotheses in [`analysis.md`](analysis.md). Running these steps takes a few minutes and turns the next incident from "reboot and hope" into an actual root-cause diagnosis. All of this is read-only observation except the one explicitly marked restart step, so there's no risk in running it fully even under time pressure.

## Table of Contents

- [Overview](#overview)
- [Step 0 — Get in without going through the broken network path](#step-0-get-in-without-going-through-the-broken-network-path)
- [Step 1 — Capture evidence, in this order](#step-1-capture-evidence-in-this-order)
- [Step 2 — The single most informative test](#step-2-the-single-most-informative-test)
- [Step 3 — Record it](#step-3-record-it)

## Step 0 — Get in without going through the broken network path

Regular SSH won't work — that's the whole problem. Use Hetzner's **out-of-band console** instead (Cloud Console → the VM → "Console" / VNC or serial console). This logs in locally on the VM and does not depend on the network stack or `sshd` being healthy, so it works even while SSH is completely dead.

## Step 1 — Capture evidence, in this order

Run each of these and save the output (copy-paste into a scratch file, or a phone photo of the console if nothing else is available) before touching anything:

```bash
systemctl status ssh                                      # is it even "active (running)"?
ps auxf | grep -i ssh                                      # zombie/defunct (Z) children piling up?
ss -tnp state all '( sport = :22 )'                         # connections stuck in the kernel accept queue?
free -h                                                     # memory exhausted?
df -h                                                       # disk full?
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max                # conntrack table full?
dmesg -T | tail -100                                        # OOM killer, fork failures, conntrack drops
```

What each answers, per the ranked hypotheses in `analysis.md`:

| Command | Confirms | Rules out |
|---|---|---|
| `ps auxf` shows many `Z` (defunct) `sshd` children | Hypothesis 1 (resource exhaustion / churn) | — |
| `nf_conntrack_count` at/near `nf_conntrack_max` | Hypothesis 2 (conntrack exhaustion) | — |
| `dmesg` shows `nf_conntrack: table full` | Hypothesis 2 | — |
| `free -h` near-zero available, or `dmesg` shows OOM killer activity | Hypothesis 3 (memory exhaustion) | — |
| `df -h` shows a full filesystem | Hypothesis 3 (disk exhaustion) | — |
| None of the above look abnormal, but `systemctl status ssh` shows it's not "active" | A different failure than any hypothesis above — capture full `systemctl status ssh -l` and `journalctl -u ssh --since "-1 hour"` | — |

## Step 2 — The single most informative test

**Before rebooting the whole VM**, try restarting just the SSH service from the console:

```bash
sudo systemctl restart ssh
```

Then, from another machine, try connecting again:

```bash
nc 178.104.35.30 22
```

- **If this alone fixes it:** the problem is scoped to `sshd`/userspace (hypothesis 1). A full VM reboot was never necessary — this is the fix going forward, and the real work becomes finding out why connections pile up rather than getting reaped.
- **If this does NOT fix it, and only a full VM reboot does:** the problem is system/kernel-scoped (hypothesis 2 or 3). Look specifically at whatever `nf_conntrack_count`, `free -h`, and `dmesg` showed in Step 1.

## Step 3 — Record it

Append the captured output and which hypothesis it points to into [`timeline.md`](timeline.md) as a new dated entry, and update [`configs.md`](configs.md) if any config was touched. Once a hypothesis is confirmed, the actual permanent fix (a `sysctl` tune for conntrack, a systemd resource limit, a memory/disk increase, or a fix to whatever leaves unauthenticated connections unreaped) should replace the guesswork in `analysis.md` with a confirmed root cause.
