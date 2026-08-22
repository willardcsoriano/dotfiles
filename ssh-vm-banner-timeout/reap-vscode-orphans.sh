#!/usr/bin/env bash
# Kills vscode-server session trees whose parent SSH session has already
# died (reparented to PID 1) -- catches a pileup within minutes of a bad
# disconnect, rather than waiting for reap-vscode-server.sh's 24h age-based
# backstop. Confirmed live case: 2026-08-21, a wifi network switch on mba15
# orphaned 3 windows' worth of extensionHost + language-server trees inside
# roughly an hour -- well under the 24h threshold -- and load average hit
# ~95 before it was noticed and cleared manually with `fix-ssh --vscode`.
#
# Safe to run unattended and frequently, unlike `fix-ssh --vscode`: it only
# ever touches a tree whose top-level launcher (the `command-shell`/`agent
# host` process spawned directly by sshd for that connection) has PPID=1,
# which structurally cannot be true for a tree still attached to a live
# session -- a live session's launcher always has a real sshd process as
# its parent. No age heuristic, no guessing.
set -uo pipefail

kill_tree() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -9 "$pid" 2>/dev/null || true
}

COLUMNS=1000 ps -eo pid,ppid,args --no-headers \
  | grep -E '\.vscode-server/code-[0-9a-f]+ (agent host|command-shell)' \
  | while read -r pid ppid _rest; do
      if [ "$ppid" -eq 1 ]; then
          logger -t reap-vscode-orphans "killing orphaned tree, root pid $pid (ppid=1, was $(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')s old)"
          kill_tree "$pid"
      fi
    done
