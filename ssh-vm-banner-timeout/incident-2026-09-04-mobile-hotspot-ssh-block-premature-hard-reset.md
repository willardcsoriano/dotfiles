# Incident: Mobile Hotspot Blocked Outbound SSH to `dev`, Compounded by a Premature Hard Reset (2026-09-04)

## Overview

`dev` appeared unreachable via SSH right after a VS Code disconnect, which read as a repeat of the well-documented `vscode-server` orphan pileup (mechanism 2) and, under time pressure, was escalated straight to `make hard-reset` rather than the full graduated recovery. That escalation turned out to be unnecessary: once console access confirmed the OS had booted cleanly and a separate forgotten-password issue was resolved, SSH continued failing with the exact same banner-exchange timeout as before the reset. A side-by-side port test — port 22 hangs, port 443 gets an instant refusal, ICMP is clean — showed the VM was fully healthy and reachable the entire time. The real cause was the client machine's mobile hotspot silently filtering outbound port 22, the same family of network-level SSH block already documented in `incident-2026-08-12-company-wifi-blocked-dev.md`. A forgotten root/personal-user password and a VNC console keyboard-layout quirk were real, separate problems surfaced along the way, both resolved. Net effect: a VM-side action was taken for a client-network-side problem, for at least the third time this general pattern has appeared.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
- [Root cause](#root-cause)
- [Secondary findings along the way](#secondary-findings-along-the-way)
- [Why this looked like a VM problem](#why-this-looked-like-a-vm-problem)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

The initial report was "VM choked, wasn't able to kill vscode in time" — a reasonable first guess given this directory's history of `vscode-server` pileups. `recon` showed every local check clean (wifi, SSH ControlMaster, VS Code lock) but `dev` UNREACHABLE even to a fresh, non-multiplexed connection. `make check` pulled Hetzner's hypervisor-level CPU/network/disk metrics and they were unremarkable — not the heavy-load signature of a crash loop or active pileup — but with the VM genuinely unreachable and dev work blocked, the decision was made to skip the graduated `password-reset → soft-reboot` steps and go straight to `make hard-reset` rather than keep investigating.

## Diagnosis

Post-reset, SSH still would not come up within a normal boot window. Hetzner's API confirmed the server was `running` and not stuck mid-action, so a Hetzner web console (VNC) session was opened to see the boot state directly — it showed a normal `dev login:` prompt, meaning the OS had booted cleanly. Login attempts then failed repeatedly, initially chased as a possible VNC keyboard/typing issue before it turned out the login credentials were genuinely forgotten.

Recovered access via Hetzner's live root-password-reset API (`make password-reset`, wraps `hcloud server reset-password`) — this resets root's password through the qemu guest agent without needing SSH or a reboot. (The assistant's own attempt to run this directly was blocked by Claude Code's auto-mode safety classifier, since it resets server credentials; the user ran it manually instead.) Logged in as `root` at the console successfully, which also confirmed directly that `PermitRootLogin no` (set by this VM's `debian-server-baselines/scripts/base.sh` hardening) only affects `sshd` — local console/getty login for root is unaffected. From there, `getent group sudo` identified the personal sudo account, and `passwd <user>` reset its password; console login as that account then worked normally.

The real test — SSH from the client machine — still failed identically to before the reset (`Connection timed out during banner exchange`), which is what reframed the whole incident: the reset had changed nothing relevant.

## Root cause

Every server-side check came back clean:
- `sshd` active and listening on both `0.0.0.0:22` and `[::]:22`
- UFW: default-deny incoming, with explicit `ALLOW IN` for `22/80/443` (v4 and v6) from anywhere
- `fail2ban`: 0 currently banned (1 historical ban, already expired, from the incident's own repeated failed connection attempts)
- Hetzner Cloud Firewall (`dev-baseline-match`): rules intact — TCP 22/80/443 + ICMP inbound, `0.0.0.0/0` / `::/0`

Client-side comparative testing isolated it instead:

| Test | Result |
|---|---|
| `ping` to `dev`'s IP | 0% loss, ~230ms avg, low jitter (~3.5ms mdev) |
| TCP connect to `dev:443` | **instant "Connection refused"** (an active RST — proves packets reach the VM and it responds) |
| TCP connect to `dev:22` | hangs and times out on every attempt (3/3, no successes) |

That combination — one specific port to one specific destination consistently failing while ICMP and another port to the same host succeed cleanly — is the same signature as `incident-2026-08-12-company-wifi-blocked-dev.md`: something upstream of `dev` is filtering port 22 traffic specifically. The client machine's active connection at the time was a mobile hotspot (a phone's personal hotspot), not a normal network — consistent with a carrier-side DPI/anti-tethering filter targeting SSH protocol traffic while leaving HTTPS-shaped traffic (443) alone.

## Secondary findings along the way

- **`make password-reset` requires manual execution.** Claude Code's auto-mode classifier blocks an assistant-initiated server credential reset, by design — this is a case where that's the correct behavior, but it's worth knowing ahead of time rather than discovering it mid-incident.
- **The Hetzner web VNC console mangles piped commands.** `getent group sudo | cut -d: -f4` came back as a garbled `getent: invalid option -- 'd'` — the `|` character wasn't typed/interpreted correctly. Diagnostic one-liners had to be split into separate, pipe-free commands to work around it. Root cause (browser keyboard layout mismatch vs. a console-specific limitation) wasn't determined.
- **Multiple `make recover` / `make wait-ssh` invocations lost their tool output** to apparent session/tooling errors mid-incident, unrelated to the VM itself. Pure noise, but it added confusion and repeated re-checks during an already time-pressured recovery.

## Why this looked like a VM problem

`check-dev`/`recon`'s UNREACHABLE branch (SSH failing on both a multiplexed and a fresh connection) cannot distinguish "genuinely wedged VM" from "client-side network is filtering port 22" — both produce an identical symptom from the client's point of view. This exact gap was already flagged as an open item in `incident-2026-08-24-mobile-provider-switch-dev-latency.md`: *"a future read of this script doesn't push straight toward rebooting a VM with live agent sessions on it for a problem that isn't the VM's."* That's precisely what happened here, one step further than before — the 08-24 incident only got as far as `fix-ssh --vscode` being considered; this one went all the way through an actual `make hard-reset`, which unconditionally kills everything on the VM, including any `tmux`-hosted sessions that would have survived a real `vscode-server` pileup (mechanism 2) completely untouched. There's no way to know in hindsight whether anything was actually running that got lost — but the reset was, in retrospect, very likely unnecessary.

## Fix

No VM-side fix, same as the two prior occurrences of this pattern — switching off the mobile hotspot to a different network is the resolution. No lasting client-side mitigation exists yet for carrier-level SSH filtering.

## Open items

- **Third occurrence of network-level SSH-port filtering to `dev`** (2026-08-12 company Wi-Fi, 2026-08-24 and 2026-09-04 on two different mobile carriers), and the second time it's been misdiagnosed as a VM-side problem despite two prior write-ups warning about exactly this pattern. The Tailscale/WireGuard overlay-tunnel recommendation from both prior incidents is now overdue to actually implement rather than deferred a third time — an overlay address wouldn't carry the "raw connection to a flagged Hetzner IP" signature these networks appear to be filtering on.
- **`check-dev`/`recon`'s UNREACHABLE branch still doesn't run a comparative port/ping test before recommending VM-side recovery.** This incident's diagnosis (ping clean, 443 instant-refused, 22 hangs) took several minutes of manual investigation that a future version of `check-dev` could run automatically and report up front, before ever pointing toward `make recover`.
- **No safeguard exists against reaching `make hard-reset` before a client-network cause is ruled out.** Worth adding an explicit check to the `recover` Makefile target itself (not just documentation) requiring a clean comparative-port test before it's allowed to proceed past `soft-reboot`.
- **Both root's and the personal sudo user's console passwords were unknown at the time of this incident.** Worth deciding whether that's acceptable (console access is rare enough not to matter) or whether credentials should be stored somewhere retrievable, given this incident needed to recover both in a single session.
- **VNC console pipe-character mangling** — untested whether this is a Hetzner console limitation or a browser/keyboard-layout mismatch on the client side. Noted here so a future incident doesn't lose time rediscovering it; avoid piped one-liners on this console, prefer separate plain commands.
