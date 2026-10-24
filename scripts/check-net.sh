#!/usr/bin/env bash
set -uo pipefail

# Advisory-only check of whether the current network can carry VS Code
# Remote-SSH to a host (default: dev). Measures packet loss and latency on
# each hop -- your router, the internet, the host -- then times a few fresh,
# non-multiplexed SSH logins against Remote-SSH's connect budget, and prints a
# verdict naming the hop at fault. Also sends one session through any
# existing shared connection (ControlMaster) to catch one that has stalled.
# Never takes action and never prints the host's address.
#
# Built after the 2026-10-14 slow-link incident (phone data while driving),
# where Remote-SSH timed out at its 17s budget and telling "my link is bad"
# from "dev is broken" took several rounds of manual pings. check-dev also
# times one handshake, but it checks VM health too; this answers only "can I
# connect from here, and if not, whose fault is it". The stalled-master check
# covers a master frozen by suspend, which `ssh -O check` still calls alive
# (notes/ssh-controlmaster-zombie-after-resume.md); on 2026-10-15 VS Code
# also timed out five times with a master open, cause unconfirmed.
#
# Usually takes 20-40s. On a very slow link each login can take up to the
# whole window, so a run can stretch to a few minutes.
#
#   check-net [host]

PINGS=20
HANDSHAKES=3
# A session through a working master needs one round trip, under a second
# even on a slow link; one that hasn't answered in this long is stalled.
SHARED_PROBE_SECS=10
# Loss above this on any hop is enough to stall an interactive session.
LOSS_BAD_PCT=2
# A healthy LAN/wifi hop answers in a few ms; sustained tens of ms means the
# router or hotspot is congested. The internet hop allows for mobile data.
ROUTER_AVG_BAD_MS=50
INTERNET_AVG_BAD_MS=250
# Anycast resolver used only as a ping target for "the internet in general".
INTERNET_REF="${CHECK_NET_REF:-1.1.1.1}"

# vscode-ssh-budget sits next to this script, both in the repo (*.sh) and
# once installed to ~/.local/bin (no suffix); PATH is the last resort.
vscode_ssh_budget() {
    local dir cand
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    for cand in "$dir/vscode-ssh-budget.sh" "$dir/vscode-ssh-budget"; do
        [ -x "$cand" ] && { "$cand" "$@"; return; }
    done
    if command -v vscode-ssh-budget > /dev/null 2>&1; then
        vscode-ssh-budget "$@"
        return
    fi
    echo "vscode-ssh-budget not found -- re-run install.sh" >&2
    return 1
}

# Remote-SSH's connect budget in ms (see vscode-ssh-budget for how VS Code
# derives it; `ssh -G` can disagree because the extension skips Include).
budget_ms() {
    local secs
    secs=$(vscode_ssh_budget "$1") || return 1
    echo $(( secs * 1000 ))
}

# "LOSS AVG MAX" (integers; loss in %, times in ms) for ping output on stdin,
# or nothing if no reply came back at all.
parse_ping() {
    awk '
        match($0, /[0-9.]+% packet loss/) { loss = substr($0, RSTART, RLENGTH - 13) }
        /^(rtt|round-trip)/ { split($4, t, "/"); avg = t[2]; max = t[3] }
        END { if (avg != "") printf "%d %d %d\n", loss + 0.5, avg + 0.5, max + 0.5 }
    '
}

# GOOD | MARGINAL | POOR | UNREACHABLE from the budget, the slowest successful
# fresh login plus VS Code's last measured server setup (0 when none is
# logged), and how many of the attempts failed out of how many were made.
verdict() {
    local budget=$1 worst=$2 failed=$3 total=$4
    if [ "$failed" -ge "$total" ]; then echo UNREACHABLE
    elif [ "$failed" -gt 0 ] || [ "$worst" -ge "$budget" ]; then echo POOR
    elif [ "$worst" -ge $(( budget / 2 )) ]; then echo MARGINAL
    else echo GOOD
    fi
}

# One fresh, non-multiplexed login; prints its wall-clock ms, or fails with
# ssh's last error line on stdout. Tests replace this function.
login_once() {
    local host=$1 timeout_s=$2 start end err
    start=$(date +%s%N)
    if err=$(timeout "$timeout_s" ssh -o ControlPath=none -o BatchMode=yes "$host" true 2>&1 < /dev/null > /dev/null); then
        end=$(date +%s%N)
        echo $(( (end - start) / 1000000 ))
    else
        tail -n 1 <<< "${err:-timed out}"
        return 1
    fi
}

# Up to N fresh logins, stopping at the first failure. Each failed login is
# one more sshd PerSourcePenalties charge against this address (10s when it
# outlasts LoginGraceTime; enforcement starts once 15s accrue), so a second
# failure could earn the very refusal being diagnosed -- and it adds nothing:
# one failure already decides the verdict. Prints
# "WORST_MS FAILED ATTEMPTED TIMES..." then, on failure, the error line.
run_logins() {
    local host=$1 n=$2 timeout_s=$3 i out worst=0 failed=0 tried=0 times="" why=""
    for (( i = 0; i < n; i++ )); do
        tried=$(( tried + 1 ))
        if out=$(login_once "$host" "$timeout_s"); then
            [ "$out" -gt "$worst" ] && worst=$out
            times+="$(fmt_secs "$out") "
        else
            failed=1
            times+="failed "
            why=$out
            break
        fi
    done
    echo "$worst $failed $tried $times"
    [ -n "$why" ] && echo "$why"
    return 0
}

# First hop at fault, nearest first: router | internet | host | (nothing).
# Args are LOSS AVG per hop; an empty pair means that hop gave no ICMP reply,
# which some routers and hosts do by design, so it can't be blamed.
blame() {
    local r_loss=$1 r_avg=$2 i_loss=$3 i_avg=$4 h_loss=$5
    if [ -n "$r_loss" ] && { [ "$r_loss" -gt "$LOSS_BAD_PCT" ] || [ "$r_avg" -gt "$ROUTER_AVG_BAD_MS" ]; }; then
        echo router
    elif [ -n "$i_loss" ] && { [ "$i_loss" -gt "$LOSS_BAD_PCT" ] || [ "$i_avg" -gt "$INTERNET_AVG_BAD_MS" ]; }; then
        echo internet
    elif [ -n "$h_loss" ] && [ "$h_loss" -gt "$LOSS_BAD_PCT" ]; then
        echo host
    fi
}

fmt_secs() { printf '%d.%ds' $(( $1 / 1000 )) $(( $1 % 1000 / 100 )); }

print_hop() {
    local name=$1 stats=$2 loss avg max
    if [ -z "$stats" ]; then
        printf '  %-9s no ping reply (may just block ICMP)\n' "$name"
        return
    fi
    read -r loss avg max <<< "$stats"
    printf '  %-9s %3d%% loss   avg %4d ms   worst %4d ms\n' "$name" "$loss" "$avg" "$max"
}

main() {
    local host="${1:-dev}"
    local target gateway budget
    target=$(ssh -G "$host" 2>/dev/null | awk '$1 == "hostname" { print $2 }')
    gateway=$(ip route show default 2>/dev/null | awk '{ print $3; exit }')
    budget=$(budget_ms "$host") || return 2
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    echo "Checking the link to $host (usually 20-40s)..."

    # Pings run concurrently so they measure the same moment.
    [ -n "$gateway" ] && ping -n -q -c "$PINGS" -i 0.2 -w 10 "$gateway" > "$TMP/router" 2>&1 &
    ping -n -q -c "$PINGS" -i 0.2 -w 10 "$INTERNET_REF" > "$TMP/internet" 2>&1 &
    [ -n "$target" ] && ping -n -q -c "$PINGS" -i 0.2 -w 10 "$target" > "$TMP/host" 2>&1 &
    wait

    local r i h
    r=$(parse_ping < "$TMP/router" 2>/dev/null)
    i=$(parse_ping < "$TMP/internet" 2>/dev/null)
    h=$(parse_ping < "$TMP/host" 2>/dev/null)
    print_hop router "$r"
    print_hop internet "$i"
    print_hop "$host" "$h"

    # `ssh -O check` only asks the local master process whether it's running,
    # never the remote end, so it can pass a master that can no longer carry
    # a session (frozen by suspend, or stalled on a dead link). Sessions sent
    # through such a master, VS Code's included, hang until they time out.
    # Send one real session through.
    # Only a timeout is evidence of a stall, as in fix-ssh: a session that
    # fails fast (refused, MaxSessions, a dying master) is reported as such
    # but doesn't get "close it" advice.
    local shared=none rc
    timeout 5 ssh -O check "$host" > /dev/null 2>&1
    rc=$?
    # 124: the master process itself didn't answer -- frozen, e.g. by suspend.
    if [ "$rc" -eq 124 ]; then
        shared=stalled
    elif [ "$rc" -eq 0 ]; then
        rc=0
        timeout "$SHARED_PROBE_SECS" ssh -o ControlMaster=no -o BatchMode=yes "$host" true < /dev/null > /dev/null 2>&1 || rc=$?
        case "$rc" in
            0)   shared=working ;;
            124) shared=stalled ;;
            *)   shared=error ;;
        esac
    fi
    case "$shared" in
        none)    echo "  shared connection: none open" ;;
        working) echo "  shared connection: working" ;;
        stalled) echo "  shared connection: STALLED (no answer in ${SHARED_PROBE_SECS}s)" ;;
        error)   echo "  shared connection: a session through it failed (ssh exit $rc), not a stall" ;;
    esac

    # Fresh logins bypass any ControlMaster: they measure what a new
    # connection costs, which is what times out when no working master exists.
    local worst failed tried times why="" summary
    summary=$(run_logins "$host" "$HANDSHAKES" $(( budget / 1000 + 5 )))
    read -r worst failed tried times <<< "$(head -n 1 <<< "$summary")"
    if [ "$failed" -gt 0 ]; then
        why=$(sed -n 2p <<< "$summary")
        # Swap the address for the host alias.
        [ -n "$target" ] && why=${why//"$target"/$host}
    fi
    echo "  fresh ssh login: ${times} (Remote-SSH gives up at $(fmt_secs "$budget"))"
    [ -n "$why" ] && echo "  last failure: $why (stopped there; more attempts would only add sshd penalties)"

    # VS Code's window also covers starting its server after the login. Use
    # the setup time its own log measured on the last successful connect.
    local setup=0 setup_age last
    last=$(vscode_ssh_budget --last-connect "$host" 2>/dev/null) || last=""
    if [ -n "$last" ]; then
        read -r setup setup_age <<< "$last"
        if [ "$setup_age" -lt 3600 ]; then setup_age="$(( setup_age / 60 ))m"
        elif [ "$setup_age" -lt 172800 ]; then setup_age="$(( setup_age / 3600 ))h"
        else setup_age="$(( setup_age / 86400 ))d"; fi
        echo "  VS Code server setup: $(fmt_secs "$setup") (measured on its last connect, $setup_age ago)"
    else
        echo "  VS Code server setup: not measured yet (no successful connect in its logs); grading the login alone"
    fi
    echo ""

    local v at rl ra il ia hl _
    v=$(verdict "$budget" $(( worst + setup )) "$failed" "$tried")
    read -r rl ra _ <<< "$r"
    read -r il ia _ <<< "$i"
    read -r hl _ <<< "$h"
    at=$(blame "$rl" "$ra" "$il" "$ia" "$hl")

    if [ "$shared" = stalled ]; then
        echo "STALLED SHARED CONNECTION -- VS Code's connects go through it and hang until they time out."
        echo "-> ssh -O exit $host    (closes it; the next connect opens a fresh one)"
        echo ""
    elif [ "$shared" = error ]; then
        echo "SHARED CONNECTION REFUSED A SESSION -- it answered, so it isn't stalled, but VS Code's"
        echo "connects go through it too. If Remote-SSH fails: ssh -O exit $host"
        echo ""
    fi
    case "$v" in
        GOOD)
            echo "GOOD -- Remote-SSH should connect normally." ;;
        MARGINAL)
            echo "MARGINAL -- a fresh Remote-SSH connect may time out."
            echo "-> Retry Remote-SSH: each attempt is a new login, and most get through on this link."
            echo "   If it fails twice, use 'ssh $host' + tmux, which has no time limit." ;;
        POOR)
            echo "POOR -- Remote-SSH will likely time out."
            echo "-> Use 'ssh $host' + tmux until the link improves, or switch networks." ;;
        UNREACHABLE)
            echo "UNREACHABLE -- no fresh login to $host succeeded."
            echo "-> Run check-dev to tell a down VM from a dead link." ;;
    esac
    # A bottleneck only matters when it costs a connect; on GOOD the hop
    # table above already shows any loss, and "restart your router" would be
    # advice to fix something that works.
    [ "$v" = GOOD ] && at=""
    case "$at" in
        router)   echo "   Bottleneck: your wifi/router or phone hotspot (local). Restart it or move networks." ;;
        internet) echo "   Bottleneck: your internet connection (ISP or mobile data), not $host." ;;
        host)     echo "   Bottleneck: the route to $host only; your internet is otherwise fine." ;;
    esac
    if [ "$v" != GOOD ] && [ "$v" != UNREACHABLE ]; then
        echo "   Don't run 'fix-ssh --vscode': $host isn't the problem, and it makes the next connect slower."
    fi

    [ "$v" = GOOD ] && [ "$shared" != stalled ] && [ "$shared" != error ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
