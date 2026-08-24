# Wifi Driver Lockup (Association Requests Rejected by the Driver)

## Overview

On mba15, home wifi cut off and never recovered, and switching to a phone hotspot also failed to connect — the machine eventually had to be rebooted. `journalctl` logs from the affected boot show this was neither an AP-side nor an ISP-side outage: `wpa_supplicant` logged `Association request to the driver failed` on every single attempt, for five straight minutes, against two completely unrelated networks (home wifi and the phone hotspot), which rules out the specific AP or the WAN link. The fault was the local wifi driver/firmware state itself refusing to associate to anything, one layer below where `fix-wifi`'s existing disconnect/reconnect cycle operates — NetworkManager had already retried that exact cycle automatically about ten times, plus once more manually, with no effect. Fixed by adding a radio-level reset tier (`fix-wifi --radio`) and a `wifi-watchdog` systemd user service that detects the pattern and runs that reset automatically, without needing a manual command or a reboot.

## Table of Contents

- [Overview](#overview)
- [Timeline (2026-08-21, incident)](#timeline-2026-08-21-incident)
- [Root cause](#root-cause)
- [Fix](#fix)
- [Caveats](#caveats)

## Timeline (2026-08-21, incident)

- **~16:21:10** — Machine resumed from a suspend cycle. `wlp3s0` reassociated to home wifi within 2 seconds. A `FT: Invalid key management type (2)` warning fired during this attempt but association succeeded anyway (4-way handshake completed, DHCP lease obtained) — this warning turned out to be cosmetic noise on this driver/AP combination, not a fault.
- **16:57:19–17:02:11** — Wifi failed to reach a fully-connected state for over 5 minutes straight. NetworkManager auto-retried roughly every 25-30 seconds (`policy: auto-activating connection 'wifi-wlp3s0'` → `Association: failed for connection` → repeat), each attempt ending in `device (wlp3s0): Activation: (wifi) association took too long, failing activation`. Every retry's `wpa_supplicant` log line read `wlp3s0: Association request to the driver failed` — a local driver-level rejection, not an AP response timeout.
- **16:59:54** — NetworkManager auto-activated a different connection profile, the phone's wifi hotspot (`W's Galaxy A14`), after home wifi kept failing. It failed identically: `Association request to the driver failed`.
- **17:00:42** — User manually disconnected (`op="device-disconnect" ... uid=1000`) — effectively running `fix-wifi`'s exact logic by hand.
- **17:01:20** — Auto-reconnected to the phone hotspot. Failed the same way again.
- **17:02:11** — Last failed attempt logged before the reboot.
- **17:02:40** — New boot.

## Root cause

`wlp3s0: Association request to the driver failed` means `wpa_supplicant` asked the kernel wifi driver to associate and the driver rejected the call immediately — before a single 802.11 frame went out over the air. That happened identically against two unrelated networks (home wifi and a phone hotspot on a different BSSID entirely), which rules out the specific access point, the home router, and the ISP. The driver/firmware state on `wlp3s0` itself was wedged.

This is a different failure class from [[wifi-roaming-storm-bluetooth-tether-fail.md]] (2026-08-17): that incident had NetworkManager/wpa_supplicant successfully reconnecting the whole time, just to the wrong access point (a connection-profile-level problem, fixed by `fix-wifi`'s disconnect/reconnect). This incident had every association attempt fail at the driver level regardless of target network — a fault one layer further down. NetworkManager's own auto-reconnect logic already performs the same disconnect/reconnect cycle `fix-wifi` does, roughly every 25-30 seconds; it ran that cycle about ten times automatically plus once more when the user manually intervened at 17:00:42, and none of those attempts helped, because they were all operating at the wrong layer.

## Fix

`scripts/fix-wifi.sh` gained a `--radio` mode:

```sh
fix-wifi --radio   # power-cycle the wifi radio itself (nmcli radio wifi off/on)
```

Unlike plain `fix-wifi` (which cycles the NetworkManager *connection profile*), `--radio` power-cycles the actual radio/firmware state via `nmcli radio wifi off` then `on`. No sudo required — `org.freedesktop.NetworkManager.enable-disable-wifi` is a normal polkit permission for the logged-in user.

`scripts/wifi-watchdog.sh`, installed as a systemd `--user` service (`etc/systemd/user/wifi-watchdog.service`, enabled via `install.sh`), polls `nmcli -f GENERAL.STATE device show <wifi-device>` every 10 seconds. If the device stays off the fully-connected state (`100`) for 6 consecutive polls (~60s) while the radio is enabled, it runs `fix-wifi --radio` automatically and sends a desktop notification (`notify-send`) reporting what it did. A 5-minute cooldown between triggers prevents fighting a genuinely flaky or out-of-range network in a loop. This closes the gap the 2026-08-21 incident exposed: no existing alias reached the radio/driver layer, so a reboot was the only tool available once the connection-profile-level retries (both automatic and manual) had already failed.

## Caveats

- The watchdog deliberately does not escalate beyond the radio reset (no driver module reload, no auto-reboot) if that doesn't clear it — it just notifies and waits out the cooldown. A driver-module-level reset would need root, which was intentionally left out of automatic remediation; if the radio reset alone stops being sufficient, investigate manually (`fix-wifi --radio`, then check `dmesg`/journal for the wifi driver's kernel messages) rather than assuming an unattended deeper reset is safe.
- The `FT: Invalid key management type (2)` warning seen throughout these logs (including in the unrelated, successful 16:21 reconnect) is cosmetic on this driver/AP combination — it fires on essentially every association attempt, successful or not, and is not a reliable signal of the driver-lockup failure mode on its own. The reliable signal is `Association request to the driver failed` combined with NetworkManager's `association took too long, failing activation`.
- Not diagnosed further: *why* the driver got wedged in the first place (firmware bug, thermal/power event, USB/PCIe bus hiccup on this older MacBook hardware). The watchdog treats the lockup as recoverable-but-recurring rather than something to root-cause at the firmware level, since a wifi-off/on power cycle already existed as a safe operator action before this file was ever written.
