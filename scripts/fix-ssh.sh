#!/usr/bin/env bash
set -euo pipefail

# SSH connection recovery utility.
#
#   fix-ssh                        Clean up stale local ControlMaster sockets
#                                   left behind by a bad disconnect (timeout,
#                                   broken pipe), and close masters that are
#                                   still running but can no longer carry a
#                                   session (stalled on a lossy link, or
#                                   frozen by suspend). Safe — only ever
#                                   closes a master after a real session
#                                   through it fails to start in time.
#
#   fix-ssh --vscode [HOST]        Force-kill ALL vscode-server processes on
#                                   HOST (default: dev). NOT safe in the same
#                                   way — kills any live session too, not
#                                   just orphaned ones, since there's no
#                                   remote way to tell "orphaned" from
#                                   "another window is using this right now."
#                                   Use only when a VS Code Remote-SSH
#                                   reconnect is actually stuck. Terminal
#                                   equivalent of VS Code's own "Kill VS Code
#                                   Server on Host" command, which is
#                                   command-palette-only, requires closing
#                                   the connection first, and has known
#                                   reliability bugs
#                                   (microsoft/vscode-remote-release#10388).
#                                   See ssh-vm-banner-timeout/self-healing.md
#                                   for the incident this covers.

# A session through a working master needs one round trip; one that hasn't
# started in this long is stalled.
SESSION_PROBE_SECS=10


kill_remote_vscode_server() {
    local host="${1:-dev}"
    echo "Killing vscode-server processes on $host..."
    # The [.] (not \.) is deliberate: pkill -f matches against the FULL
    # command line, including the invoking shell's own — since this whole
    # script is passed to the remote as one argument, a literal "\." here
    # would make the pattern match itself and kill its own parent shell
    # mid-script, silently truncating everything after it. "[.]" matches
    # the same processes but breaks the self-match, since the invoking
    # shell's own argv contains "[.]vscode-server/", not the contiguous
    # ".vscode-server/" the pattern is actually searching for.
    ssh -o ControlPath=none "$host" '
      pkill -9 -f "[.]vscode-server/" || true
      find /tmp/user/1000 -maxdepth 1 -name "code-*" -type s -delete 2>/dev/null || true
      echo "Done."
    '
}

# Close a master that can't carry a session: ask it to exit, and if it's too
# frozen to answer, kill the process listening on its socket. ssh binds the
# socket under a temporary name ("SOCKET.<random>") and links it into place,
# so ss lists it under that name; a frozen master that ignores its control
# socket may not handle SIGTERM either, hence SIGKILL.
close_master() {
    local sock=$1 pid
    if ! timeout 5 ssh -O exit -S "$sock" x > /dev/null 2>&1; then
        pid=$(ss -xlp 2>/dev/null | awk -v s="$sock." '
            index($5, s) == 1 && match($0, /pid=[0-9]+/) { print substr($0, RSTART + 4, RLENGTH - 4) }')
        if [ -n "$pid" ]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$sock"
}

clean_local_sockets() {
    shopt -s nullglob
    local sockets=("$HOME"/.ssh/cm-*)

    if [ ${#sockets[@]} -eq 0 ]; then
        echo "No control sockets found. Nothing to do."
        return 0
    fi

    local removed=0 rc
    for sock in "${sockets[@]}"; do
        [ -S "$sock" ] || continue
        rc=0
        timeout 5 ssh -O check -S "$sock" x > /dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 124 ]; then
            echo "Frozen: $sock (master didn't answer; closing)"
            close_master "$sock"
            removed=$((removed + 1))
            continue
        elif [ "$rc" -ne 0 ]; then
            echo "Stale: $sock (removing)"
            rm -f "$sock"
            removed=$((removed + 1))
            continue
        fi
        # -O check only reached the local master process. A master stalled on
        # a lossy link still passes it while every session through it hangs
        # (2026-10-15), so open a real one. Only a timeout counts as stalled:
        # any other failure isn't evidence against the master.
        rc=0
        timeout "$SESSION_PROBE_SECS" ssh -S "$sock" -o ControlMaster=no -o BatchMode=yes x true < /dev/null > /dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 124 ]; then
            echo "Stalled: $sock (no session in ${SESSION_PROBE_SECS}s; closing)"
            close_master "$sock"
            removed=$((removed + 1))
        else
            echo "Live: $sock (leaving it alone)"
        fi
    done

    echo "Done. Closed or removed $removed socket(s)."
}

if [ "${1:-}" = "--vscode" ]; then
    shift
    kill_remote_vscode_server "$@"
else
    clean_local_sockets
fi
