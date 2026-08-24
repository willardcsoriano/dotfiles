#!/usr/bin/env bash
set -euo pipefail

# Local wifi/Bluetooth recovery utility. Neither NetworkManager nor
# wpa_supplicant actually crash or wedge when wifi goes flaky (a mesh
# network roaming repeatedly between access points, for example) - they
# keep dutifully reconnecting, just to the wrong thing, over and over. A
# full reboot "fixes" this only by coincidence (it forces one fresh
# association instead of the roam loop). Forcing that same fresh
# association directly is enough, and doesn't require restarting the OS.
#
#   fix-wifi              Force a clean disconnect/reconnect of the wifi
#                          device. Use when wifi is connected-but-flaky
#                          (repeated drops, slow/stuck roaming between
#                          access points on the same network).
#   fix-wifi --radio       Power-cycle the wifi radio itself (nmcli radio
#                          wifi off/on). Use when plain fix-wifi doesn't
#                          help -- i.e. wpa_supplicant logs "Association
#                          request to the driver failed" against every
#                          network, not just one. That means the driver/
#                          firmware state is wedged, one layer below what a
#                          connection-profile disconnect/reconnect can
#                          reach. See notes/wifi-driver-lockup-2026-08-21.md.
#   fix-wifi --bluetooth   Power-cycle the Bluetooth radio. Use when
#                          Bluetooth tethering (phone NAP connection) fails
#                          to come up (bluez "Input/output error" is the
#                          usual symptom).

fix_wifi() {
    local dev
    dev="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
    if [ -z "$dev" ]; then
        echo "No wifi device found." >&2
        exit 1
    fi
    echo "Reconnecting $dev..."
    nmcli device disconnect "$dev" || true
    nmcli device connect "$dev"
    echo "Done."
}

fix_radio() {
    echo "Power-cycling wifi radio..."
    nmcli radio wifi off
    sleep 2
    nmcli radio wifi on
    echo "Done."
}

fix_bluetooth() {
    echo "Power-cycling Bluetooth..."
    bluetoothctl power off
    sleep 1
    bluetoothctl power on
    echo "Done."
}

case "${1:-}" in
    --radio)
        fix_radio
        ;;
    --bluetooth)
        fix_bluetooth
        ;;
    *)
        fix_wifi
        ;;
esac
