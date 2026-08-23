# SESSION.md

## Overview

This is the living snapshot for `dotfiles`, willard's personal config repo for the `mba15` laptop, plus the incident-response tooling it hosts for a separate Hetzner VM (`dev`) it doesn't provision. As of 2026-08-22, the most recent working session diagnosed and hardened two separate, coincidentally-overlapping failures triggered by the same evening's wifi instability: a local wifi driver lockup on `mba15` that forced a full machine restart, and a `vscode-server` process pileup on `dev` that reached crisis-level load (~95 on an 8-core box) inside an hour — faster than the existing 24-hour reaper could ever catch. Both got automated, self-healing fixes rather than one-off manual patches, and a related investigation found `dev`'s memory pressure was being driven by an explicitly-unsupported ("DO NOT USE," per its own maintainers) Salesforce VS Code extension, not genuine hardware undersizing. This file describes where things stand right now — read this first to resume; git history and the linked docs have full detail.

## Table of Contents

- [Overview](#overview)
- [Current status (2026-08-22)](#current-status-2026-08-22)
- [What happened this session, in order](#what-happened-this-session-in-order)
- [Key decisions in force (don't re-litigate without reading why)](#key-decisions-in-force-dont-re-litigate-without-reading-why)
- [Open questions / needs a decision](#open-questions-needs-a-decision)
- [How to resume](#how-to-resume)

## Current status (2026-08-22)

**Blocking issue found while wrapping up, unrelated to this session's actual work — read this first:** local `master` and `origin/master` have diverged (21 local-only commits, 11 origin-only commits), and it is **not cosmetic** — `origin/master` on GitHub is missing real content that exists locally: `scripts/check-dev.sh`, `scripts/fix-wifi.sh`, `scripts/reset-vscode.sh`, the `ssh-control-reset` sleep hook, `ssh-vm-banner-timeout/tmux.conf`, and several incident notes. Something either never got pushed, or the remote was reset/force-pushed at some point. **This needs your judgment before any further pushing to this repo** — see "Open questions" below. Nothing was force-pushed or reset by this session; it was left exactly as found.

**Two feature branches, both locally committed, neither pushed:**
- `feat/wifi-radio-reset-watchdog` (5 commits) — wifi driver-lockup hardening, `check-dev` fix, `recon`, the fast orphan-aware `vscode-server` reaper, and README documentation.
- `docs/update-session-snapshot` (this file) — not pushed either, pending the divergence above being sorted out first.

**What's live and already deployed** (independent of any unpushed commit — all verified working):
- `mba15`: `wifi-watchdog` running as a systemd `--user` service, `recon`/`check-dev`/`fix-wifi`/`reset-vscode` all in `~/.local/bin`.
- `dev` (Hetzner, `178.104.35.30`, `nbg1`): `vscode-server-reap-orphans.timer` running every 2 minutes; Hetzner Cloud Firewall `dev-baseline-match` attached (mirrors UFW's 22/80/443+ICMP policy); `salesforce.apex-language-server-extension` uninstalled; `wfmctrading`'s three containers (`nginx`, `app`, `postgres`) currently **stopped**, ahead of a not-yet-executed migration.

**A separate repo also has uncommitted docs work:** `debian-server-baselines`, branch `docs/hetzner-cloud-firewall-and-migration`, 1 commit (Hetzner Cloud Firewall + a full snapshot-based migration runbook for moving `dev` from `cx43`/Nuremberg to `cx53`/Helsinki). Not pushed.

## What happened this session, in order

1. **`mba15` wifi driver lockup (2026-08-21 evening).** Internet cut out, didn't recover, forced a full machine restart. `journalctl` analysis (read via the user running `sudo` commands themselves and pasting output back, since `willard` isn't in `systemd-journal`) found `wpa_supplicant: Association request to the driver failed` on every attempt for 5 minutes straight, against two *unrelated* networks (home wifi and a phone hotspot) — ruling out the AP/ISP and pointing at the wifi driver/firmware itself being wedged, one layer below what the existing `fix-wifi` (connection-profile disconnect/reconnect) could reach. Fix: `fix-wifi --radio` (radio power-cycle via `nmcli radio wifi off/on`) plus `wifi-watchdog`, a systemd `--user` service that detects the pattern and self-heals automatically. Full writeup: `notes/wifi-driver-lockup-2026-08-21.md`.

2. **Built `recon`**, a single offline diagnostic covering wifi, SSH `ControlMaster`, VS Code lock state, and `dev`'s health in one pass — built specifically because the wifi incident above included a stretch where there was no way to ask anything what to run. Discovered and fixed a real bug in `check-dev.sh` along the way: its final `if`/`fi` always returned exit code 0 even when it found a real problem (bash doesn't propagate a false condition's exit status through an unmatched `if`), which would have made `recon` silently miss real findings.

3. **`dev` memory investigation.** `recon` surfaced `dev` at ~99% of its `user-1000.slice` memory ceiling. Root-caused to `salesforce.apex-language-server-extension` — a separate, early-stage TypeScript rewrite of the Apex language server (distinct from the mature Java-based one), using 1.4-2.4GB *per open VS Code window*. Its own upstream repo (`forcedotcom/apex-language-support`) states "experimental - DO NOT USE." Updated 0.8.0→0.10.0, capped `apex.experimental.workers.poolSize` to 1, then uninstalled entirely once confirmed via `extensionDependencies` inspection that nothing else in the Salesforce extension pack requires it.

4. **Audited `dev`'s OS-level hardening** (from the separate `debian-server-baselines` repo's `debian-server-baseline.sh`) — confirmed genuinely solid via direct verification, not just checking config files: UFW, fail2ban, auditd, AIDE, SSH lockdown (`PermitRootLogin no`, key-only, `MaxAuthTries 3`) all live, and external `nc` testing from `mba15` confirmed UFW is actually enforcing its policy (not just configured on paper). The real gap found: no matching **Hetzner Cloud Firewall** — a second, network-edge enforcement layer independent of the VM's own OS. Created `dev-baseline-match` (22/80/443 TCP + ICMP inbound, mirrors UFW exactly) via `hcloud`, verified live before and after with external port tests.

5. **Researched a `dev` upgrade** (`cx43`/16GB/Nuremberg → `cx53`/32GB/Helsinki, €18.49→€34.99/mo — the best €/GB ratio in Hetzner's entire catalog, confirmed via a full price-grid comparison across every server type and location, including US/Singapore, which turned out **not** to be cheaper since Hetzner's cheapest line isn't offered there at all). `cx53` is only orderable in Helsinki, not `dev`'s current Nuremberg datacenter — confirmed via the live API, and separately confirmed via Hetzner's own FAQ that snapshot-based cross-location server creation is explicitly unrestricted (an initial misreading of "same network zone" language was corrected after directly fetching the source). Full step-by-step, including the "stop containers cleanly first" shortcut that avoids needing a `pg_dumpall`/restore dance, is in `debian-server-baselines/docs/HETZNER-CLOUD.md`.

6. **A real live incident during the investigation itself.** Switching wifi networks on `mba15` while 3 VS Code windows were open to `dev` triggered a genuine `vscode-server` pileup — swap 100% full, 1-minute load average ~95 on an 8-core box — inside about an hour. The user ran `fix-ssh --vscode dev` to recover; all 4 `tmux` sessions (`sbintern-agent1`, `sbintern-agent2`, `thesis-1`, `wfmc-1`) and the agents inside them survived untouched, validating the 2026-08-17 decision to isolate agent CLI sessions in `tmux`. Root-caused to a known, still-open VS Code Remote-SSH upstream bug that doesn't always clean up server-side process trees on a bad reconnect (`microsoft/vscode-remote-release#262`).

7. **Built the actual fix: `reap-vscode-orphans.sh`.** Runs every 2 minutes on `dev`, kills only `vscode-server` trees whose top-level launcher process has been reparented to PID 1 — provable, unambiguous evidence the parent SSH session has already died (a live session's tree always has a real `sshd`-descended parent). Unlike `fix-ssh --vscode`, this cannot misidentify a live session as orphaned, so it's safe to run unattended and frequently — closing the specific gap the existing 24-hour age-based reaper (`reap-vscode-server.sh`) was never designed to catch. Verified live: correctly ignored a freshly-reconnected window while the crisis was still being investigated.

8. **Proposed, then reverted, disabling `ControlMaster` for `dev`.** The theory (splitting 3 windows onto independent connections would reduce blast radius from a network blip) didn't survive contact with `ssh-vm-banner-timeout/self-healing.md`'s own existing documentation: `ControlMaster` was deliberately *re-added* on 2026-07-29 after being removed on a since-disproven theory, and each window already runs an independent server-side process tree regardless of client-side connection sharing — so splitting connections wouldn't have changed how many windows disconnected simultaneously during a full wifi-interface switch. Documented as a "red herring" in the incident file specifically so it doesn't get re-proposed from scratch next time.

## Key decisions in force (don't re-litigate without reading why)

- **`ControlMaster` stays enabled for `dev`.** See point 8 above — a real prior decision, re-confirmed after almost being reversed on incomplete information.
- **`reap-vscode-orphans.sh` runs *alongside*, not instead of, `reap-vscode-server.sh`.** Different failure speeds: minutes (a single bad reconnect) vs. hours/days (slow accumulation, e.g. from a version-mismatched client auto-update).
- **`wifi-watchdog` deliberately does not escalate beyond a radio reset** — no driver module reload, no auto-reboot. If a radio reset doesn't clear a lockup, it just notifies and waits for the next cooldown window rather than acting further. User's explicit choice.
- **`apex-language-server-extension` was uninstalled, not just disabled** — confirmed safe via its `extensionDependencies` graph (soft `extensionPack` member only, nothing hard-depends on it), and its own repo's "DO NOT USE" made the stronger action the easy call.
- **The `cx53`/Helsinki migration is documented but intentionally not executed.** The `dev` memory crisis turned out to be extension-driven (killing only `vscode-server` processes, with Docker already stopped, dropped usage from 13GB+/swap-full to 2GB used almost instantly) — not proof of genuine hardware undersizing. Recommended holding off and monitoring real usage for a few days post-uninstall before committing to a recurring cost increase.

## Open questions / needs a decision

1. **The `master`/`origin/master` divergence (see "Current status" above) — needs your judgment, not an automated fix.** Before pushing anything else to this repo: decide whether local `master`'s extra content should be pushed to origin (likely correct, given it's real, substantial, working code), or whether there's a reason origin was intentionally reset that local doesn't know about. Once resolved, `feat/wifi-radio-reset-watchdog` and `docs/update-session-snapshot` (this file) both need pushing and PRs opened.
2. **Should the `cx53`/Helsinki migration proceed?** Plan is ready in `debian-server-baselines/docs/HETZNER-CLOUD.md`. Recommended waiting for a few days of post-uninstall monitoring first — your call.
3. **`wfmctrading`'s containers are stopped on `dev`** — bring back up with `docker start wfmctrading-postgres-1 wfmctrading-app-1 wfmctrading-nginx-1` whenever needed; they were stopped deliberately ahead of the (not-yet-executed) migration snapshot, not due to a failure.
4. **`STATE.md` has a large, pre-existing uncommitted change from a prior session** (not this one) that flags `RESEND_API_KEY`/`BETTER_AUTH_SECRET` for `turtley` as possibly leaked into a transcript and recommended for rotation — surfaced during this session's commit cleanup, still needs attention, entirely unrelated to tonight's work.
5. **`debian-server-baselines`' branch also needs pushing/a PR**, independent of question 1 (that repo's remote wasn't checked for the same divergence issue — worth a quick `git status`/`git log master..origin/master` there before pushing, given what was just found here).

## How to resume

- Run `recon` on `mba15` first — it checks wifi, SSH, VS Code lock state, and `dev`'s health in one pass and tells you what (if anything) needs attention.
- `dev`'s current mitigations: `systemctl list-timers vscode-server-reap-orphans.timer` (should show ~2min out), `hcloud firewall describe dev-baseline-match` (should show 22/80/443+ICMP).
- Full incident/mitigation history: `ssh-vm-banner-timeout/self-healing.md` (status of every live mitigation) and its linked per-incident files.
- Migration runbook: `debian-server-baselines/docs/HETZNER-CLOUD.md`.
- Nothing local (on `mba15` itself) needed stopping at the end of this session — no dev servers or Compose stacks for this repo were running.
