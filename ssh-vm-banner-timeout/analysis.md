# Technical Analysis

## Overview

This explains why the four SSH-layer fixes in [`timeline.md`](timeline.md) were always going to fail, and ranks the hypotheses for what's actually causing the issue. The short version: a completed TCP handshake with zero application data ever returned means the failure is happening below `sshd`'s application logic — either `sshd` itself is starved of a resource it needs to fork a handler, or the kernel/netfilter layer is silently absorbing new connections system-wide. Nothing here has been confirmed yet; confirming it requires catching the VM in the broken state via the out-of-band console before rebooting, per [`runbook.md`](runbook.md). This file exists so the next diagnostic session starts from a ranked theory instead of from scratch.

## Table of Contents

- [Overview](#overview)
- [What "TCP completes, no banner, forever" actually means](#what-tcp-completes-no-banner-forever-actually-means)
- [Ranked hypotheses](#ranked-hypotheses)
  - [1. `sshd` resource exhaustion from repeated connection churn (most likely)](#1-sshd-resource-exhaustion-from-repeated-connection-churn-most-likely)
  - [2. Kernel-level connection tracking (`nf_conntrack`) exhaustion](#2-kernel-level-connection-tracking-nf_conntrack-exhaustion)
  - [3. Memory or disk exhaustion](#3-memory-or-disk-exhaustion)
- [Why "just reboot" always "fixed" it — and why that's misleading](#why-just-reboot-always-fixed-it-and-why-thats-misleading)

## What "TCP completes, no banner, forever" actually means

The TCP three-way handshake is completed entirely by the kernel. It can accept a connection into its listen queue and complete the handshake whether or not `sshd` is alive, healthy, or currently able to service it. The `SSH-2.0-OpenSSH_...` banner is only sent once `sshd` calls `accept()` on that queued connection and spins up a handler for it — which happens essentially immediately, before authentication, before PAM, before anything else in the SSH protocol.

So "port open, handshake completes, then infinite silence" means one of two things:

1. `sshd` (or the fork it needs to make) is not running, wedged, or unable to allocate a resource it needs — the kernel queued the connection, but nothing ever picked it up.
2. Something below `sshd` — the kernel's connection tracking, a resource limit, or an edge firewall — is accepting the handshake and then black-holing everything after it, for every process on the box, not just `sshd`.

Because a plain `nc` client (not SSH, not VS Code, no client config at all) reproduces the exact same hang, every client-side and SSH-application-layer theory is ruled out. This is why attempts 1, 3, and 4 — all of which changed SSH or client behavior — could not have fixed it.

## Ranked hypotheses

### 1. `sshd` resource exhaustion from repeated connection churn (most likely)

Each abrupt Wi-Fi drop leaves behind connections that were never cleanly authenticated or closed. If these aren't reaped promptly — because of a bug, a wedged parent process, or genuinely resource-starved forking — they can accumulate across repeated drop/reconnect cycles (which VS Code's multiplexed connections make worse, since each reconnect opens many sockets at once). Eventually `sshd` can hit a real ceiling: no free file descriptors, no free PIDs, or `MaxStartups`' `full` threshold.

This directly matches the confirmed `sshd_config` behavior: past the `full` value in `MaxStartups start:rate:full` (default `10:30:100`), **all further connections are dropped with no response at all** — no banner, no rejection message, nothing. That is exactly the observed symptom. Attempt 1 raised the numbers (`50:30:100` → `100:30:150`) but didn't address whatever is causing the pile-up in the first place, so a bigger ceiling just delays the same failure rather than preventing it.

**What would confirm this:** zombie/defunct `sshd` child processes visible in `ps auxf` at the time of failure, and/or `sudo systemctl restart ssh` alone (without a full VM reboot) fixing the hang.

### 2. Kernel-level connection tracking (`nf_conntrack`) exhaustion

If the `nf_conntrack` table fills up — plausible on a small VM under repeated connection churn — new connections can complete a handshake at the kernel level but never get their packets forwarded to any listening process, system-wide. This would explain why even `nc`, a totally unrelated process, fails identically: the block isn't specific to `sshd` at all.

**What would confirm this:** `dmesg` showing `nf_conntrack: table full, dropping packet` around the time of failure, or `nf_conntrack_count` sitting at or near `nf_conntrack_max` when the VM is unreachable.

### 3. Memory or disk exhaustion

If the VM runs low on memory (e.g. a slow leak, or log growth filling disk), `sshd`'s fork-per-connection model can fail the same way as hypothesis 1 — but for a different underlying reason, and with a different fix (add swap/memory, rotate logs, alert on disk usage) rather than an SSH-specific one.

**What would confirm this:** `free -h` showing near-zero available memory, `df -h` showing a full filesystem, or `dmesg` showing OOM-killer activity at the time of failure.

## Why "just reboot" always "fixed" it — and why that's misleading

A full reboot resets PIDs, clears memory pressure, and flushes the `nf_conntrack` table. That's true regardless of which of the three hypotheses above is correct — so the fact that rebooting has worked every time gives **no information** about which one it actually is. It has looked like each SSH-layer config change "should" have helped, and then a reboot happened anyway before anyone could tell whether the config change mattered or the reboot did all the work. That ambiguity is exactly what [`runbook.md`](runbook.md) is designed to remove.
