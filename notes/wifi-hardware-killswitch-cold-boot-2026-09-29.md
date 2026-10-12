# Wifi Hardware Killswitch Blocked After a Cold Boot

## Overview

On mba15, wifi appeared to have "turned itself off" mid-session. `journalctl` logs showed this was actually two unrelated events layered together: a routine, self-healing radio bounce from the existing `wifi-watchdog` service (working as designed, not a fault), followed roughly 12 minutes later by a full system reboot after which the wifi radio came up hardware-blocked and stayed off for 5.5 minutes until manually re-enabled. This is a third, distinct wifi failure mechanism for this machine — different from both the 2026-08-17 roaming storm and the 2026-08-21 driver lockup — and it left the client on a saved phone-hotspot profile instead of home wifi once wifi did come back, which in turn blocked an unrelated `dev`-VM SSH fix already in progress (see `dotfiles/ssh-vm-banner-timeout/incident-2026-09-29-mobile-hotspot-blocks-pileup-fix.md`). No automated recovery exists for this mechanism yet.

## Table of Contents

- [Overview](#overview)
- [Timeline (2026-09-29)](#timeline-2026-09-29)
- [Root cause](#root-cause)
- [Fix applied](#fix-applied)
- [Open items](#open-items)

## Timeline (2026-09-29)

- **14:19:05** — Resume from suspend. Wifi stuck disconnected for ~60s, `wifi-watchdog` ran its standard `fix-wifi --radio` self-heal (`rfkill: WLAN soft blocked` → `wireless-enabled:on` 2 seconds later) — the same known-good mechanism from `wifi-driver-lockup-2026-08-21.md`, not new.
- **14:31:27** — A `pkexec` root session opened for `<user>`, consistent with a locally-authenticated reboot request (e.g. the XFCE session menu).
- **14:31:30–14:31:51** — Clean `NetworkManager`/`wpa_supplicant` shutdown, then a full boot (new boot ID in `journalctl --list-boots`). Not a crash — orderly service stop/start, full device re-enumeration.
- **14:31:52** — On boot, NetworkManager logs `rfkill: Wi-Fi hardware radio set disabled`, then `rfkill: Wi-Fi disabled by radio killswitch; disabled by state file`. Wifi radio stays off.
- **14:37:13** — `<user>` (uid=1000) manually re-enables the radio (`audit: op="radio-control" arg="wireless-enabled:on"`) — 5 minutes 21 seconds after boot.
- **14:37:17** — NetworkManager auto-activates `W's Galaxy A14` (a saved phone-hotspot profile) instead of `Soriano_Home`, because every saved profile shared the same `autoconnect-priority` (0) and home wifi wasn't confirmed in range at that moment.

## Root cause

The hardware rfkill killswitch (kernel/EC level, one layer below NetworkManager's own software radio toggle) reasserted a blocked state across this reboot. NetworkManager's own log is explicit that this is the *hardware* killswitch, not its software preference (`disabled by radio killswitch`, distinct from `disabled by state file`, though both applied here). Confirming the exact kernel-side reason wasn't possible in-session — `dmesg` is root-restricted (`kernel.dmesg_restrict`) and wasn't checked with sudo — so whether this is a firmware/EC default on cold boot for this MacBook's Broadcom-family wifi chipset, or something else entirely, is not fully nailed down. What is confirmed: it's a hardware-layer block distinct from both prior mechanisms — [[wifi-roaming-storm-bluetooth-tether-fail]] (AP-level, radio never blocked) and [[wifi-driver-lockup-2026-08-21]] (driver association failures while the radio itself reports enabled).

## Fix applied

None automated — this occurrence was resolved the manual way (toggling wifi back on via the tray icon/`nmcli radio wifi on`), same as any user would without knowing the mechanism. Separately, the *downstream* effect (landing on a saved hotspot instead of home wifi once wifi came back) was mitigated: `Soriano_Home`'s `connection.autoconnect-priority` was raised from `0` to `10` so NetworkManager will prefer it over any saved hotspot whenever both are in range. This doesn't address the killswitch itself, only which network gets picked once wifi is back.

## Open items

- **No automated recovery exists for a post-reboot hardware radio block**, unlike the other two mechanisms (`fix-wifi --radio` / `wifi-watchdog` cover driver lockup; nothing currently watches for "radio has been off for N minutes right after boot/login"). A systemd unit triggered on graphical login that checks `nmcli radio wifi` and force-enables it if off would close this gap the same way `wifi-watchdog` closed the driver-lockup one.
- **Root kernel-level cause unconfirmed** — needs a `sudo dmesg` read around a future occurrence's boot time to see what the kernel/ACPI layer reports about the rfkill state at that point.
- **Unverified whether this recurs.** First confirmed occurrence; treat a second one as establishing a pattern rather than assuming this write-up alone means it's understood.
