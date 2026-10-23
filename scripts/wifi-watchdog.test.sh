#!/usr/bin/env bash
# Scenario tests for wifi-watchdog's poll loop against a fake nmcli.
#   bash scripts/wifi-watchdog.test.sh
set -uo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=scripts/wifi-watchdog.sh
. "$(dirname "$0")/wifi-watchdog.sh"

# Fake nmcli. STATE is GENERAL.STATE (100 = connected), RADIO is what
# `nmcli radio wifi` prints, PERM is the enable-disable-wifi value (empty
# drops the row, as if the permission query failed). Any attempt to toggle
# the radio directly is recorded, since the watchdog must only do that
# through fix-wifi.
STATE=30 RADIO=enabled PERM=yes
nmcli() {
    case "$*" in
        "-t -f DEVICE,TYPE device status") printf 'lo:loopback\nwlp3s0:wifi\n' ;;
        "-t -f GENERAL.STATE device show wlp3s0") printf 'GENERAL.STATE:%s (state)\n' "$STATE" ;;
        "radio wifi") printf '%s\n' "$RADIO" ;;
        "-t -f PERMISSION,VALUE general permissions")
            printf 'org.freedesktop.NetworkManager.enable-disable-network:yes\n'
            [ -n "$PERM" ] && printf 'org.freedesktop.NetworkManager.enable-disable-wifi:%s\n' "$PERM"
            printf 'org.freedesktop.NetworkManager.enable-disable-wifi-extra:yes\n'
            ;;
        "radio wifi "*) echo "$*" >> "$tmp/direct-radio" ;;
        *) echo "unexpected nmcli $*" >&2; return 1 ;;
    esac
}
notify() { echo "$1" >> "$tmp/notify"; }

# Fake fix-wifi: records each call, exits with FIX_RC.
FIX_RC=0
cat > "$tmp/fix-wifi" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/fix-calls"
exit "${FIX_RC:-0}"
EOF
chmod +x "$tmp/fix-wifi"
export FIX_WIFI="$tmp/fix-wifi" FIX_RC

reset() {
    fail_count=0 last_trigger=0 deferred=false
    STATE=30 RADIO=enabled PERM=yes FIX_RC=0
    rm -f "$tmp/fix-calls" "$tmp/notify" "$tmp/direct-radio" "$tmp/out"
}
polls() { local i; for ((i = 0; i < $1; i++)); do poll_once >> "$tmp/out" 2>&1; done; }
count() { if [ -f "$1" ]; then grep -c -- "${2:-}" "$1"; else echo 0; fi; }

fails=0
check() {
    local want=$1 got=$2 desc=$3
    if [ "$want" = "$got" ]; then
        printf 'ok    %s\n' "$desc"
    else
        printf 'FAIL  %s: want %q, got %q\n' "$desc" "$want" "$got"
        fails=$((fails + 1))
    fi
}

reset; STATE=100; polls 20
check 0 "$(count "$tmp/fix-calls")" "connected: never resets"

reset; polls 5
check 0 "$(count "$tmp/fix-calls")" "below threshold: no reset yet"
polls 1
check 1 "$(count "$tmp/fix-calls" --radio)" "threshold reached while authorized: one fix-wifi --radio"
check 1 "$(count "$tmp/notify" "ran a radio reset")" "success is notified as success"

reset; FIX_RC=1; export FIX_RC; polls 6
check 1 "$(count "$tmp/notify" "FAILED")" "a failed fix-wifi is notified as a failure"
FIX_RC=0; export FIX_RC

reset; polls 6; polls 29
check 1 "$(count "$tmp/fix-calls")" "cooldown: still stuck within 300s, no second reset"

reset; PERM=no; polls 40
check 0 "$(count "$tmp/fix-calls")" "locked session (permission no): never resets"
check 1 "$(count "$tmp/out" "deferring")" "deferral is logged once, not every poll"
PERM=yes; polls 1
check 1 "$(count "$tmp/fix-calls")" "unlocked and still stuck: resets on the next poll"

reset; PERM=auth; polls 10
check 0 "$(count "$tmp/fix-calls")" "permission auth (would need a password): never resets"

reset; PERM=""; polls 10
check 0 "$(count "$tmp/fix-calls")" "permission row missing: fails safe, no reset"

reset; PERM=no; polls 6; STATE=100; polls 1; STATE=30; polls 6
check 2 "$(count "$tmp/out" "deferring")" "reconnecting clears the deferral, next stall logs again"

reset; RADIO=disabled; polls 10
check 0 "$(count "$tmp/fix-calls")" "radio switched off by the user: left alone"

# /usr/bin:/bin keeps awk and friends but not ~/.local/bin, so the real
# fix-wifi on this machine can never be picked up here.
reset; FIX_WIFI="" PATH=/usr/bin:/bin polls 6
check 0 "$(count "$tmp/direct-radio")" "fix-wifi missing: never toggles the radio itself"
check 1 "$(count "$tmp/notify" "fix-wifi is missing")" "fix-wifi missing: says so"

check 0 "$(count "$tmp/direct-radio")" "the radio is only ever toggled through fix-wifi"

# find_fix_wifi must work under the systemd user manager's PATH, which has
# no ~/.local/bin: install a copy the way install.sh does and look it up.
mkdir -p "$tmp/bin"
cp "$(dirname "$0")/wifi-watchdog.sh" "$tmp/bin/wifi-watchdog"
cp "$tmp/fix-wifi" "$tmp/bin/fix-wifi"
check "$tmp/bin/fix-wifi" \
    "$(PATH=/usr/bin:/bin bash -c '. "$1"; find_fix_wifi' _ "$tmp/bin/wifi-watchdog")" \
    "finds fix-wifi beside itself without ~/.local/bin on PATH"
ln -s "$tmp/bin/wifi-watchdog" "$tmp/watchdog-link"
check "$tmp/bin/fix-wifi" \
    "$(PATH=/usr/bin:/bin bash -c '. "$1"; find_fix_wifi' _ "$tmp/watchdog-link")" \
    "resolves a symlinked wifi-watchdog to its real directory"

echo
if [ "$fails" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fails test(s) failed"
    exit 1
fi
