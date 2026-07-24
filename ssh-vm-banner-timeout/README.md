# SSH Banner Exchange Timeout — Dev VM Incident

## Overview

This documents an ongoing, unresolved issue on the `dev` VM (Hetzner, `178.104.35.30`, Debian 13): whenever the client laptop's Wi-Fi drops and reconnects, SSH connections to the VM start failing with `Connection timed out during banner exchange`, and the only recovery so far has been a full reboot of the VM via the cloud console. Four rounds of fixes were attempted before this session, all at the SSH application layer (VS Code multiplexing tuning, systemd socket activation, client `ControlMaster`, MTU/proxy settings) — all failed, and each failure was "fixed" by rebooting, which destroyed the evidence needed to actually diagnose it. This folder exists so the next occurrence gets diagnosed instead of just rebooted away, and so nobody re-tries a fix that's already been ruled out. Status as of writing: **not fixed, not yet root-caused** — the fix depends on data that can only be captured out-of-band the next time the VM breaks.

## Table of Contents

- [Overview](#overview)
- [Contents](#contents)
- [The one rule that matters](#the-one-rule-that-matters)

## Contents

- [`timeline.md`](timeline.md) — chronological log of every fix attempted so far, the theory behind each, and why it failed. Read this before trying anything new, so it isn't repeated.
- [`configs.md`](configs.md) — before/present snapshots of every config file touched (`sshd_config`, systemd unit state, client `~/.ssh/config`, `~/.bashrc`).
- [`analysis.md`](analysis.md) — the technical reasoning for why the SSH-layer fixes were the wrong target, and the ranked hypotheses for what's actually happening.
- [`runbook.md`](runbook.md) — **the actual next step.** A concrete, ordered list of commands to run over the Hetzner out-of-band console the next time this breaks, *before* rebooting.

## The one rule that matters

**Do not reboot the VM when this happens again until the `runbook.md` steps have been run.** Every prior incident was destroyed by an immediate reboot before anyone could look at the system in its broken state. Without that evidence, this will keep going in circles indefinitely.
