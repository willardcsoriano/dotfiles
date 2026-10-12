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

# Above this, a fresh handshake is slow enough that VS Code Remote-SSH is at
# risk of timing out (its budget is ssh's ConnectTimeout + 2s, and it also has
# to start the remote server inside that window) -- see
# incident-2026-10-12-slow-mobile-link-remote-ssh-timeout.md.
SLOW_HANDSHAKE_SECS=4

# Wall-clock seconds for one fresh, non-multiplexed handshake, or empty if it
# failed. Generous timeouts on purpose: a slow-but-working link must not be
# misread as a dead VM or a zombie ControlMaster.
fresh_handshake_secs() {
    local start end
    start=$(date +%s%N)
    timeout 20 ssh -o ControlPath=none -o ConnectTimeout=15 -o BatchMode=yes "$HOST" true </dev/null 2>/dev/null || return 1
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000000 ))
}

echo "Checking $HOST..."

# A zombie ControlMaster needs an existing master socket. Resolve the path
# before probing, since the probe itself may create a fresh master.
CTL_PATH=$(ssh -G "$HOST" 2>/dev/null | awk '$1 == "controlpath" { print $2 }')
HAD_MASTER=0
[ -n "$CTL_PATH" ] && [ "$CTL_PATH" != "none" ] && [ -S "$CTL_PATH" ] && HAD_MASTER=1

if ! timeout 20 ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" true </dev/null 2>/dev/null; then
    # A failure here could mean dev is actually down, the local ControlMaster
    # to dev is a zombie (see dotfiles/notes/ssh-controlmaster-zombie-after-resume.md
    # -- ssh -O check misleadingly reports it "alive"), or the client network is
    # slow/flaky. A fresh, non-multiplexed connection tells them apart.
    if FRESH_SECS=$(fresh_handshake_secs); then
        echo ""
        if [ "$HAD_MASTER" -eq 1 ]; then
            echo "LOCAL ISSUE -- dev is fine (a non-multiplexed connection succeeded), but the"
            echo "connection through your existing SSH ControlMaster to $HOST failed -- that master is likely a zombie."
            echo "-> fix-ssh (no flags) to clear it. This should already auto-run on every laptop"
            echo "   resume via the ssh-control-reset sleep hook -- if you're seeing this, worth"
            echo "   confirming that hook is still installed: ls /etc/systemd/system-sleep/ssh-control-reset"
        else
            echo "FLAKY LINK -- dev is fine, but the first connection attempt failed and a retry"
            echo "succeeded (${FRESH_SECS}s handshake). No ControlMaster existed, so this is your"
            echo "client network, not dev and not a zombie master."
            echo "-> Nothing to run on dev. If VS Code Remote-SSH keeps timing out, switch networks."
        fi
        exit 1
    fi
    echo ""
    echo "UNREACHABLE -- $HOST didn't respond even to a fresh, non-multiplexed connection."
    echo "-> (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make check) for metrics,"
    echo "   then make recover if it's actually down (may need a VM reboot/reset)."
    exit 1
fi

# dev answered, but measure a fresh handshake anyway: the multiplexed probe
# above can succeed instantly over an existing master and hide a link too slow
# for any new connection (VS Code Remote-SSH opens its own).
FRESH_SECS=$(fresh_handshake_secs)
SLOW_LINK=0
[ -n "$FRESH_SECS" ] && [ "$FRESH_SECS" -ge "$SLOW_HANDSHAKE_SECS" ] && SLOW_LINK=1

DOCKER_RESTARTS=$(q "systemctl --user show docker.service -p NRestarts --value")
MEM_USED=$(q "free -m | awk '/Mem:/{print \$3}'")
MEM_TOTAL=$(q "free -m | awk '/Mem:/{print \$2}'")
MEM_AVAIL=$(q "free -m | awk '/Mem:/{print \$7}'")
# Share of the last 60s some task stalled on memory (PSI). Integer part only.
PSI_SOME60=$(q "awk -F'[ =]' '/^some/{print int(\$5)}' /proc/pressure/memory")
SWAP_USED=$(q "free -m | awk '/Swap:/{print \$3}'")
SWAP_TOTAL=$(q "free -m | awk '/Swap:/{print \$2}'")
SLICE_CUR=$(q "systemctl show user-1000.slice -p MemoryCurrent --value")
SLICE_HIGH=$(q "systemctl show user-1000.slice -p MemoryHigh --value")
LOAD1=$(q "cut -d' ' -f1 /proc/loadavg")
EXTHOST_COUNT=$(q "pgrep -fc 'type=extensionHost'")
OLDEST_SECS=$(q "ps -eo etimes,cmd --sort=start_time | grep '[.]vscode-server/' | head -1 | awk '{print \$1}'")

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

AVAIL_PCT=100
[ "${MEM_TOTAL:-0}" -gt 0 ] 2>/dev/null && AVAIL_PCT=$((MEM_AVAIL * 100 / MEM_TOTAL))

# Full swap alone isn't pressure: long-idle processes (e.g. tmux-hosted agent
# sessions) get paged out while RAM stays available and nothing stalls. Only
# treat it as pressure when RAM is also short or tasks are stalling on memory.
SWAP_PRESSURE=0
if [ "$SWAP_PCT" -ge 80 ] && { [ "$AVAIL_PCT" -lt 15 ] || [ "${PSI_SOME60:-0}" -ge 5 ]; }; then
    SWAP_PRESSURE=1
fi

SLICE_PCT=0
[ "${SLICE_HIGH:-0}" -gt 0 ] 2>/dev/null && SLICE_PCT=$((SLICE_CUR * 100 / SLICE_HIGH))

echo ""
OLDEST_HOURS=0
[ "${OLDEST_SECS:-0}" -gt 0 ] 2>/dev/null && OLDEST_HOURS=$((OLDEST_SECS / 3600))

echo "  docker.service restarts : $DOCKER_RESTARTS"
echo "  RAM used                : ${MEM_USED}Mi / ${MEM_TOTAL}Mi"
echo "  RAM available            : ${MEM_AVAIL}Mi (${AVAIL_PCT}%)"
echo "  swap used                : ${SWAP_USED}Mi / ${SWAP_TOTAL}Mi (${SWAP_PCT}%)"
echo "  memory stall (PSI 60s)   : ${PSI_SOME60:-?}%"
echo "  user-1000.slice          : ${SLICE_PCT}% of MemoryHigh ceiling"
echo "  load average (1m)        : $LOAD1"
echo "  open vscode windows      : ${EXTHOST_COUNT:-0} (extensionHost count)"
echo "  oldest vscode session    : ~${OLDEST_HOURS}h old"
echo ""

ACTION=""
if [ "${DOCKER_RESTARTS:-0}" -gt 0 ] 2>/dev/null; then
    echo "SIGNATURE: docker.service has restarted -- matches the Docker crash-loop mechanism."
    echo "-> (cd ~/projects/dotfiles/ssh-vm-banner-timeout && make recover) -- likely needs a VM reboot."
    ACTION=1
fi

if [ "$SWAP_PCT" -ge 80 ] && [ "$SWAP_PRESSURE" -eq 0 ] && [ "$SLICE_PCT" -lt 90 ]; then
    echo "NOTE: swap is ${SWAP_PCT}% full, but ${AVAIL_PCT}% of RAM is available and nothing is"
    echo "stalling on memory -- idle processes paged out, not pressure. Headroom is thin, though:"
    echo "-> see what's holding it: ssh $HOST 'tmux ls' (long-idle agent sessions are the usual cause)."
fi

if [ "$SWAP_PRESSURE" -eq 1 ] || [ "$SLICE_PCT" -ge 90 ]; then
    echo "SIGNATURE: swap/memory ceiling pressure."
    if [ "$OLDEST_HOURS" -ge 12 ] 2>/dev/null; then
        echo "Oldest session is ~${OLDEST_HOURS}h old (well past a normal work session) -- this"
        echo "matches the vscode-server orphaned-session pileup mechanism."
        echo "-> fix-ssh --vscode $HOST (safe with tmux-hosted agent sessions -- see"
        echo "   dotfiles/ssh-vm-banner-timeout/self-healing.md item 5). May need 2-3 attempts"
        echo "   under real pressure; check this script again afterward to confirm recovery."
    else
        echo "Oldest session is only ~${OLDEST_HOURS}h old with ${EXTHOST_COUNT:-0} window(s) open --"
        echo "this looks like real, current usage (e.g. multiple heavy Remote-SSH windows), not"
        echo "an orphaned pileup. fix-ssh --vscode $HOST kills EVERY session indiscriminately,"
        echo "live ones included -- confirm the open-window count matches what you actually have"
        echo "open before running it. If it doesn't match, or you don't need all of them open,"
        echo "closing a window (or fix-ssh --vscode $HOST if you're fine losing all of them) will"
        echo "relieve the pressure directly."
    fi
    ACTION=1
fi

if [ "$SLOW_LINK" -eq 1 ]; then
    echo "SIGNATURE: slow client link -- a fresh SSH handshake took ~${FRESH_SECS}s."
    echo "dev itself is fine; this is your network. VS Code Remote-SSH may time out"
    echo "(its budget is ssh's ConnectTimeout + 2s, which overrides remote.SSH.connectTimeout)."
    echo "-> Switch networks if Remote-SSH won't connect. Nothing to run on dev."
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
    exit 0
fi

exit 1
