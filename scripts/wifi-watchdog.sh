#!/usr/bin/env bash
set -uo pipefail

# Wifi driver-lockup watchdog. Runs as a systemd --user service.
#
# On 2026-08-21, mba15's wifi driver got stuck: wpa_supplicant logged
# "Association request to the driver failed" on every single attempt, for
# 5 straight minutes, against home wifi *and* an unrelated phone
# hotspot -- ruling out the AP/ISP. NetworkManager auto-retried a plain
# disconnect/reconnect (what `fix-wifi` does) about 10 times on its own and
# it never helped, because the fault was one layer down, in the radio/
# driver state itself. Only a reboot cleared it. Full incident:
# notes/wifi-driver-lockup-2026-08-21.md.
#
# This watches for that pattern -- the wifi device failing to reach the
# fully-connected state while the radio is enabled -- and automatically
# runs the radio-level reset (`fix-wifi --radio`) that sits one layer
# below NetworkManager's own retries, so a lockup like that clears itself
# without needing a manual command or a reboot. No sudo required: toggling
# the wifi radio is a normal NetworkManager permission for the logged-in
# user (org.freedesktop.NetworkManager.enable-disable-wifi) -- but only
# while their session is the active one. With the screen locked the reset
# is deferred until it is allowed again; see radio_toggle_authorized.
#
# Deliberately does NOT escalate further (no driver reload, no reboot) if
# the radio reset doesn't clear it -- just notifies and waits for the next
# cooldown window, so a genuinely out-of-range or misconfigured network
# doesn't get fought forever. Investigate manually if the notification
# recurs.

POLL_INTERVAL_SECONDS=10
FAILURE_THRESHOLD=6      # consecutive non-connected polls (~60s) before acting
COOLDOWN_SECONDS=300      # minimum gap between radio resets

wifi_device() {
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: '$2=="wifi"{print $1; exit}'
}

is_connected() {
    local dev="$1" state
    state="$(nmcli -t -f GENERAL.STATE device show "$dev" 2>/dev/null | cut -d: -f2 | cut -d' ' -f1)"
    [ "$state" = "100" ]
}

radio_enabled() {
    [ "$(nmcli radio wifi 2>/dev/null)" = "enabled" ]
}

# NetworkManager's own answer to "may this session toggle the radio right
# now?". enable-disable-wifi is allow_active=yes / allow_inactive=no, so it
# reads "no" while the screen is locked (light-locker switches to the
# greeter VT and the session goes inactive). Asking first means the
# watchdog never starts a reset polkit will refuse halfway through -- the
# 2026-10-06 incident was exactly that: "off" landed, "on" was refused.
# "auth" counts as not allowed too: a background service has nobody to
# answer a password prompt. See
# notes/wifi-watchdog-resume-polkit-race-disables-radio.md.
radio_toggle_authorized() {
    nmcli -t -f PERMISSION,VALUE general permissions 2>/dev/null \
        | grep -qx 'org.freedesktop.NetworkManager.enable-disable-wifi:yes'
}

# The systemd user manager's PATH doesn't include ~/.local/bin, so a plain
# `command -v fix-wifi` fails inside the service. install.sh puts both
# scripts in the same directory, so look next to this one first.
find_fix_wifi() {
    local sibling
    sibling="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fix-wifi"
    if [ -x "$sibling" ]; then
        printf '%s\n' "$sibling"
    else
        command -v fix-wifi
    fi
}

notify() {
    if command -v notify-send > /dev/null 2>&1; then
        notify-send -u normal "Wifi auto-recovery" "$1" || true
    fi
}

fail_count=0
last_trigger=0
deferred=false

poll_once() {
    local dev now stuck_for fix_wifi

    dev="$(wifi_device)"
    if [ -z "$dev" ] || ! radio_enabled; then
        fail_count=0
        deferred=false
        return 0
    fi

    if is_connected "$dev"; then
        fail_count=0
        deferred=false
        return 0
    fi

    fail_count=$((fail_count + 1))
    now=$(date +%s)
    if [ "$fail_count" -lt "$FAILURE_THRESHOLD" ] || [ $((now - last_trigger)) -lt "$COOLDOWN_SECONDS" ]; then
        return 0
    fi
    stuck_for=$((fail_count * POLL_INTERVAL_SECONDS))

    # Keep fail_count while deferred, so the reset runs on the first poll
    # after the session becomes active again if wifi is still stuck.
    if ! radio_toggle_authorized; then
        if ! $deferred; then
            echo "wifi-watchdog: $dev stuck disconnected for ~${stuck_for}s, but this session may not toggle the radio right now (screen locked?) -- deferring the reset"
            deferred=true
        fi
        return 0
    fi
    deferred=false
    last_trigger=$now
    fail_count=0

    fix_wifi="${FIX_WIFI:-$(find_fix_wifi)}"
    if [ -z "$fix_wifi" ]; then
        echo "wifi-watchdog: $dev stuck disconnected for ~${stuck_for}s, but fix-wifi is not installed next to wifi-watchdog or on PATH" >&2
        notify "$dev looked wedged for ~${stuck_for}s -- fix-wifi is missing, rerun the dotfiles install.sh."
        return 0
    fi

    echo "wifi-watchdog: $dev stuck disconnected for ~${stuck_for}s, running radio reset..."
    if "$fix_wifi" --radio; then
        notify "$dev looked wedged for ~${stuck_for}s -- ran a radio reset (nmcli radio wifi off/on)."
    else
        notify "$dev looked wedged for ~${stuck_for}s -- radio reset FAILED, wifi may still be off. Run: nmcli radio wifi on"
    fi
}

main() {
    while true; do
        sleep "$POLL_INTERVAL_SECONDS"
        poll_once
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
fi
