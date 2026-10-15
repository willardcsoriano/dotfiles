#!/usr/bin/env bash
# Table tests for check-net's pure functions (verdict, blame, parse_ping).
#   bash scripts/check-net.test.sh
set -uo pipefail

# shellcheck source=scripts/check-net.sh
. "$(dirname "$0")/check-net.sh"

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

# verdict BUDGET WORST FAILED TOTAL
check GOOD        "$(verdict 17000 4200 0 3)"  "fast logins"
check MARGINAL    "$(verdict 17000 8500 0 3)"  "exactly half the budget is marginal"
check GOOD        "$(verdict 17000 8499 0 3)"  "just under half is good"
check MARGINAL    "$(verdict 17000 16200 0 3)" "2026-10-14 trip: 16.2s login"
check POOR        "$(verdict 17000 17000 0 3)" "at the budget"
check POOR        "$(verdict 17000 3000 1 3)"  "any failed login"
check UNREACHABLE "$(verdict 17000 0 3 3)"     "every login failed"

# blame R_LOSS R_AVG I_LOSS I_AVG H_LOSS
check router   "$(blame 15 394 0 206 0)" "2026-10-14 trip: lossy router"
check router   "$(blame 0 120 0 88 0)"   "slow router with no loss"
check internet "$(blame 0 14 5 88 0)"    "lossy internet, healthy router"
check internet "$(blame 0 14 0 300 0)"   "slow internet"
check host     "$(blame 0 30 0 88 15)"   "loss only on the route to dev"
check ""       "$(blame 0 14 0 88 0)"    "all healthy"
check ""       "$(blame 0 14 0 88 2)"    "loss at the threshold is not blamed"
check internet "$(blame "" "" 5 88 0)"   "router blocks ICMP, internet lossy"
check host     "$(blame "" "" "" "" 20)" "only the host answered"
check ""       "$(blame "" "" "" "" "")" "nothing answered"

# parse_ping on iputils output
check "15 394 2258" "$(parse_ping <<'EOF'
--- 192.0.2.1 ping statistics ---
20 packets transmitted, 17 received, 15% packet loss, time 5887ms
rtt min/avg/max/mdev = 4.412/393.648/2257.886/616.834 ms, pipe 8
EOF
)" "lossy summary"
check "0 14 210" "$(parse_ping <<'EOF'
--- 192.0.2.1 ping statistics ---
25 packets transmitted, 25 received, 0% packet loss, time 7226ms
rtt min/avg/max/mdev = 1.327/13.788/209.660/41.000 ms
EOF
)" "clean summary"
check "" "$(parse_ping <<'EOF'
--- 192.0.2.1 ping statistics ---
20 packets transmitted, 0 received, 100% packet loss, time 9999ms
EOF
)" "no replies"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
