#!/usr/bin/env bash
set -uo pipefail

# Single entry point for "something's wrong, what do I run?" -- runs every
# known local diagnostic (wifi, SSH ControlMaster, VS Code hang) plus the
# dev VM check, and prints a diagnosis with the exact alias to run next for
# each. Advisory only, like check-dev: never takes action itself.
#
# Built after the 2026-08-21 wifi driver lockup incident, where the actual
# blocker wasn't a missing fix -- it was not being able to reach an agent to
# ask "what do I run" while the network itself was down. Everything here
# runs offline, entirely from local state, so it works precisely when that
# matters most.
#
#   recon           Run all checks (local + dev VM).
#   recon --no-dev   Skip the dev VM check (it needs a network path to
#                    reach dev; local checks always run regardless).

RUN_DEV=1
[ "${1:-}" = "--no-dev" ] && RUN_DEV=0

ISSUES=0

check_wifi() {
    echo "[wifi]"
    local dev state radio
    dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    if [ -z "$dev" ]; then
        echo "  no wifi device found -- skipping"
        return
    fi
    radio="$(nmcli radio wifi 2>/dev/null)"
    state="$(nmcli -t -f GENERAL.STATE device show "$dev" 2>/dev/null | cut -d: -f2 | cut -d' ' -f1)"
    if [ "$state" = "100" ]; then
        echo "  OK -- $dev connected"
        return
    fi
    if [ "$radio" != "enabled" ]; then
        echo "  $dev not connected, but radio is off -- probably intentional"
        return
    fi
    echo "  $dev not connected (state=$state)"
    if systemctl --user is-active wifi-watchdog.service > /dev/null 2>&1; then
        echo "  -> wifi-watchdog is running and will auto-run 'fix-wifi --radio' if this"
        echo "     persists past ~60s. To act now: fix-wifi, then fix-wifi --radio if that"
        echo "     doesn't clear it within a few seconds (driver-level lockup -- see"
        echo "     notes/wifi-driver-lockup-2026-08-21.md)."
    else
        echo "  -> fix-wifi, then fix-wifi --radio if that doesn't clear it within a few"
        echo "     seconds (driver-level lockup -- see notes/wifi-driver-lockup-2026-08-21.md)."
        echo "     Note: wifi-watchdog.service isn't running -- it won't auto-recover this."
    fi
    ISSUES=1
}

check_ssh() {
    echo "[ssh]"
    shopt -s nullglob
    local sockets=("$HOME"/.ssh/cm-*)
    if [ ${#sockets[@]} -eq 0 ]; then
        echo "  no ControlMaster sockets open -- nothing to check"
        return
    fi
    for sock in "${sockets[@]}"; do
        [ -S "$sock" ] || continue
        local start end elapsed
        start=$(date +%s%N)
        timeout 5 ssh -O check -S "$sock" x > /dev/null 2>&1
        local rc=$?
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        if [ "$rc" -eq 124 ]; then
            echo "  $sock -- check itself timed out (${elapsed}ms) -- strong sign of a wedged master"
            echo "  -> fix-ssh"
            ISSUES=1
        else
            echo "  $sock -- responded in ${elapsed}ms"
            echo "     (a quick response here does NOT rule out the resume zombie bug -- it"
            echo "      false-positives 'alive'. If SSH/VS Code Remote-SSH is hanging despite"
            echo "      this looking fine, run fix-ssh anyway; it's safe either way. See"
            echo "      notes/ssh-controlmaster-zombie-after-resume.md.)"
        fi
    done
}

check_vscode() {
    echo "[vscode]"
    local lock="$HOME/.config/Code/code.lock"
    if [ ! -f "$lock" ]; then
        echo "  no lock file -- VS Code not running (or never has)"
        return
    fi
    local pid
    pid="$(cat "$lock" 2>/dev/null)"
    if [ -n "$pid" ] && [ -r "/proc/$pid/comm" ] && grep -qi code "/proc/$pid/comm" 2>/dev/null; then
        echo "  OK -- lock held by live process (pid $pid)"
    else
        echo "  stale lock (pid $pid not running, or not a code process)"
        echo "  -> reset-vscode"
        ISSUES=1
    fi
}

check_dev_vm() {
    echo "[dev]"
    if ! command -v check-dev > /dev/null 2>&1; then
        echo "  check-dev not on PATH -- skipping"
        return
    fi
    if ! check-dev; then
        ISSUES=1
    fi
}

echo "Running recon..."
echo ""
check_wifi
echo ""
check_ssh
echo ""
check_vscode
if [ "$RUN_DEV" -eq 1 ]; then
    echo ""
    check_dev_vm
fi
echo ""

if [ "$ISSUES" -eq 0 ]; then
    echo "No action needed -- everything checked out."
else
    echo "See '->' lines above for what to run."
fi

exit "$ISSUES"
