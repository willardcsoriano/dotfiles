# `wifi-watchdog`'s Own Remediation Disabled Wifi on Resume

## Overview

Wifi had to be manually re-enabled (`nmcli radio wifi on`) after a laptop resume, with no reboot involved. The cause wasn't a network problem, a driver issue, or the hardware killswitch documented previously — it was `wifi-watchdog`, the existing self-healing systemd service, misfiring its own remediation at the exact moment of resume and then failing the "turn the radio back on" half of that remediation because polkit refuses radio toggles from a session that isn't active (the screen was still locked). The tool left wifi in a strictly worse state than before it acted, with no retry and no distinct alert, which is the opposite of what it exists to do. This is a fourth, previously undocumented wifi failure mode on this hardware, and unlike the other three, this one is self-inflicted by existing tooling rather than an external driver/hardware/network cause.

## Table of Contents

- [Overview](#overview)
- [Timeline](#timeline)
- [Diagnosis](#diagnosis)
- [Why this is a different mechanism from the others](#why-this-is-a-different-mechanism-from-the-others)
- [Fix](#fix)
- [Open items](#open-items)

## Timeline

All confirmed via `sudo journalctl -u NetworkManager -u wpa_supplicant` and, critically, `journalctl --user -u wifi-watchdog` (the service's own log, readable without root since it's a user unit):

- **17:58, 18:05, 18:10 (evening before)** — `wifi-watchdog` correctly detected wifi stuck disconnected (`~60s`, `~60s`, `~300s` per its own log) and ran its radio-reset remediation three separate times, each a clean `nmcli radio wifi off` → 2s wait → `nmcli radio wifi on` pair. All three succeeded. This is the tool working exactly as designed — wifi was genuinely unstable that evening, and the existing mechanism handled it without any manual intervention.
- **18:12:31** — Laptop suspended.
- **09:49:24 (next morning)** — Laptop resumed (`manager: sleep: wake requested`). In the same instant, `wifi-watchdog` logged `wlp3s0 stuck disconnected for ~120s, running radio reset...` and the radio was turned off successfully (`audit: op="radio-control" arg="wireless-enabled:off" ... result="success"`).
- **09:49:26** — Two seconds later, exactly matching the remediation's hardcoded `sleep 2`, the "turn wifi back on" call **failed**: `wifi-watchdog[82388]: Error: failed to set Wi-Fi radio: Not authorized to perform this operation` / `audit: op="radio-control" arg="wireless-enabled:on" ... result="fail" reason="Not authorized to perform this operation"`.
- **09:49:26 – 09:50:48** — Wifi radio stayed disabled. Nothing in `wifi-watchdog` retried or alerted differently than a normal successful run.
- **09:50:48** — Manually re-enabled (`nmcli radio wifi on`, succeeded this time) and reconnected to `Soriano_Home` normally within seconds.

## Diagnosis

Two separate things had to both be true for this to happen, and neither one alone would have caused a user-visible outage:

**1. The remediation fired essentially instantly at resume, not after a genuine ~120 seconds of being stuck.** `wifi-watchdog`'s poll loop (`scripts/wifi-watchdog.sh`) is `while true; do sleep 10; ...; done`, incrementing `fail_count` on every poll where the device isn't fully connected. A real 120-second stuck period would mean 12 polls spaced 10 real seconds apart — but the trigger landed in the same instant as `wake requested`, not two minutes afterward. The most likely explanation is that the loop's `sleep 10` calls don't account for suspend cleanly, and on resume the loop runs through a backlog of polls in a tight burst rather than one every 10 real seconds — exactly the kind of suspend-insensitive-timer problem already documented for SSH's `ServerAliveInterval` in [[project_ssh_controlmaster_zombie_resume]], just surfacing differently here (a burst instead of a frozen timer). Right after resume, the network device is still mid-reconnection (`unmanaged → unavailable → disconnected` in the log, all before the device actually reassociates) — a burst of polls landing in that window would all read "not connected" and race fail_count past the 6-poll threshold almost immediately.

**2. The "turn wifi back on" half of the remediation hit a resume-specific authorization race.** The exact same `nmcli radio wifi on` action succeeded three times the evening before, under identical permissions, with no code changes. The only thing different about this occurrence is timing: it ran within 2 seconds of a resume, while the session's lock-screen/seat state (XFCE's `lock-screen-suspend-hibernate` is enabled by the post-install setup) was still reattaching. Polkit's authorization check for `org.freedesktop.NetworkManager.enable-disable-wifi` depends on the calling session being recognized as active; right at the resume boundary, before that reattachment settles, a call can transiently fail with exactly this "Not authorized" error even though the exact same call succeeds a few seconds later. The manual retry 84 seconds later needed no `sudo`, no `pkexec` and no config change, which at first read as a narrow timing race. It wasn't: the refusal lasts for as long as the session is inactive, i.e. until the screen is unlocked (confirmed 2026-10-23, see [Fix](#fix)).

## Why this is a different mechanism from the others

This machine now has **four** confirmed distinct ways wifi ends up broken, and it's worth keeping them separate:

| Mechanism | Trigger | Radio state | Fixed by |
|---|---|---|---|
| Roaming storm ([[project_wifi_roaming_bluetooth_tether]]) | Mesh AP disagreement | Stays enabled, reconnects to the wrong AP repeatedly | `fix-wifi` (plain reconnect) |
| Driver lockup ([[project_wifi_driver_lockup]]) | Driver/firmware wedge | Stays enabled, every association rejected at the driver | `fix-wifi --radio` / `wifi-watchdog` |
| Hardware killswitch on cold boot ([[project_wifi_hardware_killswitch]]) | A full reboot | Comes up hardware-blocked, stays off until manual enable | Manual `nmcli radio wifi on` (no automation yet) |
| **This incident** | **Resume from suspend**, no reboot | Actively turned off *by the watchdog itself*, then fails to turn back on | Manual `nmcli radio wifi on` (same symptom as the killswitch case, totally different cause) |

The killswitch incident and this one look identical from the outside — wifi is off, no reboot-adjacent explanation obviously applies, user has to flip it back on manually — but the killswitch case has no `wifi-watchdog` log entry at all (the radio comes up blocked before any userspace service even starts), while this one is entirely `wifi-watchdog`'s own doing, start to finish, confirmed in its own log. **Check `journalctl --user -u wifi-watchdog` before assuming a repeat of the killswitch mechanism** — if that log is silent, it's the killswitch; if it logged a radio-reset attempt, it's this one.

## Fix

**First attempt (2026-10-06), which never ran from the watchdog.** `scripts/fix-wifi.sh`'s `fix_radio()` gained a 3-attempt retry that verifies `nmcli radio wifi` reports `enabled`, and the watchdog gained a distinct `radio reset FAILED` notification. But the watchdog only calls `fix-wifi` if `command -v fix-wifi` finds it, and the systemd user manager's PATH (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`) has no `~/.local/bin`. Inside the service the lookup always failed, so the watchdog kept using its inline off/on fallback, which has no retry. Its log shows this: every failed reset logs at most two `Not authorized` lines (off, then on), never the three retries `fix-wifi --radio` would make.

**Root cause, confirmed 2026-10-23.** The cause isn't a narrow resume race. `org.freedesktop.NetworkManager.enable-disable-wifi` is `allow_active=yes`, `allow_inactive=no`. While the screen is locked, light-locker switches to the LightDM greeter VT, logind marks the session inactive, and every radio toggle is refused for as long as the lock lasts. On 2026-10-19 the watchdog tried, and was refused, every five minutes for over three hours. On 2026-10-23 it was refused at 17:20:54, and the same inactive window let nm-applet raise an admin password dialog for `settings.modify.system` about 90 seconds later. `nmcli general permissions` reads `yes` for both actions once the session is active again.

**Applied (dotfiles #47).**
- `wifi-watchdog` asks NetworkManager first (`nmcli general permissions`). If `enable-disable-wifi` is anything but `yes`, it logs the deferral once and does nothing. It keeps its stuck count, so the reset runs on the first poll after unlock if wifi is still down. It can no longer start a reset that polkit will refuse halfway through, which was the failure on 2026-10-06.
- `wifi-watchdog` finds `fix-wifi` next to itself (where `install.sh` puts both), falling back to PATH. The duplicate inline fallback is gone, and if `fix-wifi` is missing the watchdog says so instead of improvising.
- `install.sh` restarts the service, so a re-run picks up a changed script instead of leaving the old one running until the next login.
- `scripts/wifi-watchdog.test.sh` covers these paths against a fake `nmcli`.

The system-wide half, a polkit rule that refuses NetworkManager changes from a locked session so no password dialog can appear there, lives in the `debian-intel-macbook-post-install` repo (issue #11).

Still deliberately out of scope: resetting `fail_count` on resume, and disabling the watchdog around suspend.

## Open items

- **The suspend-insensitive polling-burst theory for why it fired at the exact resume instant remains the best-supported explanation, not confirmed with certainty.** Confirming it precisely would need deliberately reproducing a suspend/resume cycle while watching `wifi-watchdog`'s poll timing directly (e.g. temporarily adding a timestamp to its log line). Left uninvestigated: the permission check now in the watchdog means a burst at resume, while the screen is still locked, defers instead of acting, whatever the burst's exact shape.
