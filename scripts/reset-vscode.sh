#!/usr/bin/env bash
set -euo pipefail

# Local VS Code hang recovery utility.
#
# When the VS Code window wedges (renderer stops responding — VS Code's own
# "detected unresponsive" watchdog, surfaced as an OS-level "Close/Reopen"
# dialog), killing the window doesn't clean up after itself: the singleton
# lock file and IPC sockets it was holding are left behind. The next launch
# finds that stale state, tries to hand off to what it thinks is a live
# instance, and wedges the same way — so reopening VS Code repeatedly does
# not resolve it. This clears that stale state so the next launch starts
# clean.
#
#   reset-vscode            Kill any local VS Code processes, remove the
#                            stale singleton lock file and IPC sockets, then
#                            relaunch.
#   reset-vscode --no-relaunch
#                            Same cleanup, but don't relaunch afterward.

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

echo "Killing any local VS Code processes..."
pkill -9 -f "/usr/share/code/code" 2>/dev/null || true

echo "Removing stale singleton lock..."
rm -f "$HOME/.config/Code/code.lock"

echo "Removing stale IPC sockets..."
shopt -s nullglob
sockets=("$RUNTIME_DIR"/vscode-*.sock)
for sock in "${sockets[@]}"; do
    rm -f "$sock"
done
echo "Removed ${#sockets[@]} socket(s)."

if [ "${1:-}" != "--no-relaunch" ]; then
    echo "Relaunching VS Code..."
    nohup code >/dev/null 2>&1 &
    disown
fi

echo "Done."
