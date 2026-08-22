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
# user (org.freedesktop.NetworkManager.enable-disable-wifi).
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

notify() {
    command -v notify-send > /dev/null 2>&1 && notify-send -u normal "Wifi auto-recovery" "$1" || true
}

fail_count=0
last_trigger=0

while true; do
    sleep "$POLL_INTERVAL_SECONDS"

    dev="$(wifi_device)"
    if [ -z "$dev" ] || ! radio_enabled; then
        fail_count=0
        continue
    fi

    if is_connected "$dev"; then
        fail_count=0
        continue
    fi

    fail_count=$((fail_count + 1))
    now=$(date +%s)

    if [ "$fail_count" -ge "$FAILURE_THRESHOLD" ] && [ $((now - last_trigger)) -ge "$COOLDOWN_SECONDS" ]; then
        stuck_for=$((fail_count * POLL_INTERVAL_SECONDS))
        echo "wifi-watchdog: $dev stuck disconnected for ~${stuck_for}s, running radio reset..."
        if command -v fix-wifi > /dev/null 2>&1; then
            fix-wifi --radio
        else
            nmcli radio wifi off
            sleep 2
            nmcli radio wifi on
        fi
        notify "$dev looked wedged for ~${stuck_for}s -- ran a radio reset (nmcli radio wifi off/on)."
        last_trigger=$now
        fail_count=0
    fi
done
