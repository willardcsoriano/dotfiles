#!/usr/bin/env bash
# check-dev.sh returns early when sourced, so it stops before its ssh
# queries; shellcheck reads that top-level return as making everything after
# the source line here unreachable (SC2317). It isn't: the tests run.
# shellcheck disable=SC2317
# Table tests for check-dev's memory_signature (the pressure decision).
#   bash scripts/check-dev.test.sh
set -uo pipefail

# shellcheck source=scripts/check-dev.sh
. "$(dirname "$0")/check-dev.sh"

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

# memory_signature SWAP_PCT AVAIL_PCT SYS_PSI SLICE_PCT SLICE_PSI
# The false alarms this exists to stop (#49): slice near its ceiling, nothing stalling.
check idle     "$(memory_signature 38 42 0 96 0)"  "2026-10-24: slice 96%, PSI 0, 42% RAM free"
check idle     "$(memory_signature 38 42 0 98 0)"  "2026-10-15: slice 98%, PSI 0"
check idle     "$(memory_signature 38 42 4 90 4)"  "slice at 90%, PSI just under the threshold"
# #28: full swap of paged-out idle processes is not pressure either.
check idle     "$(memory_signature 95 40 0 50 0)"  "swap 95%, RAM available, no stalls"
check idle     "$(memory_signature 95 40 0 95 0)"  "both near limits, nothing short"

# Real pressure must still fire.
check pressure "$(memory_signature 38 42 5 90 5)"  "slice at ceiling and tasks stalling"
check pressure "$(memory_signature 38 42 30 99 30)" "slice at ceiling, heavy stalls"
check pressure "$(memory_signature 38 10 0 92 0)"  "slice at ceiling and RAM nearly gone"
check pressure "$(memory_signature 80 14 0 50 0)"  "swap at 80% and RAM nearly gone"
check pressure "$(memory_signature 100 3 60 100 60)" "2026-08-21-style meltdown"

# Each limit is judged by its own PSI.
check pressure "$(memory_signature 38 42 0 96 8)"  "slice PSI high, system PSI low"
check idle     "$(memory_signature 38 42 9 96 0)"  "system PSI high but slice PSI 0, swap low"
check pressure "$(memory_signature 90 42 9 50 0)"  "swap near limit judged by system PSI"
check idle     "$(memory_signature 90 42 0 50 9)"  "slice PSI is irrelevant while slice is far from its ceiling"

# Below every limit: nothing to say, even with stalls or low RAM.
check ok       "$(memory_signature 79 42 0 89 0)"  "just under both limits"
check ok       "$(memory_signature 10 10 20 50 20)" "short on RAM but swap and slice fine"
check ok       "$(memory_signature 0 100 0 0 0)"   "idle host"

# An unreadable (empty) PSI is not 0: it cannot prove "nothing stalling".
check unknown  "$(memory_signature 38 42 0 96 "")" "empty slice PSI with slice near ceiling"
check unknown  "$(memory_signature 90 42 "" 50 0)" "empty system PSI with swap near limit"
check pressure "$(memory_signature 38 10 "" 96 "")" "empty PSI but RAM nearly gone"
check pressure "$(memory_signature 90 42 "" 96 9)" "pressure outranks unknown"
check unknown  "$(memory_signature 90 42 0 96 "")" "unknown outranks idle"
check ok       "$(memory_signature 38 42 "" 50 "")" "empty PSI, nothing near a limit"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
