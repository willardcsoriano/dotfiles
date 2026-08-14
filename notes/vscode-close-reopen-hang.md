# VS Code "Close/Reopen" Hang Loop

## Overview

On mba15, VS Code's window can wedge into an unresponsive state — surfaced as an OS-level dialog offering only "Close" or "Reopen" — and simply reopening the app does not resolve it, because the crashed session leaves behind a stale singleton lock file and stale IPC sockets. Every relaunch finds that stale state, tries to hand off to what looks like a still-running instance, and wedges the same way. The fix is a `reset-vscode` alias (`scripts/reset-vscode.sh`, installed to `~/.local/bin` via `install.sh`) that kills any lingering local VS Code processes, removes the stale lock and sockets, and relaunches. This incident (2026-08-14) also happened to follow a system reboot triggered by an unrelated network drop during a passkey login attempt — see [Timeline](#timeline) for how the two connect.

## Table of Contents

- [Overview](#overview)
- [Timeline (2026-08-14, incident)](#timeline-2026-08-14-incident)
- [Fix](#fix)
- [Caveats](#caveats)

## Timeline (2026-08-14, incident)

- **13:59** — System rebooted. Trigger: attempting a passkey login, the internet connection dropped mid-flow; rebooting was the fastest way to restore connectivity.
- **14:02:33** — VS Code launched normally post-reboot (`~/.config/Code/logs/20260814T140233/main.log`).
- **14:03:16–14:03:52** — A window and two extension-host processes exited cleanly — unremarkable on its own.
- **14:04:18** — `CodeWindow: detected unresponsive` — VS Code's own watchdog flags the window as hung. `main.log` stops immediately after this line; the window never recovered.
- User repeatedly closed/reopened VS Code trying to clear the dialog — it kept recurring.
- Investigation found: no `code` process running, but `~/.config/Code/code.lock` and three `vscode-*.sock` files under `$XDG_RUNTIME_DIR` were still present, timestamped to the 14:02 session. The stale lock/sockets were the reason reopening never actually resolved anything.

**Root cause of the hang loop (confirmed):** stale singleton lock file + stale IPC sockets from a crashed session prevent a clean relaunch.

**Root cause of the original hang (unconfirmed, plausible):** `main.log` has no explicit passkey/WebAuthn evidence, so the causal link to the passkey login attempt is circumstantial, not proven — but the timing (reboot to fix network → VS Code opened 3 minutes later → hang 2 minutes after that) is consistent with an auth-related flow blocking on a network call that never returned. Not investigated further since the practical fix (clearing stale lock state) doesn't depend on knowing the original trigger.

## Fix

`scripts/reset-vscode.sh`, installed as `reset-vscode`:

```sh
reset-vscode                # kill, clean up stale lock/sockets, relaunch
reset-vscode --no-relaunch  # same cleanup, skip the relaunch
```

What it does:
1. `pkill -9 -f "/usr/share/code/code"` — kills any lingering local VS Code processes (main + renderer + extension host all share this binary path in argv).
2. Removes `~/.config/Code/code.lock`.
3. Removes `vscode-*.sock` under `$XDG_RUNTIME_DIR` (falls back to `/run/user/$(id -u)`).
4. Relaunches `code` in the background, detached from the shell.

This is the local-desktop counterpart to `fix-ssh --vscode`, which only ever touched the *remote* vscode-server process on an SSH host — it does not address this local hang at all.

## Caveats

- `pkill -f "/usr/share/code/code"` matches on the installed binary path for the Microsoft `.deb` package. If VS Code is ever installed a different way (snap, flatpak, custom prefix), this pattern needs updating.
- This clears state; it does not diagnose *why* a given hang happened. If hangs become frequent, the next step would be watching `~/.config/Code/logs/*/window*/exthost/*.log` for the specific extension or operation stalling at the "detected unresponsive" timestamp.
