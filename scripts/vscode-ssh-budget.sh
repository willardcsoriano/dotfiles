#!/usr/bin/env bash
# vscode-ssh-budget [host] -- print, in seconds, how long VS Code Remote-SSH
# waits for a connect to <host> (default: dev) before "Connecting with SSH
# timed out". check-net, check-dev and fix-ssh all grade logins against it.
#
# vscode-ssh-budget --last-connect [host] -- print "SETUP_MS AGE_SECS" for
# the newest successful Remote-SSH connect to <host> in VS Code's logs: how
# long it spent after the ssh login (starting its server, tunnelling) and how
# long ago that was. Prints nothing when no log has one.
#
# Mirrors connectTimeoutMilliseconds() in ms-vscode-remote.remote-ssh 0.128.0
# (out/extension.js), checked 2026-10-24:
#   1. start from the remote.SSH.connectTimeout setting, 15 when unset;
#   2. if the extension's own parse of the ssh config gives the host a
#      ConnectTimeout, use that instead (0 = no limit);
#   3. add 2s.
# The extension's parser reads ~/.ssh/config itself and does NOT follow
# Include, so a ConnectTimeout in an included file (e.g. the dotfiles
# defaults in ~/.ssh/config.d/) never reaches VS Code, even though `ssh -G`
# reports it. That gap is why this can't just read `ssh -G`.
# The budget covers the whole connect: ssh login AND starting the remote
# VS Code server, not just the ssh handshake.
#
# Self-check: the extension logs the value it used ("Using connect timeout of
# N seconds"). When its newest such line for the host is newer than both
# config files and disagrees with the computed value, the extension's rule
# has changed under this script: print the logged value and warn.
#
# Overridable for tests: VSCODE_SETTINGS, SSH_CONFIG (file paths), VSCODE_LOGS
# (directory).
set -euo pipefail

SETTINGS="${VSCODE_SETTINGS:-$HOME/.config/Code/User/settings.json}"
CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
LOGS="${VSCODE_LOGS:-$HOME/.config/Code/logs}"
SETTING_DEFAULT=15
# The extension's "no limit" (2147483647 ms), in seconds.
NO_LIMIT_SECS=2147483

die() { echo "vscode-ssh-budget: $*" >&2; exit 1; }

# remote.SSH.connectTimeout from the user settings (JSON with comments), or
# the default when the file or key is absent. A value that isn't a plain
# integer is an error, not a silent default.
setting_secs() {
    local v
    [ -r "$SETTINGS" ] || { echo "$SETTING_DEFAULT"; return; }
    v=$(grep -v '^[[:space:]]*//' "$SETTINGS" \
        | grep -o '"remote\.SSH\.connectTimeout"[[:space:]]*:[[:space:]]*[^,}[:space:]]*' \
        | head -n 1 | sed 's/.*:[[:space:]]*//') || true
    case "$v" in
        '') echo "$SETTING_DEFAULT" ;;
        *[!0-9]*) die "remote.SSH.connectTimeout in $SETTINGS is '$v', not a whole number of seconds" ;;
        *) echo "$v" ;;
    esac
}

# The first ConnectTimeout that ~/.ssh/config itself gives <host>, the way
# the extension's own parser (extension.js 0.128.0, checked 2026-10-24) reads
# it -- which differs from ssh in ways that matter here:
#   - Include is never followed.
#   - Directive names are compared case-sensitively: only "Host", "Match",
#     "HostName", "User" and "ConnectTimeout" spelled exactly so count, so a
#     lowercase "connecttimeout" reaches ssh but not VS Code, and a lowercase
#     "host" block is skipped whole.
#   - Patterns: '*' is any run, '?' is ZERO or one character (ssh: exactly
#     one), '!' negates; Host takes a whitespace list, Match criteria a
#     comma list.
#   - Match supports all, host (against HostName as set so far),
#     originalhost, user and localuser; canonical never matches. exec runs a
#     shell command and final needs a second pass: a ConnectTimeout that
#     depends on either is reported as UNSUPPORTED rather than guessed.
#   - First value wins.
# Prints the value, UNSUPPORTED, or nothing.
config_connect_timeout() {
    local host=$1 user
    [ -r "$CONFIG" ] || return 0
    user=$(id -un)
    awk -v host="$host" -v user="$user" '
        function glob_match(pat, s,   re) {
            re = pat
            gsub(/[.+^$(){}|\\\[\]]/, "\\\\&", re)
            gsub(/\*/, ".*", re)
            gsub(/\?/, ".?", re)
            return s ~ ("^(" re ")$")
        }
        # n patterns in pats[1..n]; any negated hit vetoes.
        function list_match(n, pats, s,   i, hit) {
            hit = 0
            for (i = 1; i <= n; i++) {
                if (pats[i] ~ /^!/) { if (glob_match(substr(pats[i], 2), s)) return 0 }
                else if (glob_match(pats[i], s)) hit = 1
            }
            return hit
        }
        function host_line(   i, n, pats) {
            n = 0
            for (i = 2; i <= NF; i++) pats[++n] = $i
            return list_match(n, pats, host) ? "on" : "off"
        }
        function criterion(name, val,   n, pats) {
            n = split(val, pats, ",")
            # HostName/User set under an unsupported Match: value unknown.
            if ((name == "host" && hn_unknown) || (name == "user" && user_unknown)) return -1
            if (name == "host")         return list_match(n, pats, hostname)
            if (name == "originalhost") return list_match(n, pats, host)
            if (name == "user")         return list_match(n, pats, cur_user)
            if (name == "localuser")    return list_match(n, pats, user)
            return 0
        }
        function match_line(   i, name, unsupported, r) {
            unsupported = 0
            for (i = 2; i <= NF; i++) {
                name = tolower($i)
                if (name == "all") continue
                if (name == "canonical") return "off"
                if (name == "final") { unsupported = 1; continue }
                if (i + 1 > NF) return "off"
                if (name == "exec") { unsupported = 1; i++; continue }
                r = criterion(name, $(i + 1))
                if (r == 0) return "off"
                if (r < 0) unsupported = 1
                i++
            }
            return unsupported ? "unsupported" : "on"
        }
        BEGIN { section = "on"; hostname = host; cur_user = user }
        { sub(/#.*/, ""); sub(/=/, " ") }
        NF == 0 { next }
        $1 == "Host"  { section = host_line(); next }
        $1 == "Match" { section = match_line(); next }
        tolower($1) == "host" || tolower($1) == "match" { section = "off"; next }
        section == "off" { next }
        $1 == "HostName" && !set_hostname { set_hostname = 1; if (section == "on") hostname = $2; else hn_unknown = 1; next }
        $1 == "User" && !set_user { set_user = 1; if (section == "on") cur_user = $2; else user_unknown = 1; next }
        $1 == "ConnectTimeout" {
            print (section == "unsupported" ? "UNSUPPORTED" : $2)
            exit
        }
    ' "$CONFIG"
}

# Records for <host> from every Remote-SSH output log, oldest first:
#   BUDGET <epoch> <secs>        a "Using connect timeout of N seconds" line
#   CONNECT <epoch> <setup_ms>   a successful connect: from the ssh login
#                                ("Authenticated", or the ssh spawn when a
#                                shared connection skipped it) to "Resolved"
# Log lines carry only a time of day; the date comes from the enclosing
# output_logging_YYYYMMDDTHHMMSS directory, rolling over when time runs
# backwards.
log_records() {
    local host=$1 f stamp day0
    [ -d "$LOGS" ] || return 0
    find "$LOGS" -name '*Remote - SSH.log' -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        stamp=$(grep -o 'output_logging_[0-9]\{8\}T' <<< "$f" | tail -n 1 | grep -o '[0-9]\{8\}') || continue
        day0=$(date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2}" +%s 2>/dev/null) || continue
        awk -v host="$host" -v day0="$day0" '
            match($0, /^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+\]/) {
                split(substr($0, 2, RLENGTH - 2), t, /[:.]/)
                ms = ((t[1] * 60 + t[2]) * 60 + t[3]) * 1000 + t[4]
                if (ms < prev - 3600000) day++
                prev = ms
                now = ms + day * 86400000
            }
            /SSH Resolver called for host: / { cur = $NF; t0 = ""; tauth = ""; next }
            cur != host { next }
            /Using connect timeout of [0-9]+ seconds/ {
                for (i = 1; i <= NF; i++) if ($i == "of") n = $(i + 1)
                printf "BUDGET %d %d\n", day0 + now / 1000, n
            }
            /Spawned ssh, pid=/ { t0 = now }
            /Authenticated to / { tauth = now }
            index($0, "Resolved \"ssh-remote+" host "\"") && t0 != "" {
                start = (tauth != "") ? tauth : t0
                printf "CONNECT %d %d\n", day0 + now / 1000, now - start
                t0 = ""; tauth = ""
            }
        ' "$f"
    done | sort -k2,2n
}

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

last_connect() {
    local kind at setup_ms
    read -r kind at setup_ms < <(log_records "$1" | awk '$1 == "CONNECT"' | tail -n 1) || return 0
    [ "$kind" = CONNECT ] || return 0
    echo "$setup_ms $(( $(date +%s) - at ))"
}

main() {
    if [ "${1:-}" = "--last-connect" ]; then
        last_connect "${2:-dev}"
        return
    fi
    local host="${1:-dev}" secs ct
    secs=$(setting_secs)
    ct=$(config_connect_timeout "$host")
    case "$ct" in
        '') ;;
        UNSUPPORTED) die "ConnectTimeout for $host in $CONFIG sits under 'Match exec' or 'Match final'; not evaluated, so can't tell what Remote-SSH uses" ;;
        *[!0-9]*) die "ConnectTimeout for $host in $CONFIG is '$ct', not a whole number of seconds" ;;
        # Only a config ConnectTimeout of 0 means "no limit"; a setting of 0
        # is just 0 + 2s, as in the extension.
        0) secs=$NO_LIMIT_SECS ;;
        *) secs=$(( ct + 2 )) ;;
    esac
    if [ -z "$ct" ]; then
        secs=$(( secs + 2 ))
    fi
    verify_against_log "$host" "$secs"
}

# Print the budget, or the extension's own logged value if a log line newer
# than every config input contradicts it.
verify_against_log() {
    local host=$1 secs=$2 kind="" at logged newest
    read -r kind at logged < <(log_records "$host" | awk '$1 == "BUDGET"' | tail -n 1) || true
    newest=$(mtime "$SETTINGS")
    [ "$(mtime "$CONFIG")" -gt "$newest" ] && newest=$(mtime "$CONFIG")
    if [ "$kind" = BUDGET ] && [ "$at" -gt "$newest" ] && [ "$logged" != "$secs" ]; then
        echo "vscode-ssh-budget: VS Code last used ${logged}s for $host but the config gives ${secs}s -- the extension's rule has changed; trusting its log. Update this script." >&2
        echo "$logged"
        return
    fi
    echo "$secs"
}

main "$@"
