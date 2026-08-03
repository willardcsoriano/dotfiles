#!/usr/bin/env bash
# Kills vscode-server session trees older than MAX_AGE_HOURS. Age-based, not
# connection-aware: a version-mismatched reconnect (see self-healing.md,
# "Confirmed occurrence 2026-07-29") can orphan a server tree with no client
# left that will ever ask it to shut down, so this is a coarse backstop for
# that failure mode, not a replacement for noticing stale windows.
set -uo pipefail

MAX_AGE_HOURS=24
MAX_AGE_SECONDS=$((MAX_AGE_HOURS * 3600))

COLUMNS=1000 ps -eo pid,etimes,args --no-headers \
  | grep -E '\.vscode-server/(code-[0-9a-f]+ (agent host|command-shell)|cli/servers/[^ ]+/server/(bin/code-server|node .*out/(server-main\.js|bootstrap-fork)))' \
  | while read -r pid etimes _rest; do
      if [ "$etimes" -gt "$MAX_AGE_SECONDS" ]; then
          logger -t reap-vscode-server "killing pid $pid, age ${etimes}s"
          kill "$pid" 2>/dev/null || true
      fi
    done

find /tmp/user/1000 -maxdepth 1 -name 'code-*' -type s -mmin "+$((MAX_AGE_HOURS * 60))" -delete 2>/dev/null || true
