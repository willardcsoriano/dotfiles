# Project State

## Overview

This is willard's personal dotfiles repo for the `mba15` laptop (Debian/Ubuntu XFCE, X11) — touchpad fixes, VS Code settings, and `install.sh` for both curl-based and local setup. As of 2026-07-24, the repo also hosts `ssh-vm-banner-timeout/`, a documentation folder for a live SSH-connectivity incident on a separate remote Hetzner VM (`dev`, unrelated infrastructure, not managed by this repo's `install.sh`). That incident was actively diagnosed and partially fixed this session: root cause confirmed (a Docker container health-check failure cascading into an OOM-killed, crash-restart-looping `docker.service` that starved the whole VM, including `sshd`), two of several planned mitigations shipped (swap added, dead containers pruned), and a `Makefile` added for fast recovery next time. This file is the living snapshot — read this first to resume; git history and the docs in `ssh-vm-banner-timeout/` have the full detail.

## Table of Contents

- [Overview](#overview)
- [What this repo is](#what-this-repo-is)
- [Current status (2026-07-24)](#current-status-2026-07-24)
- [How to resume](#how-to-resume)
- [Decisions in force](#decisions-in-force)
- [Open questions](#open-questions)

## What this repo is

- `install.sh` — curl-able or local installer: touchpad libinput fixes (incl. the post-resume `Device_Enabled=0` bug), VS Code Remote-SSH keep-alive settings merge.
- `xorg.conf.d/`, `etc/` — touchpad/xorg config fragments installed by `install.sh`.
- `vscode/settings.json` — the two Remote-SSH keys (`connectTimeout`, `useLocalServer`) merged into the user's real `settings.json` by `install.sh`.
- `notes/` — one-off technical write-ups (currently: the VS Code Shift+Enter terminal fix).
- `ssh-vm-banner-timeout/` — incident documentation for the `dev` VM issue (see below). Not something `install.sh` touches; it's reference/runbook material, plus a `Makefile` for live recovery.

## Current status (2026-07-24)

**Repo housekeeping (this session):** three pending, unrelated change sets already existed in the working tree from prior sessions; each was split onto its own branch, PR'd, and merged into `master`:
- `feat/vscode-remote-ssh-keepalive` (PR #1) — the VS Code Remote-SSH settings feature.
- `docs/vscode-shift-enter-fix-rewrite` (PR #2) — replaced the concise Shift+Enter note with the fuller troubleshooting write-up.
- `docs/ssh-vm-banner-timeout-incident` (PR #3) — created the `ssh-vm-banner-timeout/` folder.

All three are merged; local `master` is up to date with `origin/master`.

**The `dev` VM incident** — root cause confirmed, not fully hardened:
- **Root cause:** a Docker container health check (`pg_isready` on two long-running Postgres containers) started failing → containers got stuck mid-teardown → rootless `docker.service` was OOM-killed → systemd's restart kept re-hitting the same failure → the resulting crash-restart loop pegged CPU (~600-800%) and disk reads (~1GB/s) for over an hour → the whole VM was starved, including `sshd` (which is why SSH could complete a TCP handshake but never send its banner — SSH itself was never the actual problem).
- **What triggered the memory pressure in the first place is still unproven.** Leading theory: ~10-15 concurrent SSH-backed connections (4 VS Code Remote-SSH windows × 2-3 terminals each, each window running its own `vscode-server` + extension-host tree) stacking on top of the running containers, on a box that had zero swap at the time. Plausible, consistent with all evidence gathered, but not provable after the fact — the per-process memory snapshot from that exact moment was never captured and can't be reconstructed.
- **Fixed this session:** 4GB swapfile added and persisted (`vm.swappiness=10`); 24 months-old dead containers (`erpnext-distribution-*`, `frappe_docker-*`) pruned; a client-side `IPQoS 0x00` syntax bug (broke the local SSH client entirely, unrelated to the VM issue) fixed to `IPQoS 0`; a redundant duplicate `Host dev` block across `~/.ssh/config` and `~/.ssh/config.local` cleaned up; a duplicated `ssh-agent` startup block in `~/.bashrc` deduplicated.
- **Not yet fixed:** Postgres health-check/restart resilience (still `unless-stopped` with a tight `pg_isready` timeout — a bad blip can still cascade), no per-container memory limits (still `MemoryMax=infinity` everywhere checked), and the trigger itself is unconfirmed.
- Full ranked writeup, evidence, and the "what's confirmed vs. still open" honesty check: `ssh-vm-banner-timeout/analysis.md`.

## How to resume

- **If the VM breaks again:** `cd ssh-vm-banner-timeout && make recover` — one command, does everything (checks if SSH is already back up, tries a live no-reboot password reset, escalates to soft reboot then hard reset only as needed, then automatically captures a postmortem to `~/vm-incident-logs/`). `make check` and `make postmortem` are safe/read-only if you just want to look. Requires `hcloud` CLI with the `willard-mba15` context (the `dev` server lives there, not the default-active context).
- **If a fix needs `sudo` on the VM:** it can't be run through a non-interactive SSH command — SSH in yourself and run it there so you enter the password locally.
- **Docs to read, in order:** `ssh-vm-banner-timeout/README.md` (index) → `analysis.md` (root cause + what's still open) → `timeline.md` (full chronological log, so nothing already-ruled-out gets retried) → `configs.md` (current config snapshots) → `runbook.md` (the manual version of what `make recover` automates).

## Decisions in force

- `full-faulty-conversation.md` (repo root, gitignored, untracked) is the complete raw transcript of an earlier troubleshooting session with a different AI assistant (Gemini) — kept **private on request**, not folded into `ssh-vm-banner-timeout/` docs, not committed. Added to `.gitignore` this session so it doesn't get swept into a future `git add -A` by accident.
- Commits go one-concern-per-commit, Conventional Commits style, no AI attribution — matches the global convention already in force for this repo; the three-branch PR workflow this session is the model to repeat for future unrelated changes.
- Never push or restart/reset the VM without explicit confirmation each time — this was followed strictly this session (asked before the hard `hcloud server reset`, before pushing/merging PRs).

## Open questions

- What actually triggered the 05:56 UTC memory spike on 2026-07-24 — best-fit theory (concurrent VS Code windows) is unconfirmed. Next occurrence: capture `ps aux --sort=-%mem` or a live `netdata` per-process view *during* the incident, not after.
- Whether this same Docker/OOM cascade explains the four-to-five earlier SSH-banner-timeout incidents (before this session) — only the most recent prior boot's journal was checked.
- Whether to implement the remaining fixes (health-check resilience, per-container memory limits) directly via SSH again, or through the separate "debian-server-scripts" repo that otherwise manages this VM's hardening — not decided; last time the user chose "SSH in directly now" for the swap/prune fixes.
