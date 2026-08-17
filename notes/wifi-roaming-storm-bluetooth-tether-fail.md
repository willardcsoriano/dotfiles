# Wifi Roaming Storm + Failed Bluetooth Tether

## Overview

On mba15, home wifi appeared to "cut off and not reconnect," and a fallback attempt to switch to the phone's mobile data seemed to get overridden by the stale wifi connection. `journalctl` logs from the affected boot show neither symptom was what it looked like: wifi was actually a multi-access-point mesh network that entered a roaming storm, bouncing between at least four different radios every 30-90 seconds for six minutes and dropping the connection briefly on every hop; the "mobile data" attempt was in fact a Bluetooth tethering (NAP) connection to the phone, which failed outright with a Bluetooth I/O error before it ever came up, so wifi was never actually being chosen over it — it was the only path left. The eventual fix was a full reboot, but the logs show that was never necessary: NetworkManager and wpa_supplicant stayed healthy and kept successfully reconnecting the whole time, they just kept reconnecting to the wrong access point. A `fix-wifi` alias (`scripts/fix-wifi.sh`) now forces the same clean reconnect a reboot achieved by accident, and `fix-wifi --bluetooth` power-cycles the Bluetooth radio for the tether-failure case.

## Table of Contents

- [Overview](#overview)
- [Timeline (2026-08-17, incident)](#timeline-2026-08-17-incident)
- [Fix](#fix)
- [Caveats](#caveats)

## Timeline (2026-08-17, incident)

- **11:54:16–12:00:37** — Wifi roamed between at least four distinct access points (BSSIDs) advertising the same SSID (a home mesh network), disconnecting and reassociating roughly every 30-90 seconds. Each hop triggered a fresh DHCP negotiation and a few seconds of real outage. One hop (12:00:34) aborted on a security check — `WPA: IE in 3/4 msg does not match with IE in Beacon/ProbeResp` — because the RSN info in that mesh node's beacon didn't match what it sent during the 4-way handshake; wpa_supplicant correctly refused and retried a moment later. Not evidence of an attack, just mesh-node inconsistency.
- **12:00:14** — NetworkManager began activating a Bluetooth NAP (tethering) connection to the phone, user-initiated (`uid=1000`).
- **12:00:19** — Bluetooth tether activation failed: `bluez: NAP connect failed: GDBus.Error:org.bluez.Error.Failed: Input/output error`. The mobile-data path never came up at all.
- **12:00:28** — User manually reactivated the wifi profile (`uid=1000`) since the Bluetooth path had failed.
- **12:00:39** — Wifi settled on one access point with a working DHCP lease.
- **~12:02–12:03** — User rebooted the machine. Wifi was, at that moment, already stable.

**Root cause of the perceived "stuck on stale wifi":** the phone-tether attempt was Bluetooth NAP, not a wifi hotspot, and it failed at the Bluetooth stack level (`bluez` I/O error) before it could ever take over routing — wifi wasn't overriding a preference, it was the only functioning path.

**Root cause of the wifi instability itself:** roaming storm across mesh access points sharing one SSID. Not diagnosed further (would require RF-level investigation - signal strength per AP, mesh backhaul health) since the practical fix doesn't require knowing why the mesh nodes disagreed, only how to force a clean rejoin.

## Fix

`scripts/fix-wifi.sh`, installed as `fix-wifi`:

```sh
fix-wifi              # force a clean wifi disconnect/reconnect
fix-wifi --bluetooth  # power-cycle the Bluetooth radio
```

What it does:
1. `fix-wifi`: finds the wifi device via `nmcli`, runs `nmcli device disconnect` then `nmcli device connect` — the same "force one fresh association" effect a reboot has, without restarting the OS. NetworkManager and wpa_supplicant were never actually wedged during this incident, so this alone would have resolved it.
2. `fix-wifi --bluetooth`: `bluetoothctl power off` then `power on` — the standard fix for a Bluetooth NAP/tether connection that fails with an I/O error, no root needed.

## Caveats

- Does not address the underlying mesh roaming instability, only gives a fast way to force a clean reconnect instead of rebooting. If the roaming storm recurs frequently, the next diagnostic step is checking signal strength and backhaul health per mesh node (router admin UI, or `iw dev wlp3s0 link` while it's happening).
- `fix-wifi --bluetooth` addresses a failed *Bluetooth tether*. If the goal is actually a wifi hotspot from the phone, connecting to that is a separate wifi network in `nmcli`, not a Bluetooth action at all — worth using instead of Bluetooth tethering going forward, since NAP has historically been less reliable than a wifi hotspot.
