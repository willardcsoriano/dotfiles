# Incident: Wifi Failover to a Phone Hotspot Blocked the Fix for a Recurring `vscode-server` Pileup (2026-09-29)

## Overview

Four days after `incident-2026-09-25-vscode-orphan-pileup-dev.md` cleared a `vscode-server` orphan pileup on `dev`, the same mechanism recurred (oldest stale session ~89h old), diagnosed the same way via `recon`. This time the standard fix couldn't be applied: partway through the session, the client machine's wifi dropped off `Soriano_Home` and NetworkManager auto-failed-over to a saved phone-hotspot profile (`W's Galaxy A14`), and `fix-ssh --vscode dev` then failed with the now-familiar `Connection timed out during banner exchange`. A comparative reachability test confirmed this is the same client-network port-22 filtering mechanism documented four times previously in this directory (mechanism 5) — `dev` itself is healthy and reachable on other ports — but this occurrence adds a new piece of evidence: a raw TCP connection to port 22 completes its three-way handshake successfully, then the SSH banner simply never arrives. As of this writing the mechanism-2 pileup fix is still blocked pending a network change; no VM-side problem exists.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis](#diagnosis)
  - [Why the wifi dropped mid-session](#why-the-wifi-dropped-mid-session)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

Mid-session, `fix-ssh --vscode dev` was run again (this directory's standard reap command) and failed immediately with a banner-exchange timeout, the same symptom `incident-2026-09-04-mobile-hotspot-ssh-block-premature-hard-reset.md` and others in this directory have already tied to client-side network filtering rather than a VM problem. Before assuming that conclusion, `recon` was run first to check what state `dev` was actually in.

`recon` reached `dev` successfully at that point (a separate, still-live SSH path — see below) and reported:

```
docker.service restarts : 0
RAM used                 : 6121Mi / 15620Mi
swap used                : 3656Mi / 4095Mi (89%)
user-1000.slice          : 56% of MemoryHigh ceiling
load average (1m)        : 0.09
open vscode windows      : 0 (extensionHost count)
oldest vscode session    : ~89h old
```

An oldest session of ~89 hours (roughly the time elapsed since the 2026-09-25 fix) matches the orphaned-session pileup signature (mechanism 2) exactly — a genuine, real recurrence, not a misdiagnosis. `recon` also flagged a stale local VS Code lock (`pid 190598 not running`), unrelated to `dev` itself, which was cleared first with `reset-vscode`.

## Diagnosis

Checking the active network connection at the time of the failed `fix-ssh` explained the discrepancy between `recon`'s successful connection and the failed one: `nmcli device status` showed the client on `W's Galaxy A14`, a saved phone-hotspot profile (autoconnect enabled, one of many saved networks including `Soriano_Home`), not the home wifi network. The wifi had evidently dropped off `Soriano_Home` at some point mid-session and NetworkManager silently failed over to the next available saved, autoconnecting profile — a phone tether.

### Why the wifi dropped mid-session

`sudo journalctl -u NetworkManager -u wpa_supplicant --since -2h` (run manually; the assistant isn't in `systemd-journal`) surfaced two separate, unrelated events, not one:

1. **14:19:06–08 — `wifi-watchdog` self-healing, working as designed.** A resume-from-suspend at 14:19:05 left the wifi device stuck disconnected for ~60s, which is exactly what `scripts/wifi-watchdog.sh`'s poll loop (`FAILURE_THRESHOLD=6` × `POLL_INTERVAL_SECONDS=10`) watches for. It ran `fix-wifi --radio` automatically — the journal shows `rfkill: WLAN soft blocked` at 14:19:06 followed by `wireless-enabled:on` exactly 2 seconds later at 14:19:08, matching `fix_radio()`'s `nmcli radio wifi off; sleep 2; nmcli radio wifi on` precisely. This is the documented mechanism from `project_wifi_driver_lockup`, not a fault.
2. **14:31:30–14:31:51 — a full system reboot, then a 5.5-minute hardware radio block.** The service log shows a clean `NetworkManager`/`wpa_supplicant` shutdown and full device re-enumeration on restart (`Boot 54d5964a...`), not a crash. A `pkexec` root session opened for `<user>` at 14:31:27, 3 seconds before the shutdown sequence began — consistent with a locally-authenticated, user-initiated reboot (e.g. the XFCE session menu), not anything remote. On boot, NetworkManager logged `rfkill: Wi-Fi disabled by radio killswitch; disabled by state file` — the *hardware* killswitch, one layer below NetworkManager's own software toggle — and wifi stayed off until `<user>` (uid=1000) manually re-enabled it at 14:37:13, 5.5 minutes later. Confirming this against `dmesg` wasn't possible (`kernel.dmesg_restrict` blocks it without root), but the NetworkManager-level evidence alone is enough to place this as a cold-boot hardware-rfkill default on this machine's wifi chipset, not user action or tampering.

Once wifi was re-enabled, NetworkManager's `policy: auto-activating connection` picked `W's Galaxy A14` over `Soriano_Home` because both are saved with identical `autoconnect-priority` (0) — see the priority-fix recommendation in Open items.

A comparative reachability test, the same one used in the three prior mechanism-5 incidents, was run against the hotspot connection:

| Test | Result |
|---|---|
| `ping` to `dev`'s IP | 0% loss, 622-777ms avg (high — consistent with a cellular path) |
| TCP connect to `dev:443` | instant refused |
| TCP connect to `dev:80` | instant refused |
| TCP connect to `dev:22`, handshake only | **completes successfully** |
| TCP connect to `dev:22`, read after handshake | **no banner ever arrives — hangs until timeout** |

The last two rows are new resolution beyond prior write-ups in this directory, which only tested whether a full `connect()` succeeded or hung. Here the three-way handshake itself succeeds — proving the block isn't a wholesale SYN/packet drop — and only the follow-on application data (the SSH banner) is withheld. That's the textbook shape of payload-inspecting (DPI) filtering: it needs to see the SSH protocol banner before it can decide to block, so it lets the TCP handshake through and only then withholds data. This sharpens, but doesn't change, the standing carrier-DPI theory from `incident-2026-08-12-company-wifi-blocked-dev.md` onward.

Ping clean and 443/80 both instantly refused (proving `dev` is alive and responsive to any traffic that reaches it) rules out a VM-side cause, same as every prior occurrence of this mechanism.

## Fix

**Unresolved as of this writing.** No VM-side or client-side fix exists for the network filtering itself — every prior occurrence (2026-08-12, 2026-08-24, 2026-09-04) was only resolved by switching off the filtering network. The underlying mechanism-2 pileup fix (`fix-ssh --vscode dev`) is ready to re-run the moment the client is back on a network that doesn't filter port 22; it isn't itself the blocker.

## Open items

- **Fourth occurrence of client-network port-22 filtering** (2026-08-12 company Wi-Fi, 2026-08-24 and 2026-09-04 mobile carriers, now this hotspot), and the second time it has arrived stacked on top of a real, independently-confirmed mechanism-2 pileup rather than being mistaken for one. The Tailscale/WireGuard overlay-tunnel recommendation, carried forward unimplemented from three previous incidents, is now overdue.
- **`Soriano_Home` and every other saved wifi profile, including phone hotspots, share the same `autoconnect-priority` (0).** This is what let NetworkManager pick `W's Galaxy A14` over home wifi once the radio came back — not a fault, but not desired either. Recommended fix: give `Soriano_Home` an explicit higher `connection.autoconnect-priority` so NM strongly prefers it over any saved hotspot whenever both are in range. Not yet applied — pending a go-ahead.
- **The mechanism-2 pileup recurred only ~89 hours (under 4 days) after the last fix**, materially faster than earlier occurrences. Worth tracking whether the recurrence interval is genuinely shortening or this is noise from two data points.
- **Fourth occurrence of client-network port-22 filtering** (2026-08-12 company Wi-Fi, 2026-08-24 and 2026-09-04 mobile carriers, now this hotspot), and the second time it has arrived stacked on top of a real, independently-confirmed mechanism-2 pileup rather than being mistaken for one. The Tailscale/WireGuard overlay-tunnel recommendation, carried forward unimplemented from three previous incidents, is now overdue.

**Resolved during write-up, not left open:**
- The `*:80` listener flagged during this session's unrelated security check is `apache2` (confirmed via `sudo ss -tlpn`, 6 worker processes) — not Docker, not evidence of compromise, just an installed local service. Whether it's supposed to be running is a config question for the user, not a security finding.
- A broader local intrusion check (active sessions, login history, listening ports, `authorized_keys`, cron, top processes) during the same session found nothing anomalous — one active session (the user's own, freshly started), no unexpected persistence mechanisms.
