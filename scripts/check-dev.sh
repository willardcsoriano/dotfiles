#!/usr/bin/env bash
set -uo pipefail

# Advisory-only health check for the dev VM. Queries the same signals used to
# tell apart the two confirmed failure mechanisms during live incidents (see
# dotfiles/ssh-vm-banner-timeout/) and prints what to run, if anything -- it
# never takes any action itself. Each check is timeout-wrapped individually so
# one hung command (expected once the VM is actually under real pressure --
# see incident-2026-08-17-vscode-server-pileup-reaper-still-not-deployed.md)
# doesn't block the rest, and a hang is itself treated as a signal.

HOST="${1:-dev}"
TIMEOUT=8

q() { timeout "$TIMEOUT" ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" "$1" 2>/dev/null; }

echo "Checking $HOST..."

if ! timeout 6 ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    # A hang here could mean dev is actually down, OR it could mean the local
    # ControlMaster to dev is a zombie (see
    # dotfiles/notes/ssh-controlmaster-zombie-after-resume.md) -- ssh -O check
    # would misleadingly report that master as "alive," so the only reliable
    # way to tell them apart is a fresh, non-multiplexed connection that
    # bypasses it entirely.
    if timeout 8 ssh -o ControlPath=none -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
        echo ""
        echo "LOCAL ISSUE -- dev is fine (a non-multiplexed connection succeeded), but the"
        echo "normal connection hung -- your local SSH ControlMaster to $HOST is likely a zombie."
        echo "-> fix-ssh (no flags) to clear it. This should already auto-run on every laptop"
        echo "   resume via the ssh-control-reset sleep hook -- if you're seeing this, worth"
        echo "   confirming that hook is still installed: ls /etc/systemd/system-sleep/ssh-control-reset"
        exit 1
    fi
    echo ""
    echo "UNREACHABLE -- $HOST didn't respond even to a fresh, non-multiplexed connection."
    echo "-> (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make check) for metrics,"
    echo "   then make recover if it's actually down (may need a VM reboot/reset)."
    exit 1
fi

DOCKER_RESTARTS=$(q "systemctl --user show docker.service -p NRestarts --value")
MEM_USED=$(q "free -m | awk '/Mem:/{print \$3}'")
MEM_TOTAL=$(q "free -m | awk '/Mem:/{print \$2}'")
SWAP_USED=$(q "free -m | awk '/Swap:/{print \$3}'")
SWAP_TOTAL=$(q "free -m | awk '/Swap:/{print \$2}'")
SLICE_CUR=$(q "systemctl show user-1000.slice -p MemoryCurrent --value")
SLICE_HIGH=$(q "systemctl show user-1000.slice -p MemoryHigh --value")
LOAD1=$(q "cut -d' ' -f1 /proc/loadavg")

HUNG=0
for v in "$DOCKER_RESTARTS" "$MEM_USED" "$SWAP_TOTAL" "$SLICE_CUR" "$LOAD1"; do
    [ -z "$v" ] && HUNG=1
done

if [ "$HUNG" -eq 1 ]; then
    echo ""
    echo "PARTIAL/HUNG -- basic checks (free/systemctl) took too long or failed."
    echo "That itself is a distress signal (seen during the 2026-08-17 incident, where"
    echo "even 'free -h' and 'ps aux' stalled under real pressure)."
    echo "-> fix-ssh --vscode $HOST is the first thing to try; if that also hangs/fails,"
    echo "   (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make recover)."
    exit 1
fi

SWAP_PCT=0
[ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null && SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))

SLICE_PCT=0
[ "${SLICE_HIGH:-0}" -gt 0 ] 2>/dev/null && SLICE_PCT=$((SLICE_CUR * 100 / SLICE_HIGH))

echo ""
echo "  docker.service restarts : $DOCKER_RESTARTS"
echo "  RAM used                : ${MEM_USED}Mi / ${MEM_TOTAL}Mi"
echo "  swap used                : ${SWAP_USED}Mi / ${SWAP_TOTAL}Mi (${SWAP_PCT}%)"
echo "  user-1000.slice          : ${SLICE_PCT}% of MemoryHigh ceiling"
echo "  load average (1m)        : $LOAD1"
echo ""

ACTION=""
if [ "${DOCKER_RESTARTS:-0}" -gt 0 ] 2>/dev/null; then
    echo "SIGNATURE: docker.service has restarted -- matches the Docker crash-loop mechanism."
    echo "-> (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make recover) -- likely needs a VM reboot."
    ACTION=1
fi

if [ "$SWAP_PCT" -ge 80 ] || [ "$SLICE_PCT" -ge 90 ]; then
    echo "SIGNATURE: swap/memory ceiling pressure -- matches the vscode-server pileup mechanism."
    echo "-> fix-ssh --vscode $HOST (safe with tmux-hosted agent sessions -- see"
    echo "   dotfiles/ssh-vm-banner-timeout/self-healing.md item 5). May need 2-3 attempts"
    echo "   under real pressure; check this script again afterward to confirm recovery."
    ACTION=1
fi

LOAD1_INT=${LOAD1%%.*}
if [ -z "$ACTION" ] && [ "${LOAD1_INT:-0}" -ge 8 ] 2>/dev/null; then
    echo "SIGNATURE: load average elevated with no other clear cause."
    echo "-> (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make postmortem) to capture what's running before it resolves itself."
    ACTION=1
fi

if [ -z "$ACTION" ]; then
    echo "Looks fine -- no action needed."
fi
