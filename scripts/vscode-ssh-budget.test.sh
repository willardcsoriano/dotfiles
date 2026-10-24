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
    got=$(VSCODE_SETTINGS="$TMP/settings.json" SSH_CONFIG="$TMP/config" bash "$SCRIPT" "$host" 2>"$TMP/err")
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
reset()    { rm -f "$TMP/settings.json" "$TMP/config" "$TMP/included.conf"; }

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

config 'Match host dev' '    ConnectTimeout 5'
expect ERR "ConnectTimeout under Match is refused, not guessed"

# --- the 2026-10-24 bug: Include is invisible to the extension ---------------
printf '%s\n' 'Host *' '    ConnectTimeout 30' > "$TMP/included.conf"
config 'Host dev' '    HostName example.invalid' 'Match all' "Include $TMP/included.conf"
settings '{' '    "remote.SSH.connectTimeout": 15' '}'
expect 17 "ConnectTimeout only in an Included file does not count"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
