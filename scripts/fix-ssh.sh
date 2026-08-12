#!/usr/bin/env bash
set -euo pipefail

# SSH connection recovery utility.
#
#   fix-ssh                        Clean up stale local ControlMaster sockets
#                                   left behind by a bad disconnect (timeout,
#                                   broken pipe). Safe — only ever removes a
#                                   socket after confirming its master
#                                   connection is actually dead via
#                                   `ssh -O check`.
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

clean_local_sockets() {
    shopt -s nullglob
    local sockets=("$HOME"/.ssh/cm-*)

    if [ ${#sockets[@]} -eq 0 ]; then
        echo "No control sockets found. Nothing to do."
        return 0
    fi

    local removed=0
    for sock in "${sockets[@]}"; do
        [ -S "$sock" ] || continue
        if ssh -O check -S "$sock" x 2>/dev/null; then
            echo "Live: $sock (leaving it alone)"
        else
            echo "Stale: $sock (removing)"
            rm -f "$sock"
            removed=$((removed + 1))
        fi
    done

    echo "Done. Removed $removed stale socket(s)."
}

if [ "${1:-}" = "--vscode" ]; then
    shift
    kill_remote_vscode_server "$@"
else
    clean_local_sockets
fi
