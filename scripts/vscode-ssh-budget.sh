#!/usr/bin/env bash
# vscode-ssh-budget [host] -- print, in seconds, how long VS Code Remote-SSH
# waits for a connect to <host> (default: dev) before "Connecting with SSH
# timed out". check-net, check-dev and fix-ssh all grade logins against it.
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
# Overridable for tests: VSCODE_SETTINGS, SSH_CONFIG (file paths).
set -euo pipefail

SETTINGS="${VSCODE_SETTINGS:-$HOME/.config/Code/User/settings.json}"
CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
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
# ssh reads it (first value wins; Host patterns are globs, '!' negates), or
# nothing. Include is skipped like the extension skips it. A ConnectTimeout
# under a Match block is reported as an error: whether the extension honours
# Match is unverified, so this refuses to guess.
config_connect_timeout() {
    local host=$1
    [ -r "$CONFIG" ] || return 0
    awk -v host="$host" '
        function glob_match(pat, s,   re) {
            re = pat
            gsub(/[.+^$(){}|\\]/, "\\\\&", re)
            gsub(/\*/, ".*", re)
            gsub(/\?/, ".", re)
            return s ~ ("^" re "$")
        }
        function host_line_matches(   i, p, hit) {
            hit = 0
            for (i = 2; i <= NF; i++) {
                p = $i
                if (p ~ /^!/) { if (glob_match(substr(p, 2), host)) return 0 }
                else if (glob_match(p, host)) hit = 1
            }
            return hit
        }
        { sub(/#.*/, ""); sub(/=/, " ") }
        NF == 0 { next }
        tolower($1) == "host"  { section = host_line_matches() ? "on" : "off"; next }
        tolower($1) == "match" { section = "match"; next }
        tolower($1) == "connecttimeout" {
            if (section == "match") { print "MATCH"; exit }
            if (section != "off") { print $2; exit }
        }
    ' "$CONFIG"
}

main() {
    local host="${1:-dev}" secs ct
    secs=$(setting_secs)
    ct=$(config_connect_timeout "$host")
    case "$ct" in
        '') ;;
        MATCH) die "$CONFIG sets ConnectTimeout inside a Match block; can't tell whether Remote-SSH uses it" ;;
        *[!0-9]*) die "ConnectTimeout for $host in $CONFIG is '$ct', not a whole number of seconds" ;;
        # Only a config ConnectTimeout of 0 means "no limit"; a setting of 0
        # is just 0 + 2s, as in the extension.
        0) echo "$NO_LIMIT_SECS"; return ;;
        *) secs=$ct ;;
    esac
    echo $(( secs + 2 ))
}

main "$@"
