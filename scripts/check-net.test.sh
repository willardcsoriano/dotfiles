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

# run_logins stops at the first failure (#55): a stub login_once plays back
# a script of results and counts how often it was called.
CALLS_FILE=$(mktemp)
trap 'rm -f "$CALLS_FILE"' EXIT
PLAN=()
login_once() {
    local n
    n=$(( $(wc -l < "$CALLS_FILE") ))
    echo x >> "$CALLS_FILE"
    case "${PLAN[$n]}" in
        fail) echo "Connection timed out during banner exchange"; return 1 ;;
        *)    echo "${PLAN[$n]}" ;;
    esac
}
logins() { : > "$CALLS_FILE"; PLAN=("$@"); run_logins dev 3 67; }
calls() { wc -l < "$CALLS_FILE" | tr -d ' '; }

out=$(logins 2300 2400 2200)
check "2400 0 3" "$(head -n 1 <<< "$out" | cut -d' ' -f1-3)" "three good logins: worst, no failure, three tried"
check 3 "$(calls)" "  ...all three attempted"

out=$(logins fail 2000 2000)
check "0 1 1" "$(head -n 1 <<< "$out" | cut -d' ' -f1-3)" "first login fails: stop after one"
check 1 "$(calls)" "  ...only one sshd penalty risked"
check "Connection timed out during banner exchange" "$(sed -n 2p <<< "$out")" "  ...error line passed on"
check UNREACHABLE "$(verdict 62000 0 1 1)" "  ...which grades UNREACHABLE"

out=$(logins 3000 fail 2000)
check "3000 1 2" "$(head -n 1 <<< "$out" | cut -d' ' -f1-3)" "second login fails: stop after two"
check 2 "$(calls)" "  ...third never attempted"
check POOR "$(verdict 62000 3000 1 2)" "  ...which grades POOR"

# Measured server setup counts against the window (#55): the 2026-10-14
# car trip's 16.2s login plus a ~5s setup could never fit 17s.
check POOR     "$(verdict 17000 $(( 16200 + 5000 )) 0 3)" "slow login plus setup past the window"
check GOOD     "$(verdict 62000 $(( 19700 + 6620 )) 0 3)" "2026-10-24: 19.7s login + 6.6s setup is under half of 62s"
check MARGINAL "$(verdict 62000 $(( 24400 + 6620 )) 0 3)" "login + setup at half the window is marginal"
echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
