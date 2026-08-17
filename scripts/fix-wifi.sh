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

fix_bluetooth() {
    echo "Power-cycling Bluetooth..."
    bluetoothctl power off
    sleep 1
    bluetoothctl power on
    echo "Done."
}

if [ "${1:-}" = "--bluetooth" ]; then
    fix_bluetooth
else
    fix_wifi
fi
