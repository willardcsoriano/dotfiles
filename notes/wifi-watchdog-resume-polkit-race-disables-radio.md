# `wifi-watchdog`'s Own Remediation Disabled Wifi on Resume

## Overview

Wifi had to be manually re-enabled (`nmcli radio wifi on`) after a laptop resume, with no reboot involved. The cause wasn't a network problem, a driver issue, or the hardware killswitch documented previously — it was `wifi-watchdog`, the existing self-healing systemd service, misfiring its own remediation at the exact moment of resume and then failing the "turn the radio back on" half of that remediation to a polkit authorization race. The tool left wifi in a strictly worse state than before it acted, with no retry and no distinct alert, which is the opposite of what it exists to do. This is a fourth, previously undocumented wifi failure mode on this hardware, and unlike the other three, this one is self-inflicted by existing tooling rather than an external driver/hardware/network cause.

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

**2. The "turn wifi back on" half of the remediation hit a resume-specific authorization race.** The exact same `nmcli radio wifi on` action succeeded three times the evening before, under identical permissions, with no code changes. The only thing different about this occurrence is timing: it ran within 2 seconds of a resume, while the session's lock-screen/seat state (XFCE's `lock-screen-suspend-hibernate` is enabled by the post-install setup) was still reattaching. Polkit's authorization check for `org.freedesktop.NetworkManager.enable-disable-wifi` depends on the calling session being recognized as active; right at the resume boundary, before that reattachment settles, a call can transiently fail with exactly this "Not authorized" error even though the exact same call succeeds a few seconds later. This is a narrow timing race, not a permissions misconfiguration — confirmed by the fact that the manual retry 84 seconds later needed no `sudo`, no `pkexec`, no config change of any kind.

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

**Applied.** Both `scripts/fix-wifi.sh`'s `fix_radio()` and `scripts/wifi-watchdog.sh`'s inline fallback now retry the re-enable call up to 3 times with a short backoff, verifying via `nmcli radio wifi` that it actually reports `enabled` rather than trusting a single fire-and-forget call. If all 3 attempts fail, `fix_radio()` returns nonzero and `wifi-watchdog` sends a distinct, honest notification (`radio reset FAILED, wifi may still be off`) instead of the same reassuring message it sends on success. This would have self-healed this exact incident within a few more seconds instead of requiring manual intervention.

Not applied, and deliberately out of scope for this fix:
- Having `wifi-watchdog` explicitly reset `fail_count=0` on detecting a resume, rather than letting a possibly-stale or burst-incremented count carry across the suspend boundary. The retry/verify fix addresses the actual user-visible failure (radio left off) regardless of why the remediation fired when it did, so this wasn't needed to close the incident — worth revisiting only if the instant-at-resume firing pattern itself causes a different problem later.
- Disabling the watchdog around suspend/resume entirely — not warranted; the three same-evening successes show it's doing real, necessary work, and the bug was narrow.

## Open items

- **The suspend-insensitive polling-burst theory for why it fired at the exact resume instant remains the best-supported explanation, not confirmed with certainty.** Confirming it precisely would need deliberately reproducing a suspend/resume cycle while watching `wifi-watchdog`'s poll timing directly (e.g. temporarily adding a timestamp to its log line). Left uninvestigated since the retry/verify fix closes the actual incident regardless of this mechanism's exact shape.
- **Unverified whether the polkit authorization race is reproducible on demand** or was a one-off timing fluke. The retry/verify fix makes this moot for user impact either way, but if it recurs frequently even with retries, that would point at a longer-lived authorization gap than 2-3 seconds, worth a fresh look.
