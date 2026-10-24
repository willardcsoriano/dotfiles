#!/usr/bin/env bash
# Tests for vscode-ssh-budget: runs the real script against throwaway
# settings.json / ssh config files and checks what it prints.
#   bash scripts/vscode-ssh-budget.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/vscode-ssh-budget.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
# expect WANT DESC [HOST] -- runs against $TMP/settings.json and $TMP/config;
# WANT "ERR" means the script must fail with a message on stderr.
expect() {
    local want=$1 desc=$2 host=${3:-dev} got rc
    got=$(VSCODE_SETTINGS="$TMP/settings.json" SSH_CONFIG="$TMP/config" VSCODE_LOGS="$TMP/logs" bash "$SCRIPT" "$host" 2>"$TMP/err")
    rc=$?
    if [ "$want" = ERR ]; then
        if [ "$rc" -ne 0 ] && [ -s "$TMP/err" ] && [ -z "$got" ]; then
            printf 'ok    %s\n' "$desc"
        else
            printf 'FAIL  %s: want an error, got rc=%s out=%q\n' "$desc" "$rc" "$got"
            fails=$((fails + 1))
        fi
    elif [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
        printf 'ok    %s\n' "$desc"
    else
        printf 'FAIL  %s: want %q, got rc=%s out=%q err=%q\n' "$desc" "$want" "$rc" "$got" "$(cat "$TMP/err")"
        fails=$((fails + 1))
    fi
}
settings() { printf '%s\n' "$@" > "$TMP/settings.json"; }
config()   { printf '%s\n' "$@" > "$TMP/config"; }
reset()    { rm -rf "$TMP/settings.json" "$TMP/config" "$TMP/included.conf" "$TMP/logs"; }
# mklog STAMP LINE... -- a Remote-SSH output log in VS Code's layout, under an
# output_logging_<STAMP> directory (STAMP like 20261024T214223).
mklog() {
    local stamp=$1 d; shift
    d="$TMP/logs/20261024T211254/window1/exthost/output_logging_$stamp"
    mkdir -p "$d"
    printf '%s\n' "$@" >> "$d/1-Remote - SSH.log"
}
# old FILE... -- backdate config files so a log from 2026-10-24 is newer.
old() { touch -d '2026-10-01 00:00' "$@"; }
# run_raw ARGS... -- run the script against the fixtures; stdout to $OUT,
# stderr to $TMP/err.
run_raw() {
    OUT=$(VSCODE_SETTINGS="$TMP/settings.json" SSH_CONFIG="$TMP/config" VSCODE_LOGS="$TMP/logs" bash "$SCRIPT" "$@" 2>"$TMP/err")
}
check() {
    local want=$1 got=$2 desc=$3
    if [ "$want" = "$got" ]; then printf 'ok    %s\n' "$desc"
    else printf 'FAIL  %s: want %q, got %q\n' "$desc" "$want" "$got"; fails=$((fails + 1)); fi
}

# --- the VS Code setting -----------------------------------------------------
reset
expect 17 "no settings file, no ssh config: extension default 15 + 2"

settings '{' '    "editor.fontSize": 14' '}'
expect 17 "settings without the key"

settings '{' '    "remote.SSH.connectTimeout": 60,' '    "remote.SSH.useLocalServer": true' '}'
expect 62 "2026-10-24 fix: setting 60"

settings '{"remote.SSH.connectTimeout":45}'
expect 47 "minified JSON, key last"

settings '{' '    // "remote.SSH.connectTimeout": 99,' '    "remote.SSH.connectTimeout": 30' '}'
expect 32 "commented-out line is ignored"

settings '{' '    "remote.SSH.connectTimeout": 0' '}'
expect 2 "setting 0 is 0 + 2, not unlimited (matches the extension)"

settings '{' '    "remote.SSH.connectTimeout": "15"' '}'
expect ERR "quoted value is refused, not defaulted"

settings '{' '    "remote.SSH.connectTimeout": 1.5' '}'
expect ERR "fractional value is refused"

# --- ConnectTimeout in ~/.ssh/config overrides the setting -------------------
settings '{' '    "remote.SSH.connectTimeout": 60' '}'
config 'Host *' '    ConnectTimeout 5'
expect 7 "2026-10-12: ConnectTimeout 5 under Host * beat the setting"

config 'ConnectTimeout=20'
expect 22 "global line before any Host, key=value form"

config 'Host dev' '    HostName example.invalid' 'Host *' '    ConnectTimeout 9'
expect 11 "Host * after a dev block still applies"

config 'Host other' '    ConnectTimeout 5'
expect 62 "another host's block is ignored"

config 'Host dev' '    ConnectTimeout 25' 'Host *' '    ConnectTimeout 5'
expect 27 "first value wins, as in ssh"

config 'Host * !dev' '    ConnectTimeout 5'
expect 62 "negated pattern excludes the host"

config 'Host d?v prod-*' '    ConnectTimeout 12'
expect 14 "? glob matches"
expect 14 "* glob matches" prod-eu
expect 62 "glob does not match" staging

config 'Host dev.example' '    ConnectTimeout 12'
expect 62 "dot in a pattern is literal" devXexample

config 'Host dev # the VM' '    ConnectTimeout 12 # slow link'
expect 14 "trailing comments are stripped"

config 'Host dev' '    ConnectTimeout 0'
expect 2147483 "config 0 means no limit"

config 'Host dev' '    ConnectTimeout soon'
expect ERR "non-numeric ConnectTimeout is refused"

# --- Match, as the extension evaluates it (#56) -------------------------------
config 'Match host dev' '    ConnectTimeout 5'
expect 7 "Match host compares the alias when no HostName is set"

config 'Host dev' '    HostName vm.example' 'Match host vm.example' '    ConnectTimeout 8'
expect 10 "Match host compares HostName as set so far"

config 'Host dev' '    HostName vm.example' 'Match host dev' '    ConnectTimeout 8'
expect 62 "Match host no longer matches the alias once HostName is set"

config 'Host dev' '    HostName vm.example' 'Match originalhost dev' '    ConnectTimeout 8'
expect 10 "Match originalhost compares the alias"

config 'Match host prod,dev' '    ConnectTimeout 6'
expect 8 "Match criteria take a comma list"

config 'Match host *,!dev' '    ConnectTimeout 6'
expect 62 "negation in a Match list"

config 'Match all' '    ConnectTimeout 4'
expect 6 "Match all"

config 'Match canonical all' '    ConnectTimeout 4'
expect 62 "Match canonical never matches in the extension"

config "Match localuser $(id -un)" '    ConnectTimeout 4'
expect 6 "Match localuser"

config 'Match user nobody-here' '    ConnectTimeout 4'
expect 62 "Match user that doesn't match"

config 'Host dev' '    User deploy' 'Match user deploy' '    ConnectTimeout 4'
expect 6 "Match user sees a User set earlier"

config 'Match host dev exec "true"' '    ConnectTimeout 4'
expect ERR "Match exec is refused (would run a command)"

config 'Match final' '    ConnectTimeout 4'
expect ERR "Match final is refused (second pass)"

config 'Match exec "true"' '    HostName vm.example' 'Match host vm.example' '    ConnectTimeout 4'
expect ERR "HostName set under an unsupported Match makes later Match host unknown"

config 'Match exec "true"' '    User x' 'Host dev' '    ConnectTimeout 4'
expect 6 "unsupported Match block without a ConnectTimeout doesn't block later ones"

# --- spellings the extension treats differently from ssh ----------------------
config 'Host *' '    connecttimeout 5'
expect 62 "lowercase connecttimeout reaches ssh but not VS Code"

config 'host dev' '    ConnectTimeout 5'
expect 62 "a lowercase host block is skipped whole"

config 'Host de?v' '    ConnectTimeout 12'
expect 14 "? matches zero characters in the extension"

# --- the 2026-10-24 bug: Include is invisible to the extension ---------------
printf '%s\n' 'Host *' '    ConnectTimeout 30' > "$TMP/included.conf"
config 'Host dev' '    HostName example.invalid' 'Match all' "Include $TMP/included.conf"
settings '{' '    "remote.SSH.connectTimeout": 15' '}'
expect 17 "ConnectTimeout only in an Included file does not count"

# --- self-check against the extension's own log (#56) -------------------------
reset
settings '{' '    "remote.SSH.connectTimeout": 15' '}'
config 'Host dev' '    HostName vm.example'
old "$TMP/settings.json" "$TMP/config"
mklog 20261024T214223 '[21:42:56.716] SSH Resolver called for host: dev' '[21:42:58.450] Using connect timeout of 17 seconds'
expect 17 "log agrees with the computed value"
check "" "$(cat "$TMP/err")" "  ...and says nothing"

reset
settings '{' '    "remote.SSH.connectTimeout": 15' '}'
config 'Host dev' '    HostName vm.example'
old "$TMP/settings.json" "$TMP/config"
mklog 20261024T214223 '[21:42:56.716] SSH Resolver called for host: dev' '[21:42:58.450] Using connect timeout of 40 seconds'
expect 40 "newer log that disagrees wins: the extension's rule changed"
case "$(cat "$TMP/err")" in *"rule has changed"*) check ok ok "  ...with a warning";; *) check warning "$(cat "$TMP/err")" "  ...with a warning";; esac

reset
settings '{' '    "remote.SSH.connectTimeout": 60' '}'
mklog 20261024T214223 '[21:42:56.716] SSH Resolver called for host: dev' '[21:42:58.450] Using connect timeout of 17 seconds'
expect 62 "log older than a settings change is ignored (2026-10-24 sequence)"

reset
settings '{' '    "remote.SSH.connectTimeout": 15' '}'
old "$TMP/settings.json"
mklog 20261024T214223 '[21:42:56.716] SSH Resolver called for host: prod' '[21:42:58.450] Using connect timeout of 40 seconds'
expect 17 "another host's log line is ignored"

# --- --last-connect: setup time of the newest successful connect -------------
reset
mklog 20261024T225810 \
  '[22:58:14.354] SSH Resolver called for host: dev' \
  '[22:58:15.567] > local-server-1> Spawned ssh, pid=293094' \
  '[22:58:29.771] stderr> Authenticated to <ip> ([<ip>]:22) using "publickey".' \
  '[22:58:36.391] Resolved "ssh-remote+dev" to "port 43249"'
run_raw --last-connect dev
check 6620 "${OUT%% *}" "2026-10-24 22:58 connect: 6.6s from login to resolved"

reset
mklog 20261024T100000 \
  '[10:00:00.000] SSH Resolver called for host: dev' \
  '[10:00:00.100] > local-server-1> Spawned ssh, pid=1' \
  '[10:00:03.100] Resolved "ssh-remote+dev" to "port 1"'
run_raw --last-connect dev
check 3000 "${OUT%% *}" "shared connection (no Authenticated line): measured from the spawn"

reset
mklog 20261024T100000 \
  '[10:00:00.000] SSH Resolver called for host: dev' \
  '[10:00:00.100] > local-server-1> Spawned ssh, pid=1' \
  '[10:00:01.100] stderr> Authenticated to x' \
  '[10:00:05.100] Resolved "ssh-remote+dev" to "port 1"' \
  '[11:00:00.000] SSH Resolver called for host: dev' \
  '[11:00:00.100] > local-server-1> Spawned ssh, pid=2' \
  '[11:00:17.000] Resolver error: Error: Connecting with SSH timed out'
run_raw --last-connect dev
check 4000 "${OUT%% *}" "a later failed attempt doesn't count; the last success does"

reset
mklog 20261024T235900 \
  '[23:59:59.000] SSH Resolver called for host: dev' \
  '[23:59:59.500] > local-server-1> Spawned ssh, pid=1' \
  '[23:59:59.800] stderr> Authenticated to x' \
  '[00:00:02.300] Resolved "ssh-remote+dev" to "port 1"'
run_raw --last-connect dev
check 2500 "${OUT%% *}" "a connect across midnight"

reset
mklog 20261024T100000 \
  '[10:00:00.000] SSH Resolver called for host: prod' \
  '[10:00:00.100] > local-server-1> Spawned ssh, pid=1' \
  '[10:00:03.100] Resolved "ssh-remote+prod" to "port 1"'
run_raw --last-connect dev
check "" "$OUT" "no connect to this host: prints nothing"

reset
run_raw --last-connect dev
check "" "$OUT" "no logs at all: prints nothing"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
