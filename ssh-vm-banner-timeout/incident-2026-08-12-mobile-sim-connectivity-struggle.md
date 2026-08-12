# Incident: Mobile SIM Struggled to Reach `dev` Specifically, Resolved by Switching Carriers (2026-08-12, later same day)

## Overview

Later the same day as the company-Wi-Fi incident, `ssh dev` started failing again — this time from mobile data ("Magic Data," a Smart Communications prepaid plan) tethered over a phone hotspot. The pattern echoed the company-Wi-Fi incident almost exactly: `dev`'s IP specifically saw heavy packet loss (40-83%) and high, jittery latency while a comparison host (GitHub) on the same connection at the same moment saw 0% loss — a destination-specific problem, not a broadly broken connection. Several things were checked and ruled out along the way (compromise, the local Wi-Fi hop, a signal-tier theory that turned out to be unobserved rather than real), a VM reboot was performed at the user's request but confirmed not to be the actual fix, and a genuine fallback (Hetzner's browser-based console) was discovered for future use. The connection cleared up entirely after switching to a different carrier's hotspot (Globe), with `dev` on a like-for-like footing with GitHub again.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Ruled out: compromise](#ruled-out-compromise)
- [Ruled out: the local Wi-Fi hop](#ruled-out-the-local-wi-fi-hop)
- [Not the actual cause: signal-tier throttling](#not-the-actual-cause-signal-tier-throttling)
- [Side action: VM reboot (requested, confirmed not the fix)](#side-action-vm-reboot-requested-confirmed-not-the-fix)
- [Discovered: Hetzner's browser-based console as an SSH-independent fallback](#discovered-hetzners-browser-based-console-as-an-ssh-independent-fallback)
- [Client-side hardening applied: `ConnectionAttempts`](#client-side-hardening-applied-connectionattempts)
- [Root cause: same destination-specific degradation pattern, different network](#root-cause-same-destination-specific-degradation-pattern-different-network)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

`ssh dev` began failing with `Connection timed out`, `Connection timed out during banner exchange`, and eventually `Shared connection to 178.104.35.30 closed` — all while tethered to a phone hotspot on a Smart Communications ("Magic Data") SIM. Failures persisted for over 30 minutes, ruling out a momentary blip.

## Ruled out: compromise

Given repeated, varied-looking failures, the question came up directly: could this be a MITM or account compromise rather than a network problem? Checked `known_hosts` for `dev`'s cached key and confirmed no `"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"` across roughly a dozen connection attempts (by the user and in diagnosis) that evening. That warning is the actual tell for impersonation/key-swap; its absence, combined with every failure mode observed being consistent with ordinary packet loss and timeouts, ruled this out.

## Ruled out: the local Wi-Fi hop

`nmcli -f IN-USE,SSID,SIGNAL,RATE dev wifi` showed the laptop's Wi-Fi link to the phone hotspot at 100% signal, 65 Mbit/s — essentially perfect. This isolated the problem to somewhere between the phone and `dev`, not the laptop-to-phone leg.

## Not the actual cause: signal-tier throttling

Mid-diagnosis, a theory came up that the phone's signal indicator had dropped from `H` (HSPA/3G) to `E` (EDGE/2G) under high data consumption, which would fully explain the symptoms — EDGE's latency and jitter alone can blow past SSH's handshake timeout even without any loss. This was later clarified as never actually observed on the phone; it was raised as a hypothetical, not a real reading. **Recorded here so a future reader doesn't mistake it for a confirmed cause** — the real explanation turned out to be the destination-specific pattern below, not a signal-tier drop.

## Side action: VM reboot (requested, confirmed not the fix)

The user asked to reboot `dev` via `hcloud server reboot dev` and inspect logs once back up, reasoning the containers running on it weren't in active use and all real work was already saved via git. Pushed back first — the evidence pointed at a client-side network problem, and `dev` had been confirmed healthy (load 0.06-0.39, no OOM, `docker.service` stable for 12+ days) throughout, so a reboot seemed unlikely to fix anything and would briefly disrupt the `wfmctrading` containers for no diagnostic gain. Proceeded once the user confirmed they understood the tradeoff.

The reboot itself went cleanly: `dev` was back within ~2 minutes, `docker.service` active, load 0.02 (idle) afterward. But it did **not** restore connectivity on its own — SSH continued to fail intermittently on the same Smart SIM connection after the reboot, confirming the VM was never the actual blocker. (One post-reboot log-pull was attempted to look for boot-time errors but never completed cleanly, since the same flaky connection kept dropping mid-command; not pursued further once it became clear the VM side was already healthy.)

## Discovered: Hetzner's browser-based console as an SSH-independent fallback

While looking for alternatives, found `hcloud server request-console dev` — it mints a WebSocket URL + one-time VNC password for Hetzner's own browser-based console, which routes through Hetzner's infrastructure rather than the user's flaky network path to the VM's public IP. This is a genuine, reusable emergency-access path independent of whatever's wrong with SSH connectivity: open `console.hetzner.cloud` in a browser, select `dev`, click **Console**. Confirmed via `hcloud server request-console --help` that this is CLI-only-in-the-sense-of-minting-a-credential — the console itself is VNC (a graphical framebuffer + keyboard/mouse protocol), not a text stream, so there's no way to get a plain interactive shell purely through the CLI without a browser or a noVNC-capable client somewhere in the loop. No Hetzner MCP server exists in this environment either — confirmed via tool search — so this is the `hcloud` CLI's actual ceiling, not a gap filled by some other integration.

One process note: the console-request command was run directly rather than handed to the user, which put a short-lived session credential (WebSocket URL + VNC password) into the chat transcript. It wasn't reused or persisted anywhere, but per this repo's own secrets-hygiene standard, this should have been handed to the user to run themselves.

## Client-side hardening applied: `ConnectionAttempts`

Added `ConnectionAttempts 5` to `~/.ssh/config`'s `Host *` block on `mba15` (alongside the existing `ConnectTimeout 5`), so a single `ssh dev` invocation retries automatically instead of failing outright on the first dropped handshake. This is a live edit to a private, non-repo file (`~/.ssh/config` isn't tracked by `dotfiles` — same as the `ControlMaster` addition documented in `self-healing.md` item 4). Verified it doesn't break anything; did not single-handedly fix connectivity during the worst stretch of the Smart SIM's degradation (a 46-second, 5-attempt run still failed with `Connection reset` at one point), which is expected — it makes a single command more resilient to one bad attempt, not immune to a sustained bad path.

## Root cause: same destination-specific degradation pattern, different network

Comparative pings settled it, twice: on the Smart SIM, `dev` showed 40-60% loss and 330-660ms latency while GitHub (a comparably distant host) showed 0% loss at the same moment on the same connection. This is the same shape as the company-Wi-Fi incident earlier that day — `dev`'s specific IP faring worse than other distant destinations on the same network — except manifesting as heavy loss/jitter rather than an outright block. Two different networks in one day singling out `dev`'s Hetzner IP specifically is enough of a pattern to take seriously rather than write off as coincidence; see "Open items" below.

## Fix

Switching to a different carrier's hotspot (Globe) resolved it completely: 0% loss to `dev` (matching GitHub's own jitter), 5/5 raw TCP successes, `ssh dev` connecting in 4.8 seconds. Nothing on `dev`'s side or in the tooling needed to change — this was entirely about which network the traffic was leaving from.

## Open items

- **Recurring theme, now twice in one day:** `dev`'s Hetzner IP specifically underperforming relative to other distant hosts, across two unrelated networks (company Wi-Fi's hard block, this SIM's heavy loss). Worth treating as a real pattern rather than two coincidences. A Tailscale/WireGuard tunnel to `dev` remains the strongest candidate fix if this keeps recurring — it would present as overlay-network traffic rather than a raw connection to a flagged/poorly-peered Hetzner IP, sidestepping the pattern regardless of which network or carrier is in use.
- **The post-reboot boot-log pull was never completed** — not urgent, since every other check confirmed `dev` was healthy, but if a genuine reason to inspect that specific boot's logs comes up later, it hasn't been done yet.
- **`ConnectionAttempts 5`** is live in `~/.ssh/config` but not documented anywhere durable beyond this file — consider folding into `self-healing.md`'s client-side hardening list (item 4/5 area) if it proves useful going forward.
